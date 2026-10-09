[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile = Join-Path $repoRoot '.env'

if (-not (Test-Path -LiteralPath $envFile)) {
  throw "Missing .env at $envFile. Configure the local OpenBot development environment first."
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw 'wsl.exe was not found. This launcher requires Windows with WSL.'
}
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  throw 'bun was not found on Windows PATH. Install Bun before starting the Windows Chrome helper.'
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw 'node was not found on Windows PATH. Install Node.js before starting the Windows tunnel.'
}

$envText = Get-Content -LiteralPath $envFile -Raw
if ($envText -notmatch '(?m)^\s*COMPUTER_TOKEN\s*=\s*\S+') {
  throw 'COMPUTER_TOKEN is missing or empty in .env; the local Chrome helper requires the API token.'
}
$agentUrlLine = $envText -split "`r?`n" |
  Where-Object { $_ -match '^\s*AGENT_COMPUTER_URL\s*=' } |
  Select-Object -First 1
$agentUrl = if ($agentUrlLine) {
  ($agentUrlLine -replace '^\s*AGENT_COMPUTER_URL\s*=\s*', '').Trim().Trim('"').Trim("'")
} else {
  ''
}
if ($agentUrl -ne 'http://127.0.0.1:4102') {
  throw 'Set AGENT_COMPUTER_URL=http://127.0.0.1:4102 in .env before using the WSL bridge.'
}

function ConvertTo-PowerShellLiteral([string]$Value) {
  "'" + $Value.Replace("'", "''") + "'"
}

function Start-ServiceTerminal([string]$Title, [string]$CommandText) {
  $terminalScript = "`$Host.UI.RawUI.WindowTitle = $(ConvertTo-PowerShellLiteral $Title)`r`n$CommandText"
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($terminalScript))
  $powerShellPath = (Get-Process -Id $PID).Path
  Start-Process -FilePath $powerShellPath -ArgumentList @('-NoExit', '-EncodedCommand', $encodedCommand) | Out-Null
  Write-Host "Opened terminal: $Title"
}

function Test-LocalTcpPort([string]$HostName, [int]$Port) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $connect = $client.ConnectAsync($HostName, $Port)
    if (-not $connect.Wait(700)) { return $false }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

$repoDrive = [System.IO.Path]::GetPathRoot($repoRoot)
if ($repoDrive -notmatch '^([A-Za-z]):\\$') {
  throw "The checkout must be on a Windows drive mounted under /mnt in WSL; found '$repoRoot'."
}
$driveLetter = $Matches[1].ToLowerInvariant()
$relativeRepoPath = $repoRoot.Substring($repoDrive.Length).Replace([char]92, [char]47)
$wslRoot = "/mnt/$driveLetter/$relativeRepoPath"
$wslRootArgument = ConvertTo-PowerShellLiteral $wslRoot
& wsl.exe -d $Distro --exec test -d $wslRoot
if ($LASTEXITCODE -ne 0) {
  throw "The checkout path '$wslRoot' is not accessible in WSL distribution '$Distro'."
}

$listenerLines = @(& wsl.exe -d $Distro --exec ss -ltnH)
if ($LASTEXITCODE -ne 0) {
  throw "Could not inspect WSL listeners in '$Distro'. Check that the distribution is running and has ss installed."
}
$wslPorts = @{}
foreach ($port in '4102', '4103', '3001', '3010') {
  $wslPorts[$port] = [bool]($listenerLines | Where-Object { "$_" -match ":$port\s" } | Select-Object -First 1)
}

$wslPrefix = "& wsl.exe -d $(ConvertTo-PowerShellLiteral $Distro) --cd $wslRootArgument --exec "

if ($wslPorts['4102'] -xor $wslPorts['4103']) {
  throw 'Only one WSL relay port (4102/4103) is listening. Stop the old relay terminal, then run this launcher again.'
}
if (-not $wslPorts['4102']) {
  Start-ServiceTerminal 'OpenBot - WSL Chrome relay' "${wslPrefix}python3 -u scripts/local-chrome-wsl-relay.py"
} else {
  Write-Host 'Already running in WSL: Chrome relay (4102/4103)'
}

if (-not $wslPorts['3001']) {
  $apiCommand = "unset COMPUTER_SUPERVISOR_URL COMPUTER_SANDBOX_NAMESPACE; export AGENT_COMPUTER_URL=http://127.0.0.1:4102; exec /home/steven/.bun/bin/bun run --filter server dev"
  Start-ServiceTerminal 'OpenBot - WSL API' "$wslPrefix bash -lc $(ConvertTo-PowerShellLiteral $apiCommand)"
} else {
  Write-Host 'Already running in WSL: API (3001)'
}

if (-not $wslPorts['3010']) {
  $appCommand = 'exec /home/steven/.bun/bin/bun run --cwd app dev'
  Start-ServiceTerminal 'OpenBot - WSL app' "$wslPrefix bash -lc $(ConvertTo-PowerShellLiteral $appCommand)"
} else {
  Write-Host 'Already running in WSL: app (3010)'
}

$helperReady = $false
try {
  $health = Invoke-RestMethod -Uri 'http://127.0.0.1:4101/health' -TimeoutSec 2
  $helperReady = $health.status -eq 'ok' -and $health.browserBackend -eq 'local-chrome'
} catch {
  $helperReady = $false
}
if (-not $helperReady) {
  if (Test-LocalTcpPort '127.0.0.1' 4101) {
    throw 'Port 4101 is occupied by a service that is not the expected local-chrome helper. Stop it before retrying.'
  }
  $helperCommand = @"
Set-Location -LiteralPath $(ConvertTo-PowerShellLiteral $repoRoot)
`$env:COMPUTER_BIND_HOST = '127.0.0.1'
`$env:PORT = '4101'
`$env:COMPUTER_BROWSER_BACKEND = 'local-chrome'
`$env:COMPUTER_BROWSER_MODE = 'headed'
& bun --env-file=.env scripts/start-local-chrome-computer.ts
if (`$LASTEXITCODE -ne 0) { Write-Host 'The Chrome helper exited with an error; see the message above.' -ForegroundColor Red }
"@
  Start-ServiceTerminal 'OpenBot - Windows Chrome helper' $helperCommand
} else {
  Write-Host 'Already running: Windows Chrome helper (4101)'
}

$tunnelRunning = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*local-chrome-windows-tunnel.mjs*' } |
  Select-Object -First 1
if (-not $tunnelRunning) {
  $tunnelCommand = @"
Set-Location -LiteralPath $(ConvertTo-PowerShellLiteral $repoRoot)
& node scripts/local-chrome-windows-tunnel.mjs
"@
  Start-ServiceTerminal 'OpenBot - Windows WSL tunnel' $tunnelCommand
} else {
  Write-Host 'Already running: Windows-to-WSL tunnel'
}

Write-Host ''
Write-Host 'OpenBot local Chrome services are running or starting.' -ForegroundColor Green
Write-Host 'Keep the opened terminals running. The app is at http://localhost:3010/.'
Write-Host 'This launcher does not start Docker or open Chrome; Chrome starts when a Bot uses the computer.'

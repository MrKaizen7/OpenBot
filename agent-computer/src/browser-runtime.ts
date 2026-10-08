import { browserModeFromEnv, type BrowserMode } from "./browser-mode";

export type BrowserRuntime = {
  backend: "managed" | "local-chrome";
  channel: "chromium" | "chrome";
  mode: BrowserMode;
  useVirtualDisplay: boolean;
  hostname?: string;
  allowExec: boolean;
};

function isPrivateIPv4(address: string): boolean {
  const parts = address.split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) {
    return false;
  }
  const octets = parts.map(Number);
  if (octets.some((octet) => octet < 0 || octet > 255)) return false;
  return (
    octets[0] === 127 ||
    octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168)
  );
}

/** The same launch decision is used by profiles and the computer HTTP process. */
export function browserRuntimeFromEnv(
  env: Record<string, string | undefined>,
  platform: string = process.platform,
): BrowserRuntime {
  const backend = env.COMPUTER_BROWSER_BACKEND?.trim() || "managed";
  if (backend !== "managed" && backend !== "local-chrome") {
    throw new Error(
      "COMPUTER_BROWSER_BACKEND must be managed or local-chrome.",
    );
  }
  const local = backend === "local-chrome";
  const mode = browserModeFromEnv(
    env.COMPUTER_BROWSER_MODE?.trim() || (local ? "headed" : "headless"),
  );
  if (local && mode !== "headed") {
    throw new Error(
      "COMPUTER_BROWSER_BACKEND=local-chrome requires COMPUTER_BROWSER_MODE=headed.",
    );
  }
  const bindHost = env.COMPUTER_BIND_HOST?.trim() || "127.0.0.1";
  if (local && !isPrivateIPv4(bindHost)) {
    throw new Error(
      "COMPUTER_BIND_HOST must be a loopback or private IPv4 address; wildcard and public addresses are refused.",
    );
  }
  if (!local && env.COMPUTER_BIND_HOST?.trim()) {
    throw new Error(
      "COMPUTER_BIND_HOST is only supported with COMPUTER_BROWSER_BACKEND=local-chrome.",
    );
  }
  return {
    backend,
    channel: local ? "chrome" : "chromium",
    mode,
    useVirtualDisplay: platform === "linux" && mode === "headed",
    ...(local ? { hostname: bindHost } : {}),
    allowExec: !local,
  };
}

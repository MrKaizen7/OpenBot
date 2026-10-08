import net from "node:net";

const localComputerHost = process.env.OPENBOT_LOCAL_CHROME_HOST ?? "127.0.0.1";
const localComputerPort = Number(process.env.OPENBOT_LOCAL_CHROME_PORT ?? 4101);
const relayHost = process.env.OPENBOT_WSL_RELAY_HOST ?? "127.0.0.1";
const relayPort = Number(process.env.OPENBOT_WSL_TUNNEL_PORT ?? 4103);
const connections = Math.max(
  1,
  Math.min(8, Number(process.env.OPENBOT_LOCAL_CHROME_TUNNELS ?? 4)),
);

function connect(host, port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port });
    const timer = setTimeout(() => {
      socket.destroy(new Error(`Connection to ${host}:${port} timed out`));
    }, 10_000);
    socket.once("connect", () => {
      clearTimeout(timer);
      resolve(socket);
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function tunnel(index) {
  let delayMs = 500;
  while (true) {
    let browser;
    let relay;
    try {
      // Hold only a WSL loopback socket while idle. An empty TCP connection to Bun's
      // HTTP server is treated as a malformed request and is closed, so open Chrome
      // only after the relay signals that an API request is waiting.
      relay = await connect(relayHost, relayPort);
      delayMs = 500;
      const signal = await new Promise((resolve, reject) => {
        const onData = (chunk) => {
          relay.pause();
          resolve(chunk);
        };
        relay.once("data", onData);
        relay.once("error", reject);
        relay.once("close", () => reject(new Error("WSL relay closed")));
      });
      if (signal[0] !== 1) {
        throw new Error("Unexpected WSL relay signal.");
      }
      const pendingRequest = signal.subarray(1);
      browser = await connect(localComputerHost, localComputerPort);
      if (pendingRequest.length > 0) browser.write(pendingRequest);
      browser.pipe(relay);
      relay.pipe(browser);
      await new Promise((resolve) => {
        const close = () => resolve();
        browser.once("close", close);
        relay.once("close", close);
        browser.once("error", close);
        relay.once("error", close);
      });
    } catch (error) {
      console.error(
        `Local Chrome tunnel ${index}: ${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      browser?.destroy();
      relay?.destroy();
    }
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    delayMs = Math.min(delayMs * 2, 10_000);
  }
}

console.info(
  `Connecting ${connections} local Chrome tunnel(s): ${localComputerHost}:${localComputerPort} ↔ WSL localhost:${relayPort}.`,
);
await Promise.all(
  Array.from({ length: connections }, (_, index) => tunnel(index + 1)),
);
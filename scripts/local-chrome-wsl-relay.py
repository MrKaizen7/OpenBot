#!/usr/bin/env python3
"""Pair OpenBot's WSL API connections with Windows-initiated Chrome tunnels."""

import asyncio
import contextlib
import os
import time
from dataclasses import dataclass

APP_HOST = "127.0.0.1"
APP_PORT = int(os.environ.get("OPENBOT_LOCAL_CHROME_RELAY_PORT", "4102"))
TUNNEL_HOST = "127.0.0.1"
TUNNEL_PORT = int(os.environ.get("OPENBOT_LOCAL_CHROME_TUNNEL_PORT", "4103"))
WAIT_SECONDS = 45


@dataclass
class Peer:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    paired: asyncio.Future[None]
    created_at: float


class Relay:
    def __init__(self) -> None:
        self.app_waiting: list[Peer] = []
        self.tunnel_waiting: list[Peer] = []
        self.lock = asyncio.Lock()

    async def accept_app(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        await self._accept(reader, writer, self.app_waiting, self.tunnel_waiting)

    async def accept_tunnel(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        await self._accept(reader, writer, self.tunnel_waiting, self.app_waiting)

    async def _accept(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        own_queue: list[Peer],
        other_queue: list[Peer],
    ) -> None:
        peer = Peer(
            reader=reader,
            writer=writer,
            paired=asyncio.get_running_loop().create_future(),
            created_at=time.monotonic(),
        )
        partner: Peer | None = None
        async with self.lock:
            self._discard_expired(own_queue)
            self._discard_expired(other_queue)
            if other_queue:
                partner = other_queue.pop(0)
            else:
                own_queue.append(peer)

        if partner is not None:
            partner.writer.write(b"\x01")
            await partner.writer.drain()
            peer.paired.set_result(None)
            partner.paired.set_result(None)
            asyncio.create_task(self._bridge(peer, partner))
        try:
            await asyncio.wait_for(asyncio.shield(peer.paired), timeout=WAIT_SECONDS)
        except TimeoutError:
            async with self.lock:
                with contextlib.suppress(ValueError):
                    own_queue.remove(peer)
            await self._close(writer)
        except asyncio.CancelledError:
            async with self.lock:
                with contextlib.suppress(ValueError):
                    own_queue.remove(peer)
            await self._close(writer)
            raise

    @staticmethod
    def _discard_expired(queue: list[Peer]) -> None:
        now = time.monotonic()
        kept: list[Peer] = []
        for peer in queue:
            if now - peer.created_at > WAIT_SECONDS or peer.writer.is_closing():
                peer.writer.close()
            else:
                kept.append(peer)
        queue[:] = kept

    async def _bridge(self, app: Peer, windows: Peer) -> None:
        async def copy(
            reader: asyncio.StreamReader, writer: asyncio.StreamWriter
        ) -> None:
            while True:
                chunk = await reader.read(64 * 1024)
                if not chunk:
                    with contextlib.suppress(Exception):
                        writer.write_eof()
                        await writer.drain()
                    return
                writer.write(chunk)
                await writer.drain()

        try:
            await asyncio.gather(
                copy(app.reader, windows.writer),
                copy(windows.reader, app.writer),
            )
        except (ConnectionError, OSError, asyncio.CancelledError) as error:
            print(f"relay connection closed: {error}", flush=True)
        finally:
            await asyncio.gather(
                self._close(app.writer), self._close(windows.writer)
            )

    @staticmethod
    async def _close(writer: asyncio.StreamWriter) -> None:
        if not writer.is_closing():
            writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


async def main() -> None:
    relay = Relay()
    app_server = await asyncio.start_server(
        relay.accept_app, APP_HOST, APP_PORT
    )
    tunnel_server = await asyncio.start_server(
        relay.accept_tunnel, TUNNEL_HOST, TUNNEL_PORT
    )
    print(
        f"Local Chrome relay listening: API 127.0.0.1:{APP_PORT}; "
        f"Windows tunnel 127.0.0.1:{TUNNEL_PORT}",
        flush=True,
    )
    async with app_server, tunnel_server:
        await asyncio.gather(
            app_server.serve_forever(), tunnel_server.serve_forever()
        )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
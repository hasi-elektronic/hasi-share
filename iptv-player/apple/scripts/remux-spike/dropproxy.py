#!/usr/bin/env python3
"""Fault proxy (provider simulator): forwards to 127.0.0.1:<upstream> and, after <drop_mb> MB of response body,
cuts the connection (mode drop, default) or keeps it open without sending anything more (mode hang – a stalled
live server). usage: dropproxy.py <port> <upstream> <drop_mb> [drop|hang]"""
import asyncio, sys
PORT, UP, DROP = int(sys.argv[1]), int(sys.argv[2]), int(float(sys.argv[3]) * 1024 * 1024)
HANG = len(sys.argv) > 4 and sys.argv[4] == "hang"

async def handle(cr, cw):
    try:
        ur, uw = await asyncio.open_connection("127.0.0.1", UP)
    except OSError:
        cw.close(); return
    async def up():
        try:
            while (b := await cr.read(65536)):
                uw.write(b); await uw.drain()
        except Exception: pass
        finally: uw.close()
    async def down():
        sent = 0
        try:
            while (b := await ur.read(65536)):
                cw.write(b); await cw.drain(); sent += len(b)
                if sent >= DROP:
                    if HANG:
                        await asyncio.sleep(3600)   # keep the socket open, send nothing
                    break                           # drop the connection mid-body
        except Exception: pass
        finally: cw.close()
    await asyncio.gather(up(), down())

async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server: await server.serve_forever()
asyncio.run(main())

#!/usr/bin/env python3
"""Fault proxy (provider simulator): forwards to 127.0.0.1:<upstream> and cuts every connection after
<drop_mb> MB of response body – the mid-stream drop IPTV panels do. usage: dropproxy.py <port> <upstream> <drop_mb>"""
import asyncio, sys
PORT, UP, DROP = int(sys.argv[1]), int(sys.argv[2]), int(float(sys.argv[3]) * 1024 * 1024)

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
                if sent >= DROP: break      # drop the connection mid-body
        except Exception: pass
        finally: cw.close()
    await asyncio.gather(up(), down())

async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server: await server.serve_forever()
asyncio.run(main())

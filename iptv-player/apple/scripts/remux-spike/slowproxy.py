#!/usr/bin/env python3
"""WAN-like proxy for the spike: 127.0.0.1:<port> → 127.0.0.1:8766, +RTT ms before each response
and a per-connection bandwidth cap. usage: slowproxy.py <port> <rtt_ms> <mbit>"""
import asyncio, sys, time

PORT, RTT, MBIT = int(sys.argv[1]), int(sys.argv[2]) / 1000, float(sys.argv[3])
RATE = MBIT * 1e6 / 8

async def pipe_up(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data: break
            await asyncio.sleep(RTT / 2)
            writer.write(data); await writer.drain()
    except Exception: pass
    finally:
        try: writer.close()
        except Exception: pass

async def pipe_down(reader, writer):
    try:
        first = True
        start, sent = time.monotonic(), 0
        while True:
            data = await reader.read(32768)
            if not data: break
            if first:
                await asyncio.sleep(RTT / 2); first = False
                start, sent = time.monotonic(), 0
            sent += len(data)
            ahead = sent / RATE - (time.monotonic() - start)
            if ahead > 0: await asyncio.sleep(ahead)
            writer.write(data); await writer.drain()
    except Exception: pass
    finally:
        try: writer.close()
        except Exception: pass

async def handle(cr, cw):
    try:
        ur, uw = await asyncio.open_connection("127.0.0.1", 8766)
    except Exception:
        cw.close(); return
    await asyncio.gather(pipe_up(cr, uw), pipe_down(ur, cw))

async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server: await server.serve_forever()

asyncio.run(main())

"""Go2Sleep live bridge.

BLE (Nordic UART) <-> WebSocket (ws://localhost:8765) + dashboard (http://localhost:8000).
Every raw frame is also appended to data/session-<timestamp>.jsonl for offline algorithm work.

Protocol (from yath/go2sleep + our own probing):
  host->ring: 5a <cmd> [args]      ring->host: 5b <cmd> <status> [payload]
  0x40 HEART_SPO2 : spo2, hr, wearing, charging, pi   (1 Hz)
  0x15 BATTERY    : byte3 = battery %, bytes 9-10 = u16 aux (unknown, ~1240..1265 idle), byte 11 flag
  0x14 VERSION    : ascii from byte 3
  0x1d TIME       : yy mm dd hh mm ss
"""
import asyncio, json, os, sys, time, threading, functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from bleak import BleakScanner, BleakClient
import websockets

TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
HERE = os.path.dirname(os.path.abspath(__file__))
os.makedirs(os.path.join(HERE, "data"), exist_ok=True)
LOG = open(os.path.join(HERE, "data", time.strftime("session-%Y%m%d-%H%M%S.jsonl")), "a")

clients = set()
state = {"status": "starting", "name": None, "address": None}
loop = None


def parse(b: bytes):
    if len(b) < 2 or b[0] != 0x5B:
        return {"type": "unknown"}
    cmd = b[1]
    if cmd == 0x40 and len(b) >= 7:
        return {"type": "spo2", "spo2": b[3], "hr": b[4], "wearing": b[5] > 0,
                "charging": b[6], "pi": b[7] if len(b) > 7 else 0}
    if cmd == 0x15 and len(b) >= 4:
        d = {"type": "battery", "battery": b[3]}
        if len(b) >= 12:
            d["aux"] = (b[9] << 8) | b[10]
            d["auxflag"] = b[11]
        return d
    if cmd == 0x14:
        return {"type": "version", "version": bytes(b[3:]).decode("ascii", "replace")}
    if cmd == 0x1D and len(b) >= 9:
        return {"type": "ringtime", "time": "20%02d-%02d-%02d %02d:%02d:%02d" % tuple(b[3:9])}
    return {"type": "other", "cmd": cmd}


def broadcast(msg):
    data = json.dumps(msg)
    for ws in list(clients):
        asyncio.ensure_future(_safe_send(ws, data))


async def _safe_send(ws, data):
    try:
        await ws.send(data)
    except Exception:
        clients.discard(ws)


def set_status(s, **kw):
    state.update(status=s, **kw)
    print("STATUS", s, flush=True)
    broadcast({"type": "status", **state})


async def ble_loop():
    while True:
        try:
            set_status("scanning")
            dev = await BleakScanner.find_device_by_filter(
                lambda d, a: (d.name or a.local_name or "").startswith("Go2Sleep"), timeout=20)
            if not dev:
                continue
            gone = asyncio.Event()
            set_status("connecting", name=dev.name, address=dev.address)
            async with BleakClient(dev, timeout=20,
                                   disconnected_callback=lambda _: loop.call_soon_threadsafe(gone.set)) as c:
                got_data = asyncio.Event()

                def on_rx(_, data):
                    b = bytes(data)
                    msg = parse(b)
                    msg.update(t=time.time(), raw=b.hex())
                    LOG.write(json.dumps(msg) + "\n"); LOG.flush()
                    got_data.set()
                    broadcast(msg)

                await c.start_notify(RX, on_rx)
                set_status("waiting-for-ring")
                # the ring only starts answering ~9s after connect; poke with acknowledged writes
                while not got_data.is_set() and not gone.is_set():
                    await c.write_gatt_char(TX, b"\x5a\x15\x00\x00", response=True)
                    await asyncio.sleep(1)
                if gone.is_set():
                    continue
                set_status("live")
                for cmd in (b"\x5a\x14", b"\x5a\x1d\x00"):
                    await c.write_gatt_char(TX, cmd, response=False)
                    await asyncio.sleep(0.4)
                while not gone.is_set():
                    await asyncio.sleep(1)
        except Exception as e:
            print("BLE error:", repr(e), flush=True)
        set_status("disconnected")
        await asyncio.sleep(2)


async def ws_handler(ws, *_):
    clients.add(ws)
    try:
        await ws.send(json.dumps({"type": "status", **state}))
        async for _ in ws:
            pass
    finally:
        clients.discard(ws)


def serve_http():
    h = functools.partial(SimpleHTTPRequestHandler, directory=HERE)
    h.log_message = lambda *a, **k: None
    ThreadingHTTPServer(("127.0.0.1", 8000), h).serve_forever()


async def main():
    global loop
    loop = asyncio.get_running_loop()
    threading.Thread(target=serve_http, daemon=True).start()
    async with websockets.serve(ws_handler, "127.0.0.1", 8765):
        print("Dashboard: http://localhost:8000/dashboard.html", flush=True)
        await ble_loop()


asyncio.run(main())

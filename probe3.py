import asyncio, time
from bleak import BleakScanner, BleakClient
TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
T0 = time.time(); last = {}
def on_rx(_, d):
    b = bytes(d); last[b[1]] = b
    if b[1] not in (0x15, 0x40) or (b[1] == 0x40 and any(b[3:])):
        print(f"[{time.time()-T0:5.1f}s] RX {b.hex(' ')}", flush=True)
async def send(c, b, wait=3):
    print(f"[{time.time()-T0:5.1f}s] TX {bytes(b).hex(' ')}   (last 40: {last.get(0x40, b'').hex(' ')})", flush=True)
    await c.write_gatt_char(TX, bytes(b), response=True)
    await asyncio.sleep(wait)
async def main():
    dev = await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"), timeout=20)
    async with BleakClient(dev, timeout=20) as c:
        await c.start_notify(RX, on_rx)
        while 0x15 not in last:
            await c.write_gatt_char(TX, b"\x5a\x15\x00\x00", response=True); await asyncio.sleep(1)
        print("awake", flush=True)
        for cmd in ([0x5a,0x30,0x01],[0x5a,0x30,0x00,0x01],[0x5a,0x30,0x01,0x00],[0x5a,0x12,0x01],
                    [0x5a,0x12,0x00,0x01],[0x5a,0x29,0x01],[0x5a,0x29,0x00,0x01],[0x5a,0x41,0x01],[0x5a,0x41,0x00],
                    [0x5a,0x0f,0x00],[0x5a,0x3c,0x00],[0x5a,0x3b,0x00]):
            await send(c, cmd)
        await asyncio.sleep(4)
asyncio.run(main()); print("DONE")

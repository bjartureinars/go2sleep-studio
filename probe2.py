import asyncio, time
from bleak import BleakScanner, BleakClient
TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
T0 = time.time()
def on_rx(_, d): print(f"[{time.time()-T0:5.1f}s] RX {bytes(d).hex(' ')}", flush=True)
def on_disc(_): print(f"[{time.time()-T0:5.1f}s] *** DISCONNECTED by ring", flush=True)
async def send(c, b, resp=False, wait=0.8):
    print(f"[{time.time()-T0:5.1f}s] TX {bytes(b).hex(' ')} resp={resp}", flush=True)
    await c.write_gatt_char(TX, bytes(b), response=resp)
    await asyncio.sleep(wait)
async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, a: (d.name or a.local_name or "").startswith("Go2Sleep"), timeout=15)
    async with BleakClient(dev, timeout=20, disconnected_callback=on_disc) as c:
        print("CONNECTED", flush=True)
        await c.start_notify(RX, on_rx)
        await asyncio.sleep(1.5)
        for resp in (True, False):
            for cmd in ([0x5a,0x14],[0x5a,0x14,0x00],[0x5a,0x15,0x00],[0x5a,0x15,0x00,0x00],
                        [0x5a,0x1d,0x00],[0x5a,0x12,0x00,0x01],[0x5a,0x30,0x00,0x01],[0x5a,0x40,0x00]):
                if not c.is_connected: return
                await send(c, cmd, resp)
        await asyncio.sleep(5)
asyncio.run(main())
print("DONE")

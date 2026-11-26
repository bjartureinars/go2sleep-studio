"""Connect to the Go2Sleep ring, dump GATT, subscribe, and probe commands."""
import asyncio, time
from bleak import BleakScanner, BleakClient

TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
T0 = time.time()

def on_rx(_, data: bytearray):
    print(f"[{time.time()-T0:6.1f}s] RX {bytes(data).hex(' ')}", flush=True)

async def send(c, *b, wait=2.0):
    print(f"[{time.time()-T0:6.1f}s] TX {bytes(b).hex(' ')}", flush=True)
    await c.write_gatt_char(TX, bytes(b), response=False)
    await asyncio.sleep(wait)

async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, a: (d.name or a.local_name or "").startswith("Go2Sleep"), timeout=15)
    if not dev:
        print("ring not found"); return
    print("found", dev.name, dev.address, flush=True)
    async with BleakClient(dev, timeout=20) as c:
        print("CONNECTED", flush=True)
        for s in c.services:
            print("SERVICE", s.uuid)
            for ch in s.characteristics:
                print("   CHAR", ch.uuid, ch.properties)
        await c.start_notify(RX, on_rx)
        await send(c, 0x5a, 0x14)            # version
        await send(c, 0x5a, 0x15)            # battery
        await send(c, 0x5a, 0x02)            # BLE_TYPE
        await send(c, 0x5a, 0x03)            # BLE_SN
        await send(c, 0x5a, 0x1d)            # GET_BLE_TIME
        await send(c, 0x5a, 0x0f)            # CURRENT_HEART
        print("--- listening passively 8s ---", flush=True)
        await asyncio.sleep(8)
        await send(c, 0x5a, 0x12, 0x01, wait=6)   # REAL_HEART_SWITCH on?
        await send(c, 0x5a, 0x30, 0x01, wait=6)   # HEART_SPO2_SWITCH on?
        await send(c, 0x5a, 0x40, wait=6)         # HEART_SPO2 request?
        print("--- listening 10s ---", flush=True)
        await asyncio.sleep(10)
    print("DISCONNECTED")

asyncio.run(main())

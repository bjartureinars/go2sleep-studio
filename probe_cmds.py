"""Try payload shapes on documented non-destructive commands; log replies per TX; flag non-zero live frames."""
import asyncio, sys, time
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
SAFE=[0x03,0x0b,0x0f,0x12,0x14,0x1d,0x29,0x30,0x38,0x3e,0x3f,0x41,0x42,0x43,0x44]
PAY=[[],[0],[1],[2],[0,1],[1,0],[1,1],[0,0],[0xff]]
DENY={0x02,0x1b,0x1e,0x1f,0x20,0x21,0x22,0x23,0x25,0x32,0x33,0x34,0x35,0xe0,0xe1,0x3b,0x3c}
T0=time.time(); buf=[]; nonzero=[]
def on_rx(_,d):
    b=bytes(d)
    if b[1]==0x40 and any(b[3:]): nonzero.append((time.time()-T0,b.hex(' ')))
    if b[1] in (0x15,0x40): return
    buf.append(b.hex(' '))
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx)
        t=time.time()
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        print("awake. baseline:",flush=True)
        async def tx(cmd,p):
            assert cmd not in DENY
            buf.clear(); await c.write_gatt_char(TX,bytes([0x5a,cmd,*p]),response=True); await asyncio.sleep(0.7)
            return list(buf)
        for cmd in (0x29,0x30): print(f"  5a {cmd:02x} ->",await tx(cmd,[]),flush=True)
        for cmd in SAFE:
            for p in PAY:
                if not c.is_connected: print("!! disconnected at",hex(cmd),p); return
                r=await tx(cmd,p)
                print(f"5a {cmd:02x} {bytes(p).hex(' '):6s} -> {r if r else '(silent)'}",flush=True)
        print("--- post-check"); 
        for cmd in (0x29,0x30): print(f"  5a {cmd:02x} ->",await tx(cmd,[]),flush=True)
        print("NONZERO LIVE FRAMES:",nonzero if nonzero else "none",flush=True)
asyncio.run(main()); print("DONE")

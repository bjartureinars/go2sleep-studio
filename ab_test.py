"""Causal A/B: is HEART_SPO2_SWITCH (0x30) what starts the live sensor? Ring must stay ON the finger."""
import asyncio, time, json
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
PLAN=[(0,30,None,"baseline: NO command (ring worn)"),(30,60,b"\x5a\x30\x00\x01","0x30 ON  (5a 30 00 01)"),(60,85,b"\x5a\x30\x00\x00","0x30 OFF (5a 30 00 00)"),(85,115,b"\x5a\x30\x00\x01","0x30 ON again")]
log=[]; T0=[None]
def on_rx(_,d):
    b=bytes(d)
    if T0[0] and b[1] in (0x40,0x30): log.append((round(time.time()-T0[0],1),b.hex(" ")))
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx); t=time.time()
        print("\a== KEEP THE RING ON YOUR FINGER, STILL ==",flush=True)
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        T0[0]=time.time(); done=set()
        while time.time()-T0[0]<PLAN[-1][1]:
            el=time.time()-T0[0]
            for i,(a,b,cmd,msg) in enumerate(PLAN):
                if el>=a and i not in done:
                    done.add(i); print(f"[{el:5.1f}s] {msg}",flush=True)
                    if cmd: await c.write_gatt_char(TX,cmd,response=True)
            await asyncio.sleep(0.25)
    json.dump(log,open("data/ab_test.json","w"))
asyncio.run(main()); print("DONE")

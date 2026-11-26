"""Controlled finger test. Phases: OFF (table) -> ON (finger, still) -> OFF. Logs aux (0x15 frame), 0x29 register, 0x40 live frame."""
import asyncio, time, json
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
PHASES=[(0,25,"GET READY - ring lying on the TABLE, not touching it"),(25,55,"RING OFF: leave it on the table"),(55,115,"PUT THE RING ON NOW (index/middle finger, snug, sensor side on the palm side). Keep still."),(115,145,"TAKE THE RING OFF and lay it on the table")]
log=[]; T0=[None]
def on_rx(_,d):
    b=bytes(d)
    if T0[0] is None: return
    log.append((round(time.time()-T0[0],2),b.hex()))
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx); t=time.time()
        print("connecting... waiting for ring to wake (11 s)",flush=True)
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        T0[0]=time.time(); last=-1
        while time.time()-T0[0]<PHASES[-1][1]:
            el=time.time()-T0[0]
            for i,(a,b,msg) in enumerate(PHASES):
                if a<=el<b and i!=last: last=i; print(f"\a\n===== [{int(el):3d}s] {msg} =====",flush=True)
            await c.write_gatt_char(TX,b"\x5a\x29\x00",response=True); await asyncio.sleep(0.5)
    json.dump(log,open("data/fingertest.json","w")); print("saved",len(log),"frames")
asyncio.run(main()); print("DONE")

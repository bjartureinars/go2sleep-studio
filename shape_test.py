"""Replay each 0x30 payload shape from the fuzz, one by one, watching for the first nonzero live frame. Ring must be ON finger."""
import asyncio, time
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
shapes=[]
for k in range(1,8): shapes.append([0]+[1]*k)
for k in range(1,8): shapes.append([0]+[0]*k)
shapes+=[[0,1,0,0,0,0,0,0,0,0],[0,0xaa],[0,0x55],[1,1],[1,0,1]]
cur=["(start)"]; seen=[]; live=[]
def on_rx(_,d):
    b=bytes(d)
    if b[1]==0x40:
        live.append((time.time(),b))
        if any(b[3:]) and not seen: seen.append(cur[0]); print(f"   >>> FIRST NONZERO LIVE during shape {cur[0]}: {b.hex(' ')}",flush=True)
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx); t=time.time()
        print("\a== KEEP THE RING ON YOUR FINGER, STILL ==",flush=True)
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        for p in shapes:
            cur[0]=bytes(p).hex(" "); n0=len(live)
            await c.write_gatt_char(TX,bytes([0x5a,0x30,*p]),response=True); await asyncio.sleep(4)
            nz=sum(1 for _,b in live[n0:] if any(b[3:])); print(f"5a 30 {cur[0]:24s} -> live frames {len(live)-n0}, nonzero {nz}",flush=True)
asyncio.run(main()); print("DONE")

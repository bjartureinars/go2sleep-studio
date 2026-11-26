"""1) restore 0x43 state  2) check ring clock vs wall clock  3) set ring clock (yy mm dd hh mi ss)  4) retry gated commands + poll 0x29."""
import asyncio, time, datetime as dt
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
buf=[]; live=[]
def on_rx(_,d):
    b=bytes(d)
    if b[1]==0x40: live.append((time.time(),b.hex(' ')))
    if b[1] in (0x15,0x40): return
    buf.append(b.hex(' '))
def ringtime(h): b=bytes.fromhex(h.replace(' ','')); return "20%02d-%02d-%02d %02d:%02d:%02d"%tuple(b[3:9]) if b[1]==0x1d else h
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx)
        t=time.time()
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        async def tx(*b,wait=0.8):
            buf.clear(); await c.write_gatt_char(TX,bytes([0x5a,*b]),response=True); await asyncio.sleep(wait); return list(buf)
        print("restore 0x43: send 5a 43 00 ->",await tx(0x43,0x00)); print("query  5a 43       ->",await tx(0x43))
        r=await tx(0x1d); print("wall clock now:",dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")," | ring clock:",ringtime(r[0]) if r else r)
        n=dt.datetime.now(); payload=[n.year-2000,n.month,n.day,n.hour,n.minute,n.second]
        print("SET TIME 5a 1e",bytes(payload).hex(' '),"->",await tx(0x1e,*payload))
        r=await tx(0x1d); print("ring clock after set:",ringtime(r[0]) if r else r)
        print("--- retry gated commands after time set")
        for cmd,p in [(0x12,[1]),(0x12,[0,1]),(0x0f,[]),(0x41,[]),(0x41,[1]),(0x38,[]),(0x0b,[]),(0x3e,[]),(0x3f,[]),(0x42,[])]:
            print(f"5a {cmd:02x} {bytes(p).hex(' '):5s} ->",await tx(cmd,*p,wait=0.8) or "(silent)")
        print("--- polling 0x29 and live frame for 25 s (put finger in ring now if not already)")
        for i in range(25):
            r=await tx(0x29,wait=0.6); l=live[-1][1] if live else "-"
            print(f"  t+{i:2d}s 0x29={r[0] if r else '-'}   live40={l}",flush=True)
        nz=[x for x in live if any(bytes.fromhex(x[1].replace(' ',''))[3:])]
        print("NONZERO LIVE FRAMES:",len(nz),nz[:5])
asyncio.run(main()); print("DONE")

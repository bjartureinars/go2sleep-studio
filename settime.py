"""Set the ring clock using layout 5a 1e <status=00> yy mm dd hh mi ss, verify by reading 0x1d; then retry gated commands."""
import asyncio, time, datetime as dt
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
buf=[]; live=[]
def on_rx(_,d):
    b=bytes(d)
    if b[1]==0x40: live.append(b)
    if b[1] in (0x15,0x40): return
    buf.append(b)
def rt(b): return "20%02d-%02d-%02d %02d:%02d:%02d"%tuple(b[3:9])
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx); t=time.time()
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        async def tx(*b,wait=0.8):
            buf.clear(); await c.write_gatt_char(TX,bytes([0x5a,*b]),response=True); await asyncio.sleep(wait); return list(buf)
        r=await tx(0x1d); print("ring clock before:",rt(r[0]))
        n=dt.datetime.now(); p=[0x00,n.year-2000,n.month,n.day,n.hour,n.minute,n.second]
        print("5a 1e",bytes(p).hex(" "),"->",[x.hex(" ") for x in await tx(0x1e,*p)])
        r=await tx(0x1d); print("ring clock after :",rt(r[0]),"| wall:",dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        ok=abs((dt.datetime.strptime(rt(r[0]),"%Y-%m-%d %H:%M:%S")-dt.datetime.now()).total_seconds())<5; print("CLOCK OK" if ok else "CLOCK STILL WRONG")
        print("--- retry gated commands")
        for cmd,p in [(0x12,[0,1]),(0x12,[0,0]),(0x0f,[0]),(0x41,[0]),(0x38,[0]),(0x0b,[0]),(0x3e,[0]),(0x3f,[0]),(0x42,[0])]:
            print(f"5a {cmd:02x} {bytes(p).hex(' '):5s} ->",[x.hex(' ') for x in await tx(cmd,*p)] or "(silent)")
        print("--- live frame for 20 s"); 
        for i in range(20):
            await asyncio.sleep(1); print("  ",live[-1].hex(" ") if live else "-",flush=True) if i%4==0 else None
        nz=[x.hex(" ") for x in live if any(x[3:])]; print("NONZERO:",len(nz),nz[:3])
asyncio.run(main()); print("DONE")

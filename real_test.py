"""Send ONLY 5a 12 00 01 (REAL_HEART_SWITCH on) and watch the live frame for 45 s. Ring must be ON the finger."""
import asyncio, time
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
T0=[None]; rows=[]
def on_rx(_,d):
    b=bytes(d)
    if T0[0] and b[1]==0x40: rows.append((time.time()-T0[0],b))
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx); t=time.time()
        print("\a== PUT THE RING ON YOUR FINGER NOW AND KEEP STILL ==",flush=True)
        while time.time()-t<15: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        T0[0]=time.time(); await c.write_gatt_char(TX,b"\x5a\x12\x00\x01",response=True); print("sent 5a 12 00 01",flush=True)
        last=None
        while time.time()-T0[0]<45:
            await asyncio.sleep(1)
            if rows and rows[-1][1]!=last: last=rows[-1][1]; b=last; print(f"[{rows[-1][0]:4.1f}s] spo2={b[3]} hr={b[4]} worn={b[5]} chg={b[6]} pi={b[7] if len(b)>7 else '-'}   raw={b.hex(' ')}",flush=True)
        nz=[r for r in rows if any(r[1][3:])]; print(f"frames={len(rows)} nonzero={len(nz)}" + (f" first nonzero at {nz[0][0]:.1f}s" if nz else ""))
asyncio.run(main()); print("DONE")

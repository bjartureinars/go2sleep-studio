"""Clean attribution run with ring confirmed ON finger: A baseline (no cmd) -> B 0x30 on -> C 0x12 on."""
import asyncio, time
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
PLAN=[("A baseline, NO command",None),("B  5a 30 00 01 (HEART_SPO2_SWITCH on)",b"\x5a\x30\x00\x01"),("C  5a 12 00 01 (REAL_HEART_SWITCH on)",b"\x5a\x12\x00\x01")]
T0=[None]; rows=[]; phase=[""]
def on_rx(_,d):
    b=bytes(d)
    if T0[0] and b[1]==0x40: rows.append((time.time()-T0[0],phase[0][0],b))
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx); t=time.time()
        print("\a== keep ring ON finger, still ==",flush=True)
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        T0[0]=time.time(); last=None
        for name,cmd in PLAN:
            phase[0]=name; print(f"\n[{time.time()-T0[0]:5.1f}s] PHASE {name}",flush=True)
            if cmd: await c.write_gatt_char(TX,cmd,response=True)
            end=time.time()+45
            while time.time()<end:
                await asyncio.sleep(1)
                if rows and rows[-1][2]!=last:
                    last=rows[-1][2]; b=last; print(f"   [{rows[-1][0]:5.1f}s] spo2={b[3]} hr={b[4]} worn={b[5]} chg={b[6]} pi={b[7] if len(b)>7 else '-'}  raw={b.hex(' ')}",flush=True)
        for p in "ABC":
            f=[r for r in rows if r[1]==p]; nz=[r for r in f if any(r[2][3:])]; print(f"phase {p}: frames={len(f)} nonzero={len(nz)}")
asyncio.run(main()); print("DONE")

"""Send read-only commands to the ring and log every frame until the line goes quiet.
usage: capture.py OUTFILE QUIET_SECONDS HEXCMD [HEXCMD ...]   e.g. 5a3800 5a3f00"""
import asyncio, sys, time
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
BLOCK={0x1b,0x1f,0x32,0x33,0x35,0xe0,0x1e}   # never send: clear flash, reset, write SN, restart, set time
out, quiet, cmds = sys.argv[1], float(sys.argv[2]), [bytes.fromhex(a) for a in sys.argv[3:]]
for c in cmds:
    assert c[1] not in BLOCK, f"blocked command {c.hex()}"
f=open(out,"w"); T0=time.time(); last=[time.time()]; n=[0]
def on_rx(_,d):
    b=bytes(d)
    if b[1] in (0x15,0x40): return          # skip 1 Hz idle chatter
    last[0]=time.time(); n[0]+=1
    f.write(f"{time.time()-T0:.3f} {b.hex()}\n"); f.flush()
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx)
        seen=[]
        while time.time()-T0<30:               # wake-up poke
            await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True)
            await asyncio.sleep(1)
            if time.time()-T0>11: break
        for cmd in cmds:
            f.write(f"# TX {cmd.hex()}\n"); print("TX",cmd.hex(),flush=True)
            last[0]=time.time()
            await c.write_gatt_char(TX,cmd,response=True)
            while time.time()-last[0]<quiet: await asyncio.sleep(0.5)
            print("  frames so far",n[0],flush=True)
asyncio.run(main()); print("DONE",n[0],"frames")

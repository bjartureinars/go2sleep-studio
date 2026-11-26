"""Fuzz payload lengths on gated commands, then sweep unlisted opcodes. Never sends DENY opcodes."""
import asyncio, time
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
DENY={0x02,0x1b,0x1e,0x1f,0x20,0x21,0x22,0x23,0x25,0x32,0x33,0x34,0x35,0x3b,0x3c,0xe0,0xe1}
KNOWN_QUIET={0x03,0x14,0x15,0x1d,0x29,0x30,0x40,0x43,0x44}      # already understood; skip in sweep
GATED=[0x12,0x30,0x0f,0x41,0x38,0x0b,0x3e,0x3f,0x42]
buf=[]; live=[]
def on_rx(_,d):
    b=bytes(d)
    if b[1]==0x40:
        if any(b[3:]): live.append(b.hex(" "))
        return
    if b[1]==0x15: return
    buf.append(b.hex(" "))
async def main():
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=20)
    async with BleakClient(dev,timeout=20) as c:
        await c.start_notify(RX,on_rx); t=time.time()
        print("\a== PUT THE RING ON YOUR FINGER AND KEEP IT ON ==",flush=True)
        while time.time()-t<11: await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        async def tx(cmd,p,wait=0.45):
            assert cmd not in DENY
            if not c.is_connected: raise SystemExit(f"!! ring disconnected after {cmd:02x} {bytes(p).hex(' ')}")
            buf.clear(); await c.write_gatt_char(TX,bytes([0x5a,cmd,*p]),response=True); await asyncio.sleep(wait); return list(buf)
        print("--- phase 1: payload-length fuzz on gated commands",flush=True)
        shapes=[]
        for k in range(1,8): shapes.append([0]+[1]*k)         # status 00 then k bytes of 01
        for k in range(1,8): shapes.append([0]+[0]*k)         # status 00 then k zero bytes
        shapes+= [[0,1,0,0,0,0,0,0,0,0],[0,0xaa],[0,0x55],[1,1],[1,0,1]]
        for cmd in GATED:
            hit=[]
            for p in shapes:
                r=await tx(cmd,p)
                if r: hit.append((bytes(p).hex(' '),r))
            print(f"5a {cmd:02x}: {len(hit)} replies / {len(shapes)} shapes", (hit[:3] if hit else ""),flush=True)
            if live: print("   !!! NONZERO LIVE:",live[-3:],flush=True)
        print("--- phase 2: unlisted opcode sweep with payload 00",flush=True)
        for cmd in range(0x00,0x50):
            if cmd in DENY or cmd in KNOWN_QUIET or cmd in GATED or cmd in (0x0c,): continue
            r=await tx(cmd,[0])
            if r: print(f"5a {cmd:02x} 00 -> {r}",flush=True)
        print("NONZERO LIVE FRAMES:",live[:5] if live else "none")
asyncio.run(main()); print("DONE")

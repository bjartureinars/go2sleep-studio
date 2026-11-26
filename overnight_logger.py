"""Overnight Go2Sleep logger (runs in Terminal.app, which has Bluetooth permission).

Every SLOT minutes it connects for BURST minutes, logs every frame to data/overnight/<date>.jsonl,
and executes queued test commands from data/overnight/queue.txt (one hex command per line, e.g. `5a1200 01`,
optional `wait=SECONDS` suffix). Executed lines move to queue_done.txt with a timestamp.
Touch data/overnight/PAUSE to make it stay disconnected (so another app can use the ring).
status.json is rewritten every few seconds.
"""
import asyncio, json, os, time, datetime as dt, traceback
from bleak import BleakScanner, BleakClient
TX="6e400002-b5a3-f393-e0a9-e50e24dcca9e"; RX="6e400003-b5a3-f393-e0a9-e50e24dcca9e"
D=os.path.join(os.path.dirname(os.path.abspath(__file__)),"data","overnight")
SLOT=30*60; BURST=10*60
DENY={0x02,0x12,0x54,0x1b,0x1e,0x1f,0x20,0x21,0x22,0x23,0x24,0x25,0x32,0x33,0x34,0x35,0xe0,0xe1}
st={"started":time.time(),"bursts":0,"frames":0,"nonzero_live":0,"last_nonzero":None,"last_connect":None,"state":"idle","last_error":None}
def save(): json.dump(st,open(os.path.join(D,"status.json"),"w"),indent=1,default=str)
def logf(): return open(os.path.join(D,dt.datetime.now().strftime("%Y%m%d")+".jsonl"),"a")
async def run_queue(c,lf):
    q=os.path.join(D,"queue.txt")
    if not os.path.exists(q): return
    lines=[l.strip() for l in open(q) if l.strip() and not l.startswith("#")]
    open(q,"w").close()
    for l in lines:
        parts=l.split(); wait=3.0; hx=""
        for p in parts:
            if p.startswith("wait="): wait=float(p[5:])
            else: hx+=p
        b=bytes.fromhex(hx)
        if len(b)<2 or b[0]!=0x5a or b[1] in DENY:
            res="REFUSED"
        else:
            await c.write_gatt_char(TX,b,response=True); lf.write(json.dumps({"t":time.time(),"tx":b.hex()})+"\n"); lf.flush()
            await asyncio.sleep(wait); res="sent"
        with open(os.path.join(D,"queue_done.txt"),"a") as f: f.write(f"{dt.datetime.now():%H:%M:%S} {res} {l}\n")
async def burst():
    st["state"]="scanning"; save()
    dev=await BleakScanner.find_device_by_filter(lambda d,a:(d.name or a.local_name or "").startswith("Go2Sleep"),timeout=60)
    if not dev: st["state"]="not found"; st["not_found_at"]=dt.datetime.now().isoformat(timespec="seconds"); save(); return "notfound"
    lf=logf(); end=time.time()+BURST; gone=asyncio.Event()
    def on_rx(_,data):
        b=bytes(data); st["frames"]+=1
        lf.write(json.dumps({"t":time.time(),"rx":b.hex()})+"\n")
        if len(b)>7 and b[1]==0x40 and any(b[3:]):
            st["nonzero_live"]+=1; st["last_nonzero"]={"t":dt.datetime.now().isoformat(timespec="seconds"),"spo2":b[3],"hr":b[4],"worn":b[5],"pi":b[7]}
    async with BleakClient(dev,timeout=25,disconnected_callback=lambda _: gone.set()) as c:
        st["state"]="connected"; st["last_connect"]=dt.datetime.now().isoformat(timespec="seconds"); st["bursts"]+=1; save()
        lf.write(json.dumps({"t":time.time(),"event":"connect"})+"\n")
        await c.start_notify(RX,on_rx)
        t0=time.time()
        while time.time()-t0<15 and not gone.is_set():
            await c.write_gatt_char(TX,b"\x5a\x15\x00\x00",response=True); await asyncio.sleep(1)
        passive_until=time.time()+180
        while time.time()<end and not gone.is_set():
            if os.path.exists(os.path.join(D,"PAUSE")): break
            if time.time()>passive_until: await run_queue(c,lf)
            save(); await asyncio.sleep(3)
        lf.write(json.dumps({"t":time.time(),"event":"disconnect"})+"\n"); lf.close()
    st["state"]="idle"; save()
async def main():
    while True:
        slot_start=time.time()
        if not os.path.exists(os.path.join(D,"PAUSE")):
            r=None
            try: r=await burst()
            except Exception as e: st["last_error"]=repr(e)[:300]; st["state"]="error"; save(); traceback.print_exc()
            if r=="notfound":
                await asyncio.sleep(180); continue
        else: st["state"]="paused"; save()
        while time.time()-slot_start<SLOT:
            if os.path.exists(os.path.join(D,"RUN_NOW")): os.remove(os.path.join(D,"RUN_NOW")); break
            await asyncio.sleep(10)
asyncio.run(main())

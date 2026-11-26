"""Scan for nearby BLE devices and highlight likely Go2Sleep rings."""
import asyncio
from bleak import BleakScanner

NUS = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"


async def main(seconds=25):
    print(f"Scanning {seconds}s...")
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    rows = sorted(found.values(), key=lambda x: -x[1].rssi)
    for dev, adv in rows:
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        name = dev.name or adv.local_name or "?"
        flag = ""
        if NUS in uuids:
            flag += " [NORDIC-UART]"
        if any(k in name.lower() for k in ("sleep", "go2", "hst", "ring", "o2")):
            flag += " [NAME-MATCH]"
        print(f"{adv.rssi:4d} dBm  {name:28s} {dev.address}{flag}")
        if flag:
            print(f"        services={uuids} mfr={ {k: v.hex() for k, v in adv.manufacturer_data.items()} }")


asyncio.run(main())

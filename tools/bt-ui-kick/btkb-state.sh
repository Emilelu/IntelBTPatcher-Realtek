#!/bin/zsh
# Reports whether any Bluetooth HID device (keyboard) is currently connected.
# Prints: connected  |  none  |  error
out=$(/usr/sbin/system_profiler SPBluetoothDataType -json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    b = d["SPBluetoothDataType"][0]
    conn = b.get("device_connected") or []
    names = []
    for item in conn:
        for name, props in item.items():
            names.append(name)
    print("connected:" + ",".join(names) if names else "none")
except Exception:
    print("error")
' 2>/dev/null)
[ -z "$out" ] && out="error"
echo "$out"

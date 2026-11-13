#!/bin/zsh
# Blake: run btkick only when the BLE keyboard is NOT connected.
# Designed for a LaunchAgent (user session) at login plus a periodic retry.
LOG=/tmp/btkick-if-needed.log
KB=${KB_ADDR:-D3:0C:D1:FA:CA:CA}
MAXKICKS=${MAXKICKS:-2}
stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(stamp) $*" >> "$LOG"; }

connected() {
  system_profiler SPBluetoothDataType -json 2>/dev/null | /usr/bin/python3 -c '
import json,sys
kb="'"$KB"'"
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
for blk in d.get("SPBluetoothDataType",[]):
    conns=blk.get("device_connected") or []
    for c in conns:
        for name,info in c.items():
            if isinstance(info,dict) and info.get("device_address","").upper()==kb.upper():
                sys.exit(0)
sys.exit(1)
'
}

if connected; then log "keyboard $KB connected - nothing to do"; exit 0; fi

BOOT=$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/')
BOOT_KICKS=/tmp/btkick-count.$BOOT
n=$(cat "$BOOT_KICKS" 2>/dev/null || echo 0)
if [ "$n" -ge "$MAXKICKS" ]; then
  log "keyboard $KB absent but already kicked $n times this boot - giving up"
  exit 0
fi
echo $((n+1)) > "$BOOT_KICKS"
log "keyboard $KB not connected - bluetooth off/on (kick $((n+1))/$MAXKICKS)"
~/btkick.zsh 2 >> "$LOG" 2>&1
sleep 6
if connected; then log "keyboard connected after kick"; else
  log "keyboard not connected yet after kick (BLE keyboard may need a key press to advertise)"; fi

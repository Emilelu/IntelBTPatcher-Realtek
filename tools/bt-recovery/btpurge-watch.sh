#!/bin/zsh
# btpurge-watch v3 -- detect the bluetoothd corruption signature and repair it.
#
# Two independent failure modes are handled:
#   A) /usr/sbin/bluetoothd's __TEXT pages are served corrupt from the boot
#      snapshot (APFS/decmpfs read path). bluetoothd then crash-loops and the
#      controller never powers up: state=attrib_off, fw="v0 c0", addr=NULL,
#      chipset=BCM_4350C2.
#   B) macOS writes bluetoothExternalDongleFailed=%01 into NVRAM when the dongle
#      cannot be brought up, which *pins* bluetooth into the failed state even
#      after bluetoothd itself recovers. Resetting the two NVRAM variables to
#      %00 is required; config.plist already deletes+rewrites them at boot but
#      macOS re-writes %01 at runtime.
#
# Repair order: reset NVRAM -> purge -> kickstart bluetoothd -> verify.
# Second pass with a longer settle time if the first does not stick.

LOG=/var/log/btpurge-history.log
LAST=/var/run/btpurge.last
COOLDOWN=300
NVRAM=/usr/sbin/nvram

bt_info() {
  local TMP
  TMP=$(mktemp)
  /usr/sbin/system_profiler SPBluetoothDataType -json > "$TMP" 2>/dev/null
  /usr/bin/python3 - "$TMP" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("parse-error|-|-")
    raise SystemExit
root = d.get("SPBluetoothDataType") or []
if isinstance(root, list):
    root = root[0] if root else {}
c = (root.get("controller_properties") or {}) if isinstance(root, dict) else {}
print("%s|%s|%s" % (c.get("controller_state", ""),
                    c.get("controller_firmwareVersion", ""),
                    c.get("controller_address", "")))
PY
  rm -f "$TMP"
}

healthy() {
  local I STATE FW ADDR
  I=$(bt_info)
  STATE=${I%%|*}; I=${I#*|}; FW=${I%%|*}; ADDR=${I#*|}
  [ "$STATE" = "attrib_on" ] && [[ "$FW" != v0* ]] && [ "$ADDR" != "NULL" ]
}

reset_nvram() {
  $NVRAM bluetoothExternalDongleFailed=%00 2>/dev/null
  $NVRAM bluetoothInternalControllerInfo=%00%00%00%00%00%00%00%00%00%00%00%00%00%00 2>/dev/null
}

INFO=$(bt_info)
STATE=${INFO%%|*}; REST=${INFO#*|}; FW=${REST%%|*}; ADDR=${REST#*|}

if [ "$1" = "--probe" ]; then
  echo "state=$STATE fw=$FW addr=$ADDR"
  exit 0
fi

healthy && exit 0

NOW=$(date +%s)
if [ -f "$LAST" ]; then
  PREV=$(stat -f %m "$LAST" 2>/dev/null || echo 0)
  if [ $(( NOW - PREV )) -lt $COOLDOWN ]; then
    exit 0
  fi
fi
touch "$LAST"

NEWCRASH=$(find /Library/Logs/DiagnosticReports -name "*bluetoothd*.ips" -mmin -15 2>/dev/null | wc -l | tr -d ' ')
echo "$(date '+%Y-%m-%d %H:%M:%S') unhealthy state=$STATE fw=$FW addr=$ADDR crashes15m=$NEWCRASH ->nvram+purge+kickstart" >> "$LOG"

# Pass 1
reset_nvram
/usr/sbin/purge
/bin/launchctl kickstart -k system/com.apple.bluetoothd >/dev/null 2>&1
sleep 20
echo "$(date '+%Y-%m-%d %H:%M:%S') pass1: $(bt_info)" >> "$LOG"

# Pass 2 -- dongle bring-up can lag well behind bluetoothd start
if ! healthy; then
  reset_nvram
  /usr/sbin/purge
  /bin/launchctl kickstart -k system/com.apple.bluetoothd >/dev/null 2>&1
  sleep 25
  echo "$(date '+%Y-%m-%d %H:%M:%S') pass2: $(bt_info)" >> "$LOG"
fi

if [ "$1" = "--force-test" ]; then
  echo "forced test done. now: $(bt_info)"
fi

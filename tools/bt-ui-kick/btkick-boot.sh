#!/bin/zsh
# Boot-time Bluetooth watchdog.
#   1) Waits up to 120 s for the BLE keyboard to connect on its own and records
#      how long that took (this is the measurement that tells us whether the
#      "no auto reconnect" problem recurs).
#   2) If it is still not connected, performs ONE Settings-switch power cycle
#      (the only equivalent of toggling Bluetooth manually on macOS 26).
# Everything is appended to /var/log/btkick-history.log, one readable line per event.
LOG=/var/log/btkick-history.log
SSH=(/usr/bin/ssh -i /var/root/.ssh/id_localhost -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 emilelu@127.0.0.1)
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

BOOT=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')
say "=== boot=$BOOT watchdog start ==="

i=0
connected_at=""
while [ $i -lt 8 ]; do
  sleep 15
  i=$((i + 1))
  st=$(${SSH[@]} '~/btkb-state.sh' 2>/dev/null)
  case "$st" in
    connected:*)
      connected_at="+$((i * 15))s"
      say "auto-connected $connected_at state=$st"
      break
      ;;
  esac
done

if [ -n "$connected_at" ]; then
  say "=== boot=$BOOT result=auto-connected($connected_at) ==="
  exit 0
fi

say "not connected after 120s (state=${st:-unknown}) -> power cycle bluetooth once"
out=$(${SSH[@]} 'MAXKICKS=1 ~/btkick-if-needed.zsh' 2>&1)
say "kick output: $(echo "$out" | tr '\n' ' ')"

sleep 45
after=$(${SSH[@]} '~/btkb-state.sh' 2>/dev/null)
say "=== boot=$BOOT result=kicked after=${after:-unknown} ==="

#!/bin/zsh
# btKick - equivalent of manually toggling Bluetooth off/on, without touching the mouse.
# Opens System Settings > Bluetooth, presses the switch twice, then quits Settings.
# Usage: ~/btkick.zsh [gap_seconds]
GAP=${1:-2}
SW=~/btswitch

# make sure the pane exists
open "x-apple.systempreferences:com.apple.Bluetooth"
for i in {1..20}; do
  v=$($SW com.apple.systempreferences find 2>/dev/null | grep -oE 'value=[01]' | head -1 | cut -d= -f2)
  [ -n "$v" ] && break
  sleep 0.5
done
if [ -z "$v" ]; then echo "FAIL: bluetooth switch not found"; exit 1; fi
echo "initial switch value: $v"

if [ "$v" = "1" ]; then
  $SW com.apple.systempreferences press 2>&1 | grep -E 'AXPress|after='
  sleep "$GAP"
  $SW com.apple.systempreferences press 2>&1 | grep -E 'AXPress|after='
else
  # already off: single press powers it back on
  $SW com.apple.systempreferences press 2>&1 | grep -E 'AXPress|after='
fi

osascript -e 'tell application "System Settings" to quit' 2>/dev/null
echo "--- bluetoothd power transitions ---"
echo 1015 | sudo -S log show --style compact --last 40s 2>/dev/null \
  | grep -E 'bluetoothd.*(SetPowerState|Power state changed: Powered)' | tail -6

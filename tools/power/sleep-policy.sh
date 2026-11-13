#!/bin/zsh
# Keep the machine awake (clamshell included) only while on AC power.
# On battery, restore normal sleep so the laptop still saves power.
LOG=/var/log/sleep-policy.log
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

src=$(pmset -g batt 2>/dev/null | head -1)
cur=$(pmset -g 2>/dev/null | awk '/SleepDisabled/ {print $2}')

case "$src" in
  *"AC Power"*)
    want=1
    ;;
  *)
    want=0
    ;;
esac

if [ "$cur" != "$want" ]; then
  pmset -a disablesleep $want >/dev/null 2>&1
  say "power=[$src] SleepDisabled $cur -> $want"
fi

#!/bin/zsh
# Boot-time bluetooth kick: if the BLE keyboard did not come up, toggle Bluetooth
# off/on once via the Settings switch (inside an sshd session, which owns the
# Accessibility TCC grant). Max one kick per boot.
LOG=/var/log/btkick-boot.log
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

log "boot kick scheduled (pid $$)"
sleep 75
out=$(/usr/bin/ssh -i /var/root/.ssh/id_localhost -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 emilelu@127.0.0.1 'MAXKICKS=1 ~/btkick-if-needed.zsh' 2>&1)
rc=$?
log "ssh rc=$rc"
echo "$out" >> "$LOG"
log "done"

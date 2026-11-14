#!/bin/zsh
# Install the bluetoothd decompression-fix tracker as a LaunchDaemon.
#
# Why this exists: `chflags nocompressed` on /usr/sbin/bluetoothd removes the
# APFS decmpfs compression flag, which is what makes the BlueToolFixup page
# patch survivable (see docs/bluetoothd-Code-Page-Corruption.md §4). This
# daemon samples every 15 minutes so we can tell whether that actually holds
# over days, and whether a macOS update silently re-compresses the file.
#
#   sudo zsh install_btdecomp_track.zsh
#   sudo /usr/local/bin/bt-decomp-track.py --show
set -u
SRC=${0:A:h}
BIN=/usr/local/bin/bt-decomp-track.py
PLIST=/Library/LaunchDaemons/com.local.btdecomp.track.plist

if [[ $EUID -ne 0 ]]; then
  print -u2 "run as root"
  exit 1
fi

/usr/bin/install -m 755 -o root -g wheel "$SRC/bt-decomp-track.py" "$BIN" || exit 1
/usr/bin/install -m 644 -o root -g wheel "$SRC/com.local.btdecomp.track.plist" "$PLIST" || exit 1
/usr/bin/touch /var/log/bt-decomp-fix.log
/usr/sbin/chown root:wheel /var/log/bt-decomp-fix.log
/bin/chmod 644 /var/log/bt-decomp-fix.log

/bin/launchctl bootout system/com.local.btdecomp.track 2>/dev/null
/bin/launchctl bootstrap system "$PLIST" || exit 1
/bin/launchctl enable system/com.local.btdecomp.track

print "installed: $BIN"
print "plist:     $PLIST"
/bin/launchctl print system/com.local.btdecomp.track 2>/dev/null | grep -E 'state|runs|last exit' | head -3
print -- "--- first sample ---"
/usr/bin/python3 "$BIN"

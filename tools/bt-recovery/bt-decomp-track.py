#!/usr/bin/python3
"""bluetoothd decompression-fix tracker.

Records, per sample:
  - whether /usr/sbin/bluetoothd is still decompressed (no `compressed` flag)
  - bluetoothd crash-report count and the newest one
  - APFS hash_mismatch events in the kernel log (real ones only)
  - controller state

Run it from a LaunchDaemon every 15 min, or by hand. Output is one line per
sample appended to /var/log/bt-decomp-fix.log, so a multi-day picture builds up
without any dashboard.

Usage:
  bt-decomp-track.py            # sample and append
  bt-decomp-track.py --show     # print the accumulated log
"""
import json
import os
import re
import subprocess
import sys
import time

LOG = "/var/log/bt-decomp-fix.log"
BIN = "/usr/sbin/bluetoothd"
REPORTS = "/Library/Logs/DiagnosticReports"


def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.stdout
    except Exception as e:
        return "ERR:%s" % e


def is_decompressed():
    """True if the file no longer carries the APFS `compressed` flag."""
    out = run("ls -lO %s" % BIN)
    if "compressed" in out:
        return False
    return "restricted" in out or out.strip() != ""


def crash_stats():
    try:
        names = [n for n in os.listdir(REPORTS) if "bluetoothd" in n and n.endswith(".ips")]
    except Exception:
        return 0, "none"
    if not names:
        return 0, "none"
    newest = max(names, key=lambda n: os.path.getmtime(os.path.join(REPORTS, n)))
    return len(names), newest


def hash_mismatch_count():
    """Count real apfs_announce_hash_mismatch lines since boot (excludes our own log greps)."""
    boot = run("sysctl -n kern.boottime")
    m = re.search(r"sec = (\d+)", boot)
    if not m:
        return -1
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(m.group(1))))
    out = run(
        "log show --start '%s' --predicate 'eventMessage CONTAINS \"apfs_announce_hash_mismatch\"' 2>/dev/null"
        % start,
        timeout=300,
    )
    n = 0
    for line in out.splitlines():
        if "apfs_announce_hash_mismatch" in line and "args: 'log'" not in line:
            n += 1
    return n


def bt_state():
    out = run("system_profiler SPBluetoothDataType -json 2>/dev/null", timeout=120)
    try:
        d = json.loads(out)["SPBluetoothDataType"][0]["controller_properties"]
        return "%s|%s|%s" % (
            d.get("controller_state", "?"),
            d.get("controller_firmwareVersion", "?"),
            d.get("controller_address", "?"),
        )
    except Exception:
        return "?|?|?"


def main():
    if "--show" in sys.argv:
        if os.path.exists(LOG):
            sys.stdout.write(open(LOG).read())
        else:
            print("no samples yet")
        return

    crashes, newest = crash_stats()
    line = "%s decomp=%s crashes=%d newest=%s mismatch=%d bt=%s\n" % (
        time.strftime("%Y-%m-%d %H:%M:%S"),
        "yes" if is_decompressed() else "NO",
        crashes,
        newest,
        hash_mismatch_count(),
        bt_state(),
    )
    with open(LOG, "a") as f:
        f.write(line)
    sys.stdout.write(line)


if __name__ == "__main__":
    main()

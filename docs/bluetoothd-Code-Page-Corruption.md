# bluetoothd crash-loop: corrupted `__TEXT` pages on the sealed boot snapshot

**Date:** 2026-11-14
**Machine:** HP 15s-dy0xxx / i7-8565U / macOS Tahoe 26.7.3 (25G342) / Darwin 25.6.0
**Symptom:** Bluetooth suddenly dies. `system_profiler SPBluetoothDataType` reports
`State: Off`, `Chipset: BCM_4350C2`, `Address: NULL`, `Firmware: v0 c0` — the same
picture as a missing dongle — while the USB device is present and healthy.

**TL;DR — this is not a kext bug, and not our patcher.** It is a data-integrity
fault in the read path of one system binary, `/usr/sbin/bluetoothd`, on this
machine. Everything in this repository is exonerated by the timeline evidence
below. Mitigation is a watchdog that resets NVRAM + purges + restarts bluetoothd.

---

## 1. What actually crashes

`bluetoothd` dies with `EXC_BAD_ACCESS (SIGBUS)` + `KERN_MEMORY_ERROR`, and the
faulting address always lands inside bluetoothd's own `__TEXT`:

```
0x100ded17f is in 0x100c0b000-0x1016ae000 ---> __TEXT [10.6M] r-x/r-x SM=COW /usr/sbin/bluetoothd
```

`SIGBUS` on a code page means the page could not be faulted in — not a bad
pointer. The kernel says so directly:

```
apfs_announce_hash_mismatch:154: disk1s4 Data hash mismatch for 16384 bytes at offset 1982464
  in compressed data stream 1152921500312575937 of inode 1152921500312575936:
  expected 976c30cd50d177b1234ac93d11baf33ba756b289a35d9ec14171fade36a5fc56,
  got      253f3faadef8ef1f1d236330652ea3fdc22b08c2627388551f85f74bfe5fa27d
```

That is APFS itself reporting that the bytes it just produced do not match the
hash stored on disk.

## 2. It is exactly one file

Scanning 343 system binaries (`/usr/bin /usr/sbin /bin /sbin /usr/libexec
/System/Library/CoreServices`, size > 1 MB) with `codesign -v`:

```
checked=343 bad=157
```

Of the 157 "bad", 156 are `.car` / `.icns` / `.loctable` resources that simply
carry no signature (normal `codesign` noise). Exactly **one** real Mach-O fails:
`/usr/sbin/bluetoothd`. Per-page verification against its embedded CodeDirectory:
2885 pages, 2 bad (`[233, 483]`).

## 3. The disk is fine — the *view* is not

The same inode (`1152921500312575936`) read through two paths:

| read path | sha256 |
| --- | --- |
| boot snapshot (`/usr/sbin/bluetoothd`) | **BAD** (varies per boot: `c31f8ff4…`, `5c7fd127…`) |
| live volume (`/System/Volumes/Update/mnt1/usr/sbin/bluetoothd`) | **GOOD** `579bb5f5…` |

The good hash is the signed one: `codesign -v` passes on the live copy and fails
on the boot copy. `F_NOCACHE` reads give the same answer on both paths, so this
is not the unified buffer cache.

Critically the corruption is **not stable** — it changes between boots and even
after `purge` (`c31f8ff4…` → `5c7fd127…`), and it is always a handful of bytes
in the same two regions:

```
0x0edd1e   root=0xeb  live=0x74
0x1e7bb7   root=0x90  live=0x81     <- 8 consecutive bytes replaced by 0x90
0x45c13e   root=0x31  live=0x85
```

A disk bad block does not heal, so this is not media rot. It behaves like data
being corrupted while it is in flight through the boot-time read path.

## 4. What was tried, and what it ruled out

| Hypothesis | Test | Result |
| --- | --- | --- |
| Our kexts (`IntelBTPatcher`, `AirPortRTW`, `BlueToolFixup`) | crash-type census of all 51 reports | `EXC_BAD_ACCESS` appears on **2026-11-10** (7×) and **2026-11-14** (3×) only. On 11-10 `AirPortRTW` was still 1.2.0 — the WiFi 1.2.1 update landed 11-14 17:20, four days later. **Exonerated.** |
| RAM | 12 GB resident, 3 rounds, pattern fill + verify | 0 mismatches |
| SSD media | `diskutil info` SMART, NVMe error counters | `Verified`, all read/write error and retry counters 0 |
| Page cache | `F_NOCACHE` reads, root `purge` | unchanged |
| Stale snapshot | rewrote the file on the live volume, made a new snapshot, re-blessed, rebooted | boot copy still bad (`c31f8ff4…`) |
| Snapshot content itself | mounted each snapshot and hashed | all mountable snapshots hash GOOD |
| Launchd override to a good copy | `/Library/LaunchDaemons/com.apple.bluetoothd.plist` pointing at `/usr/local/libexec/bluetoothd-good` | **failed** — see §5 |

Note on §4 row "snapshot content": `mount_apfs -s <name> /dev/disk1s4 <dir>`
appears to succeed but can resolve to the live volume instead of the snapshot,
which makes snapshot hashing look better than reality. The only trustworthy
observation is what the booted root reports.

## 5. The launchd override does not work (do not retry)

Pointing `ProgramArguments` at a byte-perfect copy (`codesign` VALID, sha256
`579bb5f5…`) on the Data volume:

- launchd accepts the plist (`launchctl print` shows `program =
  /usr/local/libexec/bluetoothd-good`, `state = running`);
- the process starts, prints `Bluetooth Super Server Robot Destroyer. Host
  software version MobileBluetooth-196.5.0.5`, and can run standalone for
  seconds without crashing;
- **but** under launchd it crash-loops immediately (60 reports in minutes) and
  Bluetooth is dead: `[bm3_usb][GetProductAndVendorID] -- Found USB Device :`
  repeats every 1–2 s with no VID/PID, `Failed to talk to secd after 4
  attempts`, `Read SDP cache version failed`.

A platform binary (`Platform identifier=26`) evidently does not function when
executed from `/usr/local`; the entitlement/signature context differs. Reverted.

## 6. The second failure mode: NVRAM pinning

Even with a healthy bluetoothd, Bluetooth can stay dead because macOS writes

```
bluetoothExternalDongleFailed   %01
```

when the dongle cannot be brought up. That flag pins the failure state. Setting
it back to `%00` (plus a 14-byte all-zero `bluetoothInternalControllerInfo`)
and kickstarting bluetoothd restores Bluetooth **within seconds**:

```
State: On | Chipset: THIRD_PARTY_DONGLE | DC:F5:05:FF:E4:02 | v61592 c30136
```

`config.plist` already lists both variables under `NVRAM → Delete` *and*
`NVRAM → Add`, so they are reset at every boot — but macOS re-writes `%01` at
runtime, so a boot-time fix alone is not sufficient.

## 7. Mitigation in place

`btpurge-watch.sh` (v3), installed as
`/usr/local/bin/btpurge-watch.sh` + `/Library/LaunchDaemons/com.local.btpurge.watch.plist`
(`RunAtLoad`, `StartInterval=60`):

1. read controller state / firmware / address;
2. healthy → exit (no action, no disconnects);
3. unhealthy → reset the two NVRAM variables, `purge`, `kickstart -k` bluetoothd;
4. verify; if still unhealthy, repeat once with a longer settle time;
5. 300 s cooldown, log to `/var/log/btpurge-history.log`.

Observed working: two automatic recoveries in one evening, each logged as
`unhealthy … ->nvram+purge+kickstart` followed by
`pass1: attrib_on|v61592 c30136|DC:F5:05:FF:E4:02`.

`--probe` prints the current state without touching anything.

## 8. If it keeps happening

The remaining candidates are all below the configuration layer:

- reinstall macOS (recreates the sealed snapshot from scratch — the official
  remedy for `APFSUserAgent`'s "Volume Hash Mismatch" dialog);
- replace the SSD, since a fault that corrupts data in flight but never trips a
  media error counter is characteristic of controller/firmware-level problems;
- or accept the watchdog, which recovers in under a minute.

An external USB Bluetooth dongle with an Apple-native chipset (BCM20702, e.g.
ASUS USB-BT400) also sidesteps the issue entirely — it does not depend on
bluetoothd's `__TEXT` pages being intact any more than any other process does,
but it removes the Realtek DriverKit serial path that this machine depends on.

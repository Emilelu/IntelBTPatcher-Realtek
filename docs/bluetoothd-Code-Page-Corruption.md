# bluetoothd crash-loop: it was our own `-btlfxa2dpcheck` page patch all along

**Date:** 2026-11-14 (corrected 2026-11-15)
**Machine:** HP 15s-dy0xxx / i7-8565U / macOS Tahoe 26.7.3 (25G342) / Darwin 25.6.0
**Symptom:** Bluetooth suddenly dies. `system_profiler SPBluetoothDataType` reports
`State: Off`, `Chipset: BCM_4350C2`, `Address: NULL`, `Firmware: v0 c0` — the same
picture as a missing dongle — while the USB device is present and healthy.

> **Correction notice.** The first version of this document (2026-11-14)
> concluded that this was an APFS/SSD data-integrity fault in the read path of
> `/usr/sbin/bluetoothd`, and recommended reinstalling macOS or replacing the
> SSD. **That conclusion was wrong.** The "corrupted" bytes are our own
> BlueToolFixup `-btlfxa2dpcheck` patch, written into bluetoothd's `__TEXT`
> pages at run time. §3 below records the experiment that proves it, and §9
> records why the earlier reasoning went astray, so nobody repeats it.

---

## 1. The four distinct symptoms (do not conflate them)

| # | Symptom | Real cause | Status |
| --- | --- | --- | --- |
| A | `codesign -v /usr/sbin/bluetoothd` fails, file sha256 differs from Apple's | BlueToolFixup rewrites `__TEXT` pages at run time (§2, §3) | **Expected.** Not a fault. |
| B | `bluetoothd` dies with `EXC_BAD_ACCESS (SIGBUS)` on its own `__TEXT` | A patched page could not be re-derived from the APFS-compressed stream (§4) | **Fixed** by `chflags nocompressed` (§4) |
| C | Bluetooth dead: `State: Off`, `BCM_4350C2`, `v0 c0` | NVRAM pinning `bluetoothExternalDongleFailed %01` + bluetoothd crash-loop (§6) | Mitigated by watchdog (§7) |
| D | BLE keyboard won't connect, AirPods do | Keyboard does not advertise while idle; boot-time race (§6b) | Known, not a Mac bug |

A is normal and harmless. B is fixed. C is mitigated. D is a separate, older
issue.

## 2. What BlueToolFixup does to bluetoothd

`BrcmPatchRAM/BlueToolFixup.cpp` routes `_cs_validate_page` and, for
`/usr/sbin/bluetoothd` only, rewrites code pages in place before the kernel
validates them:

```cpp
KernelPatcher::RouteRequest csRoute =
    KernelPatcher::RouteRequest("_cs_validate_page", patched_cs_validate_page, orig_cs_validate);
patcher.routeMultipleLong(KernelPatcher::KernelID, &csRoute, 1);
```

Inside `patched_cs_validate_page` the page is searched for known byte patterns
(vendor check, bad-chipset check, NVRAM check, boardId, address check, and the
A2DP gate) and patched. The A2DP gate alone is:

```
original  45 85 F6 74 25   test r14d,r14d ; je +0x25
patched   45 31 F6 EB 25   xor  r14d,r14d ; jmp +0x25
```

That is a deliberate, working patch: it makes bluetoothd unconditionally take
the audio-publish path, which is what stops AirPods audio from stuttering.
Boot-arg `-btlfxa2dpcheck` enables it. **Do not remove it** — without it the
user's AirPods audio breaks up.

Because the patch mutates the page image, the file as read back is no longer the
signed file. `codesign -v` therefore reports
`invalid signature (code or signature have been modified)`, and the sha256 no
longer matches Apple's. The Apple-original hash on this machine is:

```
579bb5f53d6b26d2c9b10228df357ca783d636d8dd92c21141195de5a725f23a
```

## 3. The experiment that proves it is our patch, not the disk

The file was read, hashed, and compared while toggling only the daemon:

```
launchctl bootout system/com.apple.bluetoothd ; purge ; shasum
    -> GOOD  579bb5f5…
launchctl kickstart -k system/com.apple.bluetoothd ; shasum
    -> BAD   c31f8ff4…
```

The bytes are wrong **only while bluetoothd is running**, and they come back
wrong within seconds of restarting it. Nothing was written to disk; the volume
is read-only. So the "corruption" lives in the page cache, put there by the
in-process patcher.

Supporting evidence:

- Exactly 11 bytes differ from the live-volume copy, in three spots:
  ```
  0x0edd1e   root=0xeb  live=0x74
  0x1e7bb7   root=0x90×8 (NOP sled)  live=81 f9 6f 17 00 00 77 30
  0x45c13e   root=45 31 f6 eb 25     live=45 85 f6 74 25
  ```
  The second and third are `searchAndPatch` results: an 8-byte NOP sled and the
  `xor/jmp` A2DP gate. They are not random bit rot — they are valid x86.
- Scanning every kext in `EFI/OC/Kexts` for those patterns, **BlueToolFixup is
  the only one** that contains `81f96f17`, `4585f674`, `4531f6eb`, and
  `6f170000`. Its strings confirm the feature:
  `[a2dpcheck] bluetoothd Read Clock workaround enabled (fast-connect A2DP bypass)`,
  `[a2dpcheck] patched %s in %s`.
- Reading the same inode through the other mount
  (`/System/Volumes/Update/mnt1/usr/sbin/bluetoothd`) always returns the clean
  bytes: a different vnode means a different page-cache entry that the patcher
  never touched. This is what made it look like "one view is corrupt".

## 4. Why it still crashes (symptom B) — and the fix

`bluetoothd` occasionally died with:

```
EXC_BAD_ACCESS (SIGBUS) KERN_MEMORY_ERROR
0x100ded17f is in 0x100c0b000-0x1016ae000 ---> __TEXT [10.6M] r-x/r-x SM=COW /usr/sbin/bluetoothd
```

`SIGBUS` on a code page means the page could not be faulted back in. The kernel
reported a companion APFS error:

```
apfs_announce_hash_mismatch:154: disk1s4 Data hash mismatch for 16384 bytes at offset 1982464
  in compressed data stream 1152921500312575937 of inode 1152921500312575936
```

bluetoothd is an APFS-compressed (`decmpfs`) binary. After the patcher has
rewritten a cached page, a later fault on that page has to be re-served from the
compressed stream; the decompressed bytes no longer match the recorded hash, so
the fault fails and the process takes a `SIGBUS`. **The compression is the
enabler** — the patched bytes themselves are harmless as long as nothing has to
re-derive them from a hash-checked stream.

### The fix: decompress the file

Removing the APFS compression flag on `/usr/sbin/bluetoothd` removes the hash
check that the patch trips over:

```sh
sudo diskutil mount disk0s1                     # ESP, for config work only
sudo umount "/Volumes/Macintosh HD 1"
sudo mount -o nobrowse -t apfs /dev/disk1s4 /System/Volumes/Update/mnt1
sudo mount -uw /System/Volumes/Update/mnt1

F=/System/Volumes/Update/mnt1/usr/sbin/bluetoothd
sudo chflags nocompressed "$F"
sudo xattr -d com.apple.decmpfs "$F" 2>/dev/null    # may already be gone

sudo bless --mount /System/Volumes/Update/mnt1 --bootefi --create-snapshot
sudo reboot
```

`chflags nocompressed` makes APFS store the file uncompressed; the decmpfs
attribute disappears and so does the per-chunk hash. The file keeps its
`restricted` flag and its size (23555568 bytes), and it still carries the
patcher's bytes — but nothing re-verifies them against a stored hash any more.

### Measured result

| | before (compressed) | after (`nocompressed`) |
| --- | --- | --- |
| `ls -lO` flags | `restricted,compressed` | `restricted` |
| crashes in 58 min | 3 on 11-14 evening | **0** |
| real `apfs_announce_hash_mismatch` | 10 on 11-14, 32 on 11-10 | **0** |
| `-25291` keychain noise | present | 15 (still present, still harmless) |
| encrypted connections | worked | 2 (still works) |
| controller | `attrib_on / v61592 c30136` | `attrib_on / v61592 c30136` |

The `codesign -v` failure remains, of course — the patch still rewrites the
pages. That is symptom A, which is expected and harmless.

**Caveat:** a macOS update can reinstall or re-compress `bluetoothd`, silently
undoing this. That is what `bt-decomp-track.py` (§7) is for: it samples
`decomp=yes|NO` and the real mismatch count every 15 minutes, so a regression
shows up as a log line rather than as a dead Bluetooth stack days later.

## 5. What was ruled out on the way

| Hypothesis | Test | Result |
| --- | --- | --- |
| RAM | 12 GB resident, 3 rounds, pattern fill + verify | 0 mismatches |
| SSD media | `diskutil` SMART, NVMe counters | `Verified`; all read/write error and retry counters 0 |
| Page cache | `F_NOCACHE` reads, root `purge` | purge clears it; F_NOCACHE alone does not |
| Stale snapshot | rewrote file on live volume, new snapshot, re-bless, reboot | still "bad" — because bluetoothd patched it again |
| APFS/decmpfs on disk | mount live volume rw, hash the file there | always GOOD |
| `AirPortRTW` 1.2.1 | crash census vs install date | exonerated (crashes exist on 11-10, install was 11-14) |
| Our kexts generally | crash-type census of all 51 reports | `EXC_BAD_ACCESS` only on 11-10 (7×) and 11-14 (3×); 11-10 predates the WiFi update |

## 6. Symptom C: NVRAM pinning

Even with a healthy bluetoothd, Bluetooth can stay dead because macOS writes

```
bluetoothExternalDongleFailed   %01
```

when the dongle cannot be brought up. That flag pins the failure state. Setting
it back to `%00` (plus a 14-byte all-zero `bluetoothInternalControllerInfo`) and
kickstarting bluetoothd restores Bluetooth **within seconds**:

```
State: On | Chipset: THIRD_PARTY_DONGLE | DC:F5:05:FF:E4:02 | v61592 c30136
```

`config.plist` lists both variables under `NVRAM → Delete` **and**
`NVRAM → Add`, so they are reset at boot — but macOS re-writes `%01` at runtime,
so a boot-time fix alone is not enough. This is why the watchdog exists.

## 6b. Symptom D: the keyboard, and why `-25291` is a red herring

`bluetoothd` logs

```
Failed to query keychain for device Random D3:0C:D1:FA:CA:CA with result -25291
```

`-25291` is `errSecNotAvailable`. It is tempting to blame the patched binary for
losing its keychain entitlement, but the numbers refuse that story:

- this boot: **523** occurrences of `-25291` and **7** successful
  `Encryption is now enabled` — the same daemon, the same session;
- 2026-11-13 11:00 hour: 342 `-25291` **and** a successful encrypted keyboard
  connection;
- 2026-11-14 23:32:40.939: `Le topology … D3:0C:D1:FA:CA:CA` →
  `Outgoing connection … successful` → `Encryption is now enabled`, with
  `-btlfxa2dpcheck` active.

So `-25291` is background noise on this Realtek/Tahoe combination and does not
block pairing. What actually blocks the keyboard:

1. the BLE keyboard **does not advertise while idle** — it only advertises on a
   keypress, so if it is not advertising at the moment macOS retries, the
   attempt fails;
2. a boot-time race: macOS tries to reconnect before the controller's LE
   subsystem is up, and does not retry.

## 7. Two daemons now in place

### `btpurge-watch.sh` (v3) — recovers a dead Bluetooth stack

Installed as `/usr/local/bin/btpurge-watch.sh` +
`/Library/LaunchDaemons/com.local.btpurge.watch.plist` (`RunAtLoad`,
`StartInterval=60`):

1. read controller state / firmware / address;
2. healthy → exit (no action, no disconnects);
3. unhealthy → reset the two NVRAM variables, `purge`, `kickstart -k` bluetoothd;
4. verify; if still unhealthy, repeat once with a longer settle time;
5. 300 s cooldown, log to `/var/log/btpurge-history.log`.

**It deliberately does not hash-check bluetoothd.** An earlier version did, and
would have fired every 60 seconds forever, because a running bluetoothd always
looks "corrupt" (§3). Health is judged only by controller state.

Observed working:

```
2026-11-14 23:18:38 unhealthy state=attrib_off fw=v0 c0 addr=NULL ->nvram+purge+kickstart
2026-11-14 23:19:03 pass1: attrib_on|v61592 c30136|DC:F5:05:FF:E4:02
```

`--probe` prints the current state without touching anything.

### `bt-decomp-track.py` — guards the §4 fix from being silently undone

Installed as `/usr/local/bin/bt-decomp-track.py` +
`/Library/LaunchDaemons/com.local.btdecomp.track.plist` (`RunAtLoad`,
`StartInterval=900`). Every 15 minutes it appends one line to
`/var/log/bt-decomp-fix.log`:

```
2026-11-15 00:24:57 decomp=yes crashes=63 newest=… mismatch=0 bt=attrib_on|v61592 c30136|DC:F5:05:FF:E4:02
```

- `decomp=yes|NO` — is `/usr/sbin/bluetoothd` still free of the `compressed` flag?
- `mismatch=N` — real `apfs_announce_hash_mismatch` events since boot (our own
  `log show` invocations are filtered out).
- `crashes=N newest=…` — crash-report count and newest file.

This matters because **a macOS update can re-compress or replace the file**,
which silently reinstates symptom B. The tracker turns that into a visible log
line instead of a dead Bluetooth stack days later. `--show` prints the history.

## 8. What is genuinely left

- **Symptom D** is best solved on the keyboard side (press a key when pairing
  is attempted) or by accepting the watchdog.
- A more robust alternative to §4 would be to stop patching `__TEXT` at all —
  hook the function rather than rewriting its bytes — but that is real work with
  real risk, and it trades against AirPods audio stability. Decompressing the
  file achieves the same outcome for one `chflags` and no kext changes.
- An Apple-native BCM20702 dongle (e.g. ASUS USB-BT400) sidesteps the Realtek
  DriverKit serial path entirely, but would still be subject to BlueToolFixup
  patching if that kext is kept.

## 9. Why the first version of this document was wrong

Recorded so the mistake is not repeated:

1. **The two read paths were treated as two views of the same data.** They are
   two vnodes with two page-cache entries. Only one of them is patched. The
   difference was read as "the boot snapshot is corrupt".
2. **`purge` was thought to be ineffective** because the bad bytes came back
   after purging. They came back because bluetoothd was still running and
   re-patched the page. The decisive test — stop the daemon, *then* purge — was
   not run until later.
3. **"The corruption changes between boots" was over-interpreted.** Different
   boots ran different amounts of bluetoothd, so different pages had been
   patched; that was mistaken for drifting media damage.
4. **`mount_apfs -s <name>` silently falls back to the live volume** when the
   snapshot name does not resolve, so every "the snapshot is fine" check was
   actually hashing the live volume. Do not trust snapshot hashes obtained that
   way; the only trustworthy observation is what the booted root reports.

The general lesson: before concluding "the storage is corrupt", toggle the
process that touches the file and re-hash. If the bytes follow the process, the
process is the author.

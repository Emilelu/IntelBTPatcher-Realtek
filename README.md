# RealtekBTPatcher

A Lilu plugin that fixes **BLE HID keyboards that connect but never finish pairing**
on third-party **Realtek RTL8821CE** Bluetooth controllers under **macOS Tahoe (26.x)**.

Verified on real hardware: HP 15s-dy0xxx / Intel i7-8565U / RTL8821CE (USB `0BDA:B00A`) / macOS 26.7.2.

> A Realtek-capable fork of [OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware)'s `IntelBTPatcher`,
> extended with the Tahoe `IOUSBHostIOSource::io` hook paths and a single-event injection
> strategy that does not rely on duplicate HCI events.

---

## The problem

```
GattServer device "245E5F78-..." connected for session
encryptionStatusChangedCb handle:0x... status=4803 isPairing=0        <- normal, NOT the root cause
TS_LE_EncryptionCompleteCb completed with error STATUS 4803
Remote Features: 3D 00 00 00 00 00 00 00 ... ready: wait-for-features, PHYReady:no
Le topology - {... ready-state: LE_READY_WAIT_FOR_LENGTH, enc-state: OFF}
LE Link disconnected ... reason 722 encryptionPending 0
Will not retry
```

`bluetoothd` waits for two LE Meta events that this controller never emits:

| Event | Subevent |
|---|---|
| `LE PHY Update Complete` | `0x0C` |
| `LE Data Length Change` | `0x07` |

The link therefore never reaches `LE_READY_IDLE`, SMP pairing never starts, no passkey prompt
appears, and the keyboard never binds.

### Ruled out by measurement

- `STATUS 4803` / `isPairing=0` — also present in successful pairing logs on other controllers
- RPA / LL Privacy — the keyboard advertises a **static random** address (`0xD3…`, top bits `11`)
- Stale bond — no `com.apple.bluetoothd.plist` `SMPDistributionKeys`
- Missing `rtl8821c_config.bin` — already shipped by the firmware loader; not a feature bitmap

---

## How it works

1. Hooks **`IOUSBHostDevice::deviceRequest`** (HCI command path).
2. Hooks **all three `IOUSBHostIOSource::io` overloads** — mandatory on Tahoe, where pipe/stream
   I/O tail-jumps into `IOSource::io` instead of `IOUSBHostPipe::io`:
   ```
   __ZN17IOUSBHostIOSource2ioEP18IOMemoryDescriptorjP19IOUSBHostCompletionj
   __ZN17IOUSBHostIOSource2ioEP18IOMemoryDescriptorjRjj
   __ZN17IOUSBHostIOSource2ioEP18IOMemoryDescriptorjP26IOUSBHostBundledCompletionj
   ```
3. Hooks `IOUSBHostPipe::init` / `initWithDescriptors` to capture the interrupt-IN pipe
   (vendor filter: Realtek `0x0BDA`, Intel `0x8087`).
4. On the **first real `LE Read Remote Features Complete` (`0x04`)**, appends two synthetic
   events into the same transfer:
   ```
   LE PHY Update Complete : 3E 06 0C 00 <h_lo> <h_hi> 02 02                    (8 bytes)
   LE Data Length Change  : 3E 0B 07 <h_lo> <h_hi> 1B 00 48 01 1B 00 48 01     (13 bytes)
   ```
   Handle taken from the real event (`data[2]` = lo, `data[3]` = hi).
5. Fallback: clears the **LE Data Packet Length Extension** bit (bit 5) of
   `LE Read Local Supported Features`, so `bluetoothd` may skip the length gate entirely.

Unlike the Intel-only #514 patch, this does **not** require duplicate `0x04` events —
Realtek returns exactly one.

---

## Verified result

```
IBTPRouteErr     = dev=0 async=0 iosC=0 iosR=0 iosB=0 initCfg=0 initPipe=0   (all routes OK)
IBTPPipeCaptured = Y
IBTPIOSourceHits = 1374
IBTPReqLRF       = 1
IBTPInjected     = 1
IBTPHandle       = 0x0010
IBTPWrapEnabled  = Y

Remote Features ... ready: wait-for-features, PHYReady:no
Data Length Changed for central lmhandle 00000010: Tx [27 -> 27, 328], Rx [27 -> 27, 328],
                    ready-state: wait-for-length, phy-ready 1
ready-state: LE_READY_IDLE
Accepting pairing request from device "245E5F78-..."
smpPairingCompleted address=Random D3:0B:... status=0
```

The BLE keyboard pairs and works.

---

## Safety switch

All event rewriting is gated behind the **`-ibtpwrap`** boot argument.

| Mode | Behaviour |
|---|---|
| default (no arg) | installs hooks, publishes counters, **does not touch any buffer** — identical to not having the kext |
| `-ibtpwrap` | enables PHY / Data-Length event injection |

Other boot args: `-ibtcompatoff` (disable plugin), `-ibtcompatdbg`, `-ibtcompatbeta`.

---

## Observability

Lilu-plugin `IOLog`/`SYSLOG` output is unreliable on macOS 26, so every diagnostic is
published as an **IORegistry property** on the Bluetooth USB device:

| Property | Meaning |
|---|---|
| `IBTPRouteErr` | `routeMultiple` error code per symbol (0 = OK) |
| `IBTPPipeCaptured` / `IBTPPipeAddr` | interrupt pipe captured, kernel address |
| `IBTPIOSourceHits` | hits on the three `IOSource::io` hooks |
| `IBTPWrapEnabled` | `Y` when `-ibtpwrap` is active |
| `IBTPReqLRF` | `LE Read Remote Features` commands seen |
| `IBTPInjected` | synthetic event batches appended |
| `IBTPHandle` | connection handle used for the last injection |
| `IBTPEDLClear` | times the EDL bit was cleared |

```bash
ioreg -lw0 | grep -oE '"IBTP[A-Za-z]+" = <[^>]*>'
```

---

## Install

1. `Kernel → Add`: add `RealtekBTPatcher.kext` after Lilu (Enabled).
2. `boot-args`: add `-ibtpwrap`.
3. Reboot.

Works alongside `RealtekBluetoothFirmware.kext` (firmware upload) and `BlueToolFixup.kext`.

**Requirements:** macOS Tahoe (26.x); Lilu 1.7.x.

---

## Credits

This work builds directly on the following projects and analyses. Many thanks to their authors.

### Forked / based on
- **[OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware)** — original `IntelBTPatcher` by **zxystd**; source of the `IOUSBHostDevice::deviceRequest` / `IOUSBHostPipe` hook structure.
- **[if-lensman/Hackintosh-MacPro7-1-EFI](https://github.com/if-lensman/Hackintosh-MacPro7-1-EFI)** — Tahoe `IOUSBHostIOSource::io` routing (`newIOSourceIOCompletion` / `Rjj` / `Bundled`) and the `_iosSourceCompletionRouted` de-duplication idea.

### Root-cause analysis of the `LE_READY_WAIT_FOR_LENGTH` stall
- **[OpenIntelWireless/IntelBluetoothFirmware #514](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/issues/514)** — original LE PHY / Data Length readiness analysis.
- **[OpenIntelWireless/IntelBluetoothFirmware PR #515](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/pull/515)** — reference implementation of the three `IOUSBHostIOSource::io` paths.
- **[OpenIntelWireless/IntelBluetoothFirmware #497](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/issues/497)** — BLE keyboard pairing failures on Tahoe.
- **[soyeoning94/hackintosh-logitech-k251-bluetooth-pairing-fix](https://github.com/soyeoning94/hackintosh-logitech-k251-bluetooth-pairing-fix)** — proved `status=4803 isPairing=0` also appears in successful pairing logs.
- **[flxxxxddd/SimpleMtkBtFw](https://github.com/flxxxxddd/SimpleMtkBtFw)** (issue #2 / PR #3) — MT7922 equivalent; source of the `HCI_LE_Set_Data_Length (0x2022)` alternative.

### Realtek Bluetooth support
- **[thegwchr/RealtekBluetoothFirmware](https://github.com/thegwchr/RealtekBluetoothFirmware)** — Realtek RTL8821C firmware loader used alongside this kext.

### Kernel extension infrastructure
- **[acidanthera/Lilu](https://github.com/acidanthera/Lilu)** — plugin framework, `KernelPatcher::routeMultiple`, `onKextLoadForce`, `checkKernelArgument`.
- **[acidanthera/WhateverGreen](https://github.com/acidanthera/WhateverGreen)** — `kern_fb.hpp` / `kern_igfx.cpp`, essential for the Intel framebuffer connector work on the HDMI side.
- **[acidanthera/BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM)** — `BlueToolFixup`, which makes third-party controllers acceptable to `bluetoothd`.

### Reference data / documentation
- **[torvalds/linux](https://github.com/torvalds/linux)** — `drivers/bluetooth/btrtl.c`, `include/net/bluetooth/hci.h` (LE feature bits, vendor config), `drivers/gpu/drm/i915/display/*` (VBT parsing, HDMI timing).
- **[intel-gpu-tools](https://gitlab.freedesktop.org/drm/igt-gpu-tools)** — `intel_vbt_decode`, reference for VBT decoding.
- **[AppleIntelWifi/device-logs](https://github.com/AppleIntelWifi/device-logs)** — public `AppleIntelFramebuffer` logs documenting `[Getonline_info] fIsHDMI=` / `[EDID]` ordering.

### Tooling references
- **[kfix/ddcctl](https://github.com/kfix/ddcctl)** — `IOFramebufferI2CInterface` / `IOI2CSendRequest` usage.
- **[watchthelight-labs/WTLLegionBtFix](https://github.com/watchthelight-labs/WTLLegionBtFix)** — `_cs_validate_page`-based `bluetoothd` patching on macOS 26.

If your project should be credited and is missing, please open an issue.

---

## Disclaimer

Provided as-is, no warranty. Kernel extensions can panic or prevent boot — keep a working EFI
backup and know how to disable the kext (`-ibtcompatoff`) or boot without it.

# IntelBluetoothFirmware

![CI](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/workflows/CI/badge.svg)

- **English**
- [简体中文](/.github/README-zh_Hans.md)

> [!IMPORTANT]
> The **LE Data Length Change fix** in this fork — which clears bluetoothd's `LE_READY_WAIT_FOR_LENGTH` stall so BLE HID devices bind on macOS Tahoe ([#514](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/issues/514)) — was **written by Claude, an AI assistant**. It is provided as-is, with no warranty: you are responsible for reviewing, testing, and using it at your own risk.

## Intro

IntelBluetoothFirmware is a Kernel Extension that uploads Intel Wireless Bluetooth Firmware to provide native Bluetooth in macOS.
The firmware binary files are from the Linux Open Source Project.

After several months of public testing, it appears that the Kext is working well and stable.

[![Join the chat at https://gitter.im/OpenIntelWireless/itlwm](https://badges.gitter.im/OpenIntelWireless/IntelBluetoothFirmware.svg)](https://gitter.im/OpenIntelWireless/IntelBluetoothFirmware?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

## Documentation

**Please read the docs carefully before using the Kernel Extensions or submitting an Issue Report!**

- [Supported Devices](https://openintelwireless.github.io/IntelBluetoothFirmware/Compat.html)
- [Installation](https://openintelwireless.github.io/IntelBluetoothFirmware/Installation.html)
- [Frequently Asked Questions](https://openintelwireless.github.io/IntelBluetoothFirmware/FAQ.html)
- [Troubleshooting](https://openintelwireless.github.io/IntelBluetoothFirmware/Troubleshooting.html)

## Credits

- [torvalds/linux](https://github.com/torvalds/linux)
- [acidanthera/BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM)


---

# Realtek RTL8821CE BLE HID fix (macOS Tahoe) — verified on real hardware

This fork additionally supports **Realtek** USB Bluetooth controllers (`0x0BDA`), and fixes
**BLE HID keyboards that connect but never finish pairing** on macOS Tahoe 26.x.

## Symptom

```
GattServer device "..." connected
encryptionStatusChangedCb status=4803 isPairing=0     <- normal, NOT the root cause
Remote Features: 3D 00 ... ready: wait-for-features, PHYReady:no
Le topology - {... ready-state: LE_READY_WAIT_FOR_LENGTH, enc-state: OFF}
LE Link disconnected ... reason 722, Will not retry
```

`bluetoothd` waits for two LE Meta events this controller never sends:
`LE PHY Update Complete (0x0C)` and `LE Data Length Change (0x07)`.
The link never reaches `LE_READY_IDLE`, so SMP pairing never starts and no passkey appears.

## What this fork does

1. Hooks `IOUSBHostDevice::deviceRequest` (HCI command path).
2. Hooks **all three `IOUSBHostIOSource::io` overloads** — required on Tahoe, where
   pipe/stream I/O tail-jumps into `IOSource::io` rather than `IOUSBHostPipe::io`.
3. Captures the controller interrupt-IN pipe (vendor filter `0x0BDA` / `0x8087`).
4. On the **first real `LE Read Remote Features Complete` (0x04)**, appends two synthetic
   events into the same transfer:
   ```
   LE PHY Update Complete : 3E 06 0C 00 <h_lo> <h_hi> 02 02
   LE Data Length Change  : 3E 0B 07 <h_lo> <h_hi> 1B 00 48 01 1B 00 48 01
   ```
5. Fallback: hides the LE Data Packet Length Extension bit (bit 5 of
   `LE Read Local Supported Features`) so `bluetoothd` may skip the length gate.

Unlike the Intel-only #514 patch, this does **not** depend on the controller returning
duplicate `0x04` events — Realtek returns only one.

## Verified result (HP 15s-dy0xxx, i7-8565U, RTL8821CE, macOS 26.7.2)

```
IBTPReqLRF       = 1
IBTPIOSourceHits = 1374
IBTPInjected     = 1
IBTPHandle       = 0x0010

Remote Features ... ready: wait-for-features, PHYReady:no
Data Length Changed ... ready-state: wait-for-length, phy-ready 1
ready-state: LE_READY_IDLE
Accepting pairing request from device "245E5F78-..."
smpPairingCompleted ... status=0
```

The BLE keyboard pairs and works.

## Safety switch

All event rewriting is gated behind **`-ibtpwrap`**. Without it the plugin installs hooks and
publishes counters only (behaviour identical to not having the kext), so the hook paths can be
verified before enabling rewriting.

## Observability (IORegistry properties on the Bluetooth USB device)

`IBTPRouteErr`, `IBTPPipeCaptured`, `IBTPPipeAddr`, `IBTPIOSourceHits`, `IBTPWrapEnabled`,
`IBTPReqLRF`, `IBTPInjected`, `IBTPHandle`, `IBTPEDLClear`.

Kernel `IOLog` from Lilu plugins is unreliable on macOS 26, which is why diagnostics are
published as IORegistry properties instead of log lines.

## Install

1. `Kernel -> Add`: `IntelBTPatcher.kext` after Lilu.
2. `boot-args`: add `-ibtpwrap` to enable the fix.
3. Reboot.

Works alongside `RealtekBluetoothFirmware.kext` (firmware upload) and `BlueToolFixup.kext`.

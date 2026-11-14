# IntelBTPatcher 修改记录（Tahoe IOSource::io + 单事件注入）

### 2.6.1 - boot-time controller race is not ours

Two hypotheses for "the keyboard only reconnects after toggling Bluetooth once"
were tested on 2026-11-13.

Findings from the boot window (macOS 26.7.3, RTL8821CE `0BDA:B00A`, firmware
v61592 c30136):

```
11:53:14.189 E OI_HCICMD_ReadLocalVersionInformation failed:  STATUS 408, but we move forward
11:53:14.294 E Failed to read local Fast LE Connection data from controller with result:11
11:53:14.295 E LE_InitMultipleAdvertising failed with status  STATUS 152
11:53:14.315 E Server.LE.Scan  Failed to add rule
11:53:14.389 Df Connect called to "82F8798D-68AF-A2E5-A994-BB08F8605055"
```

After `Connect called` there is no `Outgoing connection ... successful` and no
`reason`; bluetoothd abandons the attempt and does not retry for hours. The
same four error lines appear in the 2026-11-10 logs, so the race predates every
change made here.

To rule out our own hooks, 2.6.1 added `-ibtpguard`: every rewrite
(`rewriteHciEvent` injection and the three `IOUSBHostIOSource::io` completion
wrappers) stays disarmed until system uptime reaches `IBTP_ARM_DELAY_MS`
(default 60 s). Verified with the guard active during the whole init burst
(`IBTPArmed=N` through the failure, then `IBTPUptimeMs=60078` at the transition)
and the boot-time failures were unchanged, byte for byte.

Conclusion: the failed bring-up belongs to the controller/firmware, not to these
wrappers, so the guard is opt-in only (`-ibtpguard`) and behaviour without it is
identical to 2.6.0. What stays from 2.6.1 is the ioreg write throttle inside the
hooks: `IBTPIOSourceHits` is published on every 64th pass while unarmed and on
state transitions, instead of allocating an `OSData` for every HCI event.

Practical consequence: after a cold boot the keyboard may need one manual
Bluetooth off/on in System Settings. That toggle performs a real controller
power cycle; no CLI equivalent exists on Tahoe
(`IOBluetoothPreferenceSetControllerPowerState` is a stub returning 0,
`pkill bluetoothd` / `launchctl kickstart` restart the daemon without
re-initialising the controller, and `USBDeviceReEnumerate` returns
`0xE00002CD`). Do not use `defaults write /Library/Preferences/com.apple.Bluetooth
ControllerPowerState 0` to emulate it: it powers the radio off and cannot be
undone without a reboot.

### Local (Xcode-free) build: two things the linker no longer does

Building with `scripts/build-local.sh` produced a bundle that OpenCore
injected but the kernel never loaded, with no complaint in the log. Two
independent causes, both introduced by the toolchain rather than the source:

1. **Missing `_kmod_info`.** `ld -kext` used to synthesise the writable
   `__kmod_info` struct (and the `__realmain` / `__antimain` indirections that
   `libkmod`'s `c_start.o` / `c_stop.o` jump through). The linker in macOS 26
   (`ld-1267`) dropped that, so `kmutil` rejects the bundle with
   `kexts must have a _kmod_info symbol`. `libkmod.a` only *references* the
   symbol, so nothing defines it. The build now emits the struct by hand with
   the layout the old linker used: `next=0`, `info_version=KMOD_INFO_VERSION`,
   `id=(uint32_t)-1`, `name` = bundle id, `version` = `MODULE_VERSION`,
   `reference_count=-1`, and `start`/`stop` pointing at
   `<PRODUCT_NAME>_kern_start` / `_kern_stop` from Lilu's `plugin_start.cpp`.
   Getting `info_version` wrong produces the distinct error
   `unsupported kmod_info version of 0`.

2. **Missing `CFBundleSupportedPlatforms`.** Xcode's `ProcessInfoPlistFile`
   injects `CFBundleSupportedPlatforms`, `LSMinimumSystemVersion`,
   `DTPlatformName` and friends from build settings; the repository's
   `Info.plist` template only carries `$(...)` placeholders. A kext without
   the platform declaration is skipped while the boot kext collection is
   built. The script now generates a complete plist with `plistlib`.

`scripts/build-local.sh` fails the build if either check regresses, because
OpenCore skips an unusable kext silently - there is no error message to notice
at boot time.

## 2.6.0 — 2026-11-13

### 修复：睡眠唤醒后内核 page fault（UAF）

症状：合盖睡眠、唤醒后约 0.8 秒出现 kernel panic，Panicked task 是 `kernel_task`：

```
trap type = 14 page fault, Fault CR2: 0x0000000000000268
com.zxystd.IntelBTPatcher :
  CIntelBTPatcher::newHostDeviceRequest(...) + 0x160
 <- IOUSBHostDevice::deviceRequest <- getDescriptor <- getDeviceDescriptor
 <- CIntelBTPatcher::captureIntelInterruptPipe + 0x40
 <- CIntelBTPatcher::newInitPipeConfig + 0x40
 <- AppleUSBXHCIPipe::withDescriptorsAndOwners <- IOUSBHostDevice::start
```

`+0x160` 对应 `callq *0x268(%rcx)`，`%rcx` 来自全局 `g_btDevice`，读出来是 0。
也就是 `g_btDevice` 指向的 `IOUSBHostDevice` 已经被释放：唤醒时 USB 重新枚举，
旧设备被销毁，钩子再往它身上写 ioreg 标记就踩到已释放内存。

### 修法

- `setBtDevice()`：交换前 `retain()` 新设备，交换后对旧指针 `release()`。只要我们持有引用，对象就不会被释放。
- `btDeviceUsable()`：每次调用前校验首字段（vtable 槽）非空，双重保险。
- `setPropData()` / `setDeviceData()`：`OSData::withBytes` 之后必须 `release()`。
  `setProperty()` 自己持有引用，原来每次 HCI 设备请求漏掉一个内核对象。

### 构建

`scripts/build-local.sh`：不依赖 Xcode，单独 clang++ + MacKernelSDK + Lilu 头文件就能出 kext。
2.6.0 产物 47520 字节，`VersionInfo = REL-260-...`（2.5.2 是 `REL-252-...`），
`kmutil showloaded` 里可以直接区分。

---

修改时间：2026-11-09
修改范围：仅本地文件；未 git commit / git push，未 SSH，未重启任何机器。
参考实现：https://raw.githubusercontent.com/if-lensman/Hackintosh-MacPro7-1-EFI/main/patches/IntelBTPatcher/IntelBTPatcher.cpp

## 1. 修改文件

- `IntelBTPatcher/IntelBTPatcher.cpp`
- `IntelBTPatcher/IntelBTPatcher.hpp`

## 2. 新增的 IOUSBHostIOSource::io hook 与路由

### 2.1 `processKext()` 中新增的路由（仅 `KernelVersion::Tahoe` 及以上）

| 符号 | replacement | 行号（cpp） |
| --- | --- | --- |
| `__ZN17IOUSBHostIOSource2ioEP18IOMemoryDescriptorjP19IOUSBHostCompletionj` | `newIOSourceIOCompletion` | 175–188 |
| `__ZN17IOUSBHostIOSource2ioEP18IOMemoryDescriptorjRjj` | `newIOSourceIORjj` | 190–202 |
| `__ZN17IOUSBHostIOSource2ioEP18IOMemoryDescriptorjP26IOUSBHostBundledCompletionj` | `newIOSourceIOBundled` | 204–216 |

- `_iosSourceCompletionRouted` 在 Completion 重载路由成功后置 `true`（cpp 184），用于让 `newAsyncIO` 不再重复包装同一个 completion（cpp 521）。
- 三个路由的错误码分别保存在 `g_routeIOSourceIOCompletionErr` / `g_routeIOSourceIORjjErr` / `g_routeIOSourceIOBundledErr`（cpp 18–20），并写入 `IBTPRouteErr`（cpp 621–626）。

### 2.2 新增函数

| 函数 | 作用 | 行号（cpp） |
| --- | --- | --- |
| `CIntelBTPatcher::newIOSourceIOCompletion` | `IOUSBHostIOSource::io(IOMemoryDescriptor*, uint32_t, IOUSBHostCompletion*, uint32_t)` hook；复制原 completion（保留 `parameter`），包装为 `asyncIOCompletion` | 541–563 |
| `CIntelBTPatcher::newIOSourceIORjj` | 同步重载 `io(..., uint32_t &bytesTransferred, ...)` hook；原调用返回成功后调用 `rewriteHciEvent()` | 565–576 |
| `CIntelBTPatcher::newIOSourceIOBundled` | `IOUSBHostBundledCompletion` 重载 hook；包装为 `asyncBundledCompletion` | 578–600 |
| `CIntelBTPatcher::isHookedIOSource` | 仅在 `g_btDevice` 已捕获且 `that == _hookPipeInstance` 时返回 true（Realtek 0x0BDA / Intel 0x8087 过滤沿用 `captureIntelInterruptPipe`） | 536–539 |
| `asyncBundledCompletion` | 遍历 bundled 完成数组逐个改写并写回 `actualByteCountArray` | 487–499 |

hpp 中的对应声明与成员：

- `#include <IOKit/usb/IOUSBHostIOSource.h>`：hpp 14（该头文件同时定义 `IOUSBHostCompletion`、`IOUSBHostBundledCompletion` 与 `IOUSBHostBundledCompletionAction`）
- `AsyncOwnerData` 新增 `IOUSBHostBundledCompletionAction bundledAction`：hpp 24
- 三个新函数声明：hpp 81–83
- 三个 `oldIOSource*` 地址：hpp 91–93
- `_iosSourceCompletionRouted` / `isHookedIOSource()`：hpp 99–101

## 3. 单事件注入（不再依赖重复 0x2016）

### 3.1 命令侧：只 arm，不再重发命令

`newHostDeviceRequest()` 收到 `HCI_OP_LE_READ_REMOTE_FEATURES (0x2016)` 时：

- 不再调用两次 `FunctionCast(...oldHostDeviceRequest)` 重发 0x2016；
- 只设置 `remoteReadSCount = 1`、`g_leMetaStage = 0`（cpp 371–376）。

`HCI_OP_RESET` 时同时清零 `g_leMetaStage` / `remoteReadSCount`（cpp 384–388）。

### 3.2 完成侧：在第一条真实 0x04 事件后追加 13 字节

实现位置：`rewriteHciEvent()`，cpp **415–476**；其中单事件追加逻辑在 **447–470**。

流程：

1. `rewriteHciEvent()` 先 `IOMalloc(origLen + 13)`，避免原来的堆溢出风险（原实现只分配 `origLen` 却在 `buffer + origLen` 处写 13 字节）。
2. 保留原 EDL bit 清理路径：`0x0E` Command Complete 且 opcode `0x2003`（LE Read Local Supported Features）时清除 `hdr->data[4]` 的 bit5（cpp 438–445，属性 `IBTPEDLClear`）。
3. 当 `hdr->evt == 0x3E`、`hdr->data[0] == 0x04`、且 `g_leMetaStage == 0` 时：
   - 从真实事件取 handle：`fakeEvent[3] = hdr->data[2]`（lo）、`fakeEvent[4] = hdr->data[3]`（hi）；
   - 检查 `dataBuffer->getLength() >= origLen + 13`，不够则**不追加**；
   - `memcpy` 到 `buffer + origLen`，`writeBytes(0, buffer, origLen + 13)`，`bytesTransferred = origLen + 13`；
   - `g_injected++`，写 `IBTPInjected`；
   - `IBTPHandle` 写入 `0x%04X` 形式的最近 handle；
   - `g_leMetaStage = 1`，`remoteReadSCount = 0`，保证每条真实 0x04 只注入一次。
4. 追加的 13 字节模板：`3E 0B 07 <handle_lo> <handle_hi> 1B 00 48 01 1B 00 48 01`（数组定义 cpp 408）。

### 3.3 属性

均通过 `g_btDevice->setProperty(...)` + `OSData::withBytes(...)` 写入（辅助函数 cpp 284–306）：

- `IBTPIOSourceHits`：三个新 hook 的命中总次数（只统计已捕获的 BT 中断 pipe，即 `isHookedIOSource(that)` 为 true 的调用；每次命中刷新）
- `IBTPInjected`：成功追加伪造事件的次数
- `IBTPEDLClear`：清 EDL bit 的次数
- `IBTPHandle`：最近一次注入使用的 handle（hex 字符串）

## 4. 需要人工确认的点

1. **头文件/类型**：已核对 MacKernelSDK master 的 `<IOKit/usb/IOUSBHostIOSource.h>`，其中同时定义 `IOUSBHostCompletion`、`IOUSBHostBundledCompletion` 和 `IOUSBHostBundledCompletionAction`；请再以实际构建用的 KDK 版本复核（若该版本没有，需要补前置声明或对应头文件）。
2. **`IOUSBHostCompletion` 字段**：MacKernelSDK 头中该结构为 `{ owner, action, parameter }`。`newIOSourceIOCompletion`/`newIOSourceIOBundled` 使用整体结构体拷贝，`parameter` 会被保留；`newAsyncIO` 仍是原地修改 `owner/action`，也会保留 `parameter`。请用实际 Tahoe KDK 复核该结构布局。
3. **`isHookedIOSource()` 的指针比较**：已核对 MacKernelSDK 的 `IOUSBHostPipe.h`：`class IOUSBHostPipe : public IOUSBHostIOSource`（单继承），因此 `IOUSBHostPipe*` 与 `IOUSBHostIOSource*` 地址应一致。若实际 Tahoe 布局不同，`that == _hookPipeInstance` 可能匹配不到；可改为按 `_device` 偏移判断或暂时去掉过滤（参考实现曾用固定偏移 `0x18/0x60`）。
4. **`KernelVersion::Tahoe`**：确认所用 Lilu 头中的枚举值与 macOS 26 对应（工程里原本已把 `KernelVersion::Tahoe` 作为最高支持版本，应无问题）。
5. **buffer 容量**：单事件追加依赖中断 pipe 的 `IOMemoryDescriptor::getLength()` 至少比实际事件长度多 13 字节。若某些机型分配得刚好，`IBTPInjected` 会保持 0，需要检查实际 buffer 大小。
6. **行为变化**：原有“重复 0x2016 → 两个重复 0x04 → 改写 PHY / Data Length”的 3 阶段逻辑已移除（不再使用的 `fakePhyUpdateCompleteEvent` 数组也已删除）；现在只保留真实 0x04 + 追加 Data Length Change。请确认不再需要伪造 PHY Update Complete。

## 5. 语法检查

- 本机没有 `clang` / `clang++` / `g++` / MSVC（`cl.exe`）可执行文件，也没有 macOS SDK，因此无法做真正的编译/类型检查。
- 已用 tree-sitter C++ 解析器对 `IntelBTPatcher.cpp` 和 `IntelBTPatcher.hpp` 做语法解析：两个文件均无 ERROR / missing 节点（仅语法层面，不能替代 Xcode + KDK 编译验证）。

## 6. 未执行的操作

- 未 `git commit`
- 未 `git push`
- 未 SSH
- 未重启任何机器

### 2026-11-14 - bluetoothd code-page corruption is not a kext bug

Investigated a Bluetooth outage where the controller reported
`State: Off / BCM_4350C2 / Address NULL / v0 c0` while the USB dongle was
present. Root cause is a data-integrity fault on `/usr/sbin/bluetoothd`'s
`__TEXT` pages in the sealed boot snapshot's read path, not this kext:

- crash is `EXC_BAD_ACCESS (SIGBUS)` / `KERN_MEMORY_ERROR`, address inside
  bluetoothd `__TEXT`; APFS logs `apfs_announce_hash_mismatch` for the same inode;
- same inode reads GOOD from the live volume, BAD from the boot snapshot;
  the bad bytes move between boots and after `purge`;
- 343 system binaries scanned, bluetoothd is the only real Mach-O that fails
  `codesign -v`;
- `EXC_BAD_ACCESS` occurrences: 2026-11-10 (7x) and 2026-11-14 (3x) only. On
  11-10 AirPortRTW was still 1.2.0, so the WiFi update is exonerated;
- 12 GB x 3 rounds RAM test: 0 mismatches; NVMe error/retry counters all 0;
- rewriting the file on the live volume + new snapshot + re-bless + reboot did
  not fix the boot copy;
- overriding launchd to run a good copy from `/usr/local` fails: the process
  crash-loops and cannot talk to `secd`.

Second, independent failure mode: macOS writes `bluetoothExternalDongleFailed
%01` at runtime, which pins Bluetooth off even with a healthy bluetoothd.
`config.plist` resets it at boot but macOS re-writes it.

Mitigation: `tools/bt-recovery/btpurge-watch.sh` (v3) - resets the two NVRAM
variables, purges, kickstarts bluetoothd, verifies, retries once, 300 s
cooldown. Two automatic recoveries observed in one evening.

See `docs/bluetoothd-Code-Page-Corruption.md`.

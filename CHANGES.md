# IntelBTPatcher 修改记录（Tahoe IOSource::io + 单事件注入）

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

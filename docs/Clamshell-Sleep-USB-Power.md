# 合盖后 USB 间歇性断电（Clamshell Sleep 循环）—— 2026-11-13

## 现象

用户报告：Mac 合盖后 USB 间歇性断电（蓝牙适配器、USB 设备反复掉线）。

## 诊断（macOS 26.7.3 / HP 15s-dy0xxx）

```
AppleClamshellState = Yes      # 合盖
displays=0                     # 没有任何活动显示器（外接屏接在另一台电脑上）
pmset: sleep 0 / displaysleep 0 / powernap 0 / standby 1 / tcpkeepalive 1 / womp 1
```

`pmset -g log` 显示从 17:04 合盖开始：

```
17:04:24 Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active
17:04:30 DarkWake from Normal Sleep [CDN] : due to XDCI CNVW/
17:05:15 Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active
17:05:21 DarkWake ...
...（每 45 秒一个循环）
```

统计：**24 小时 30 次睡眠 / 34 次 DarkWake**；12 小时内 **78 次 `USB Device Reset`**。

每次唤醒，内核日志出现大量：

```
[IOUserUSBHostHIDDevice.cpp:1532] Reset:0xe00002d8      # kIOReturnNotAttached
[IOUserUSBHostHIDDevice.cpp:781] Retries exhausted, reason:0xe00002d8, wantsReset:1
[IOUserUSBHostHIDDevice.cpp:1521] USB Device Reset
IOUSBHostDevice@14a00000: getDescriptorGated: ... 0xe00002cd
Bluetooth Radio@14a00000: RealtekBluetoothFirmware selected configuration 1
```

即：**合盖 + 无外接显示器 → macOS 进入 Clamshell Sleep；`tcpkeepalive` 让它每 45 秒做一次 Maintenance Sleep/DarkWake；每次唤醒 XHCI 控制器都给 USB 设备复位，蓝牙适配器重新枚举。** 这就是「USB 间歇性断电」，也很可能是蓝牙键盘「时好时坏」的重要放大器。

> 注：`IOUSBHostDevice@14a00000` 是蓝牙适配器（RTL8821CE），每次唤醒都重新 `selected configuration 1` 下载固件。

## 处理

`SleepDisabled` 是**全局**设置（`pmset -c disablesleep 1` 也会写成 System-wide），不支持按电源区分。因此用一个 LaunchDaemon 每 30 秒同步一次：

- `/usr/local/bin/sleep-policy.sh`：读 `pmset -g batt`，AC 电源 → `pmset -a disablesleep 1`；电池 → `pmset -a disablesleep 0`（恢复默认省电）
- `/Library/LaunchDaemons/com.local.sleeppolicy.plist`：`RunAtLoad` + `StartInterval 30`
- 只在状态变化时写 `/var/log/sleep-policy.log`

验证（17:16 安装后）：`pmset -g` → `SleepDisabled 1`；17:15:08 之后再无 `Entering Sleep state` / `DarkWake`；最近 5 分钟 `USB Device Reset` 计数 = **0**。

## 副作用

- AC 下合盖也不睡：机器持续运行、发热，注意散热。
- 电池供电时自动恢复休眠（`disablesleep 0`）。

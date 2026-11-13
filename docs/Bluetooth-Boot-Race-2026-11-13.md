# 蓝牙键盘开机/唤醒后不自动连接 —— 排查记录（2026-11-13）

环境：HP 15s-dy0xxx 黑苹果 / macOS Tahoe 26.7.3 / Darwin 25.6.0 / Realtek RTL8821CE `0BDA:B00A`（固件 v61592 c30136）/ IntelBTPatcher 2.6.1。

## 1. 现象

开机后蓝牙 `State: On`、`THIRD_PARTY_DONGLE`、固件版本正常，但已配对的 BLE 键盘（`D3:0C:D1:FA:CA:CA`）停在 Not Connected。手动把蓝牙开关关一次再打开，键盘随后就能连上并使用。

## 2. 被推翻的三个假设

### 2.1 「我们的 `IOUSBHostIOSource::io` 钩子拖慢开机 HCI 初始化」

2.6.1 加了 `IBTP_ARM_DELAY_MS = 60000` 时间闸（boot-arg `-ibtpguard` 开启，默认关闭），实测开机窗口内 `IBTPArmed=N`、`IBTPUptimeMs=60078`，改写确实完全没生效——**但四条初始化错误与之后连不上的现象一模一样**。

同一批错误在 2026-11-10 18:34 的旧日志里也存在。→ 与补丁无关。

### 2.2 「bluetoothd 抢在 DriverKit 串口 dext 就绪之前初始化控制器」

毫秒级日志显示链路是：

```
bluetoothd 打开 HCI → IOBluetoothFamily CreateSerialDevice 等 IOUserBluetoothSerialDriver
→ 等 ~10.5–10.9 s 放弃 → publish nub → dext 被拉起（真正启动只要 ~20 ms）
```

三次实测间隔：10.51 s / 10.66 s / 10.87 s。期间 bluetoothd 在进入 `CreateSerialDevice` 后 0.08 s 就发出第一条 HCI 命令。

据此做了两个实验：

| 实验 | 做法 | 结果 |
| --- | --- | --- |
| 延迟 bluetoothd | `launchctl bootout system/com.apple.bluetoothd` → 等 80 s → `bootstrap` + `kickstart` | 四条错误一模一样，dext 仍在 open 后 10.7 s 才 launch |
| dext 已存活时重启 bluetoothd | dext pid 在跑，`kickstart -k system/com.apple.bluetoothd` | 12:05:02 依旧四条错误，间隔 10.66 s |
| 按住伪串口保活 | 另一进程 `open('/dev/cu.Bluetooth-Incoming-Port', O_RDWR)` 持 900 s | 仍 `Stopping bluetooth nub` + 10.87 s |

→ DriverKit 的 10 s 等待是**架构固有**的，且不解释「开关一次就好」。

### 2.3 「四条初始化错误 = 失败原因」

对比 11:13 那次**连接成功**的日志，同一窗口里四条错误一条不少：

```
Unknown chipset 0 / OI_HCICMD_ReadLocalVersionInformation failed: STATUS 408
Failed to read local Fast LE Connection data from controller with result:11
LE_InitMultipleAdvertising failed with status  STATUS 152
```

紧接着就是 `Device found: CBDevice 82F8798D … DvT Keyboard` → `Encryption is now enabled`。→ **这四条是这颗 Realtek 芯片的常态噪声**。

## 3. 现在的解释（证据支持）

近 30 分钟 `bluetoothd` 的 `Device found: 82F8798D` 共 6 次——**每一次都精确对应一次蓝牙上电瞬间，两次上电之间一次都没有**。BLE 键盘空闲时不广播，只有按键才广播。

所以「开关一次蓝牙就好」的真实可能原因是：上电瞬间那次扫描窗口刚好碰上按键产生的广播。**在没有任何按键的情况下，Mac 侧无论怎么重试都找不到它。**（这一点还需要用户按一次键来最终确认；已问 m05168。）

## 4. 唯一可脚本化的「真·开关蓝牙」通道

macOS 26 上所有命令行电源接口全部失效（实测）：

- `IOBluetoothPreferenceSetControllerPowerState`：Tahoe 空壳，getter 恒 0
- `BluetoothManager.framework`（私有）`setPowered:`：零日志
- `IOServiceOpen(IOBluetoothHCIController, type 0..5)`：全 `0xE00002C7`
- `USBDeviceReEnumerate`：`0xE00002CD`
- `IOBluetoothDevice openConnection`：`0xE00002BC`
- `launchctl kickstart` bluetoothuserd / bluetoothUIServer：无效
- `DisableEnhancedConnections=1`：生效但无用，已撤销
- `defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 0`：**能关掉，但同会话内任何方式都打不开，只能重启** —— 永远不要碰这个键

可用通道：**系统设置 → 蓝牙面板里的那个 `AXCheckBox`**。AXPress 它会让 bluetoothd 打出真正的

```
SetPowerState: PoweredOff → Power state changed: PoweredOff (PowerState:0 managerState:4)
SetPowerState: PoweredOn  → Power state changed: PoweredOn  (PowerState:1 managerState:5)
```

与手动点开关等价。工具 `btswitch.m`（递归 14 层找 AXCheckBox，`find` / `press` 两个命令）。

注意：`bluetoothd` 收到的是 `SetPowerState`，而重启 `bluetoothd` 会 `DetachUserClients → Stopping bluetooth nub → terminating pseudo nub`，下次 open 又要重踩 10 s，所以 `pkill bluetoothd` 永远无效。

## 5. 开机自动化：launchd → localhost SSH → AX

**关键技巧**：launchd 直接起的进程没有辅助功能（Accessibility）权限，但 `sshd-keygen-wrapper` 有；TCC 的 responsible-process 会传递给 sshd 会话的所有子进程。所以在 LaunchDaemon 里 `ssh emilelu@127.0.0.1` 再跑 UI 自动化即可拿到 AX 权限。

一次性准备：

```sh
sudo mkdir -p /var/root/.ssh
sudo ssh-keygen -q -t ed25519 -N '' -f /var/root/.ssh/id_localhost
sudo cat /var/root/.ssh/id_localhost.pub >> ~/.ssh/authorized_keys   # 以登录用户身份
```

组成：

- `/usr/local/bin/btkick-boot.sh`：`sleep 75` → `ssh -i /var/root/.ssh/id_localhost … 'MAXKICKS=1 ~/btkick-if-needed.zsh'`
- `/Library/LaunchDaemons/com.local.btkick.boot.plist`：`RunAtLoad`
- `~/btkick-if-needed.zsh`：用 `system_profiler SPBluetoothDataType -json` 判断键盘是否已连；未连才踢，每次 boot 最多 `MAXKICKS` 次（计数文件 `/tmp/btkick-count.$BOOT`）
- `~/btkick.zsh`：打开蓝牙设置面板 → 等开关出现 → 连按两次（关→2 s→开）→ 退出系统设置 → 打印 bluetoothd 电源转换

实测（2026-11-13 13:03）：`AXPress err=0 / after=0` → `after=1`，bluetoothd `13:03:11.761 SetPowerState: PoweredOff` / `13:03:16.982 SetPowerState: PoweredOn`，链路完整。

Windows 侧一键工具：`D:\Files\System\Windows\Utilities\VNC\修复蓝牙.bat`（调 `btkick_mac.py`，paramiko SSH）。

## 6. 仍未验证

- 开关一次之后，键盘是**自己**连上，还是要按一下键才连？（决定这条自动化到底有没有意义）
- 睡眠唤醒后是否同样需要踢一次（当前 LaunchDaemon 只覆盖开机）。

## 7. 结论建议

如果确认「必须按键才广播」，那么任何 Mac 侧自动化都无法解决，因为问题在键盘的省电策略上；此时可选：

- **A（推荐，根治）** 换 Apple 原生支持的 BCM20702 芯片 USB 蓝牙（华硕 USB-BT400 等，¥50–100），走原生 USB 传输，不经过 DriverKit 串口，也不依赖这颗 Realtek 芯片的私有固件路径。
- **B** 维持现状，保留开机自动踢一次 + Windows 侧手动按钮。

# macOS 上的「水冷连接效果」——复刻 open-revo 的水冷模块

机械革命（MECHREVO）40/50 系本子的「冰河/水冷魔盒」在 Windows 上由 open-revo / ControlCenter  
接管。本目录是把它搬到 macOS 的最小实现：用 CoreBluetooth 直接跟水冷魔盒说话，  
不依赖任何 Windows 组件。

## 0. 已验证可用 ✅

本机（黑苹果，第三方 USB 蓝牙 dongle）实测通过，完整日志：

```
使用 NUS：写 6e400002-… / 通知 6e400003-…
握手：写 "sw" (73 77)，等待固件版本串…
<- 握手应答：固件版本 "MCU F/W Version: 2.0.0.4" (版本段 = "2.0.0.4")
连接已建立，固件版本 '2.0.0.4'
-> FE 1A 01 00 00 00 00 EF    system enable (0x1A)
-> FE 1C 01 64 03 00 00 EF    restore pump 100% @ 8V
-> FE 1B 01 32 00 00 00 EF    restore fan 50%
-> FE 1E 01 00 FF 00 00 EF    restore head led (0,255,0) mode=0(常亮)
<- 水表状态 2 = 流量正常（设备主动推送）
```

`2.0.0.4` 正是文档里 **LCT22002（Mk2）** 的固件版本 → **风扇灯效 `0x33` 可用**，
可以加 `--fan-led 0,0,255,2`。

一句话上手：

```bash
pip3 install bleak
python3 wcooler.py run --volt 8 --duty 100 --fan 50
```

> **本机建议先用 Python 版。** 实测 Python/bleak 第 1 次就连上了，而 Swift/CoreBluetooth
> 会卡在 `connecting`（同一台机器、同一个 dongle）。两条路径的建链行为不同，
> Swift 版的连接兜底逻辑保留着，换机器/换 dongle 时可以再试。

## 1. 菜单栏 App（UI 版）✅ 推荐

一个常驻菜单栏的原生 App，开机自启、自动连水冷、可自定义、带智能控制。

![状态](https://img.shields.io/badge/菜单栏-常驻-green)

### 构建与运行

```bash
sh gui/build.sh          # -> dist/WCooler.app
open dist/WCooler.app
```

首次运行会弹「WCooler 想要使用蓝牙」，**必须允许**；之后它就是一个水滴图标
（`LSUIElement`，不占 Dock）。点图标弹出控制面板。

### 功能

| 能力     | 说明                                                                    |
| ------ | --------------------------------------------------------------------- |
| 自动连接   | 启动即扫描连接，握手校验固件版本串；掉线自动重连，10 次失败后每 20 秒重试                |
| 状态显示   | 图标颜色反映状态，菜单里显示 固件版本 / 水表 / rssi / 当前泵扇档位，可展开实时日志             |
| 智能控制   | 按 **CPU 负载**（或外部温度命令）经折线曲线算出泵/扇占空比，带滞回避免抖动                     |
| 预设     | 静音 / 均衡 / 性能，一键切换；也可逐点自定义曲线                                       |
| 自定义    | 水泵电压 7/8/11/12、手动档位、泵下限、采样间隔、滞回阈值                                |
| 灯效     | 冷头灯 + 风扇灯（Mk2），各自独立开关、取色器、模式（常亮/呼吸/炫彩/呼吸变色）                     |
| 注水/排气  | 一键跑官方 68 秒排气序列                                                       |
| 高级/诊断  | 0x30 探测、复位输出（0x1F）、详细日志开关、日志导出（收在设置里，不占主面板）      |
| 机型识别   | 按固件版本串首位判 Mk1(1.x)/Mk2(2.x)，**Mk1 自动隐藏不支持的风扇灯**             |
| 高温保护   | 温度或负载超过阈值强制泵 100% + 扇 100%，回落 5 度后交回曲线（带回差，不抖）       |
| 告警       | 流量异常/掉线时：菜单栏图标变 ⚠️ + 面板顶部红色横幅 + 系统通知（三重，互不依赖）   |
| 告警通知   | 流量异常、掉线、恢复可分别开关                                                   |
| 右键菜单   | 不展开面板直接切预设 / 注水 / 遥测 / 复位 / 重连 / 退出                          |
| 日志导出   | 一键写到 `~/Library/Logs/wcooler-<时间戳>.log` 并在 Finder 中选中                |
| 开机自启   | 勾选即写入 `~/Library/LaunchAgents/com.wcooler.gui.plist`（`KeepAlive`） |
| 睡眠保护   | 系统睡眠前自动停泵并断线，唤醒后自动重连并恢复档位                                        |

### 智能控制怎么配

**默认按 CPU 温度控制**，温度直接从 SMC 原生读取（`gui/SMCReader.swift`），
**零依赖、不需要 root**。

实测可用（i9-14900HX + VirtualSMC/SMCProcessor）：

| 键     | 含义       | 实测值    |
| ----- | -------- | ------ |
| `TC0P` | CPU 包/邻近 | 53~56℃ |
| `TC0D/E/F` | 核心温度     | 54℃    |
| `TC1c/2c/3c` | 各核温度     | 46~47℃ |

### `0x1A` 是什么

`FE 1A 01 00 00 00 00 EF` 是**固件内部的一个布尔标志位**（system enable）：
把 byte[2] 归一化成 0/1 写入 RAM `0x20002b01`，同时把 `0x200033c8` 清 0，没有其它副作用。

**Windows 主机从来不发这一帧** —— 既然官方不发设备也能正常工作，说明默认值就是使能状态，
所以这帧**对功能没有影响**。本工具默认**关闭**以严格对齐官方行为，设置里可打开。

### 默认曲线（按实测温度标定）

映射区间 **45℃ → 95℃**；CPU 温度取所有可用传感器里的**最高值**（控制要看最热的那个）。

| CPU 温度 | 泵     | 扇     |
| ------ | ----- | ----- |
| 50℃（待机） | 54%   | 29%   |
| 60℃    | 63%   | 39%   |
| 70℃    | 75%   | 55%   |
| 80℃    | 87%   | 75%   |
| 90℃    | 96%   | 92%   |
| 95℃    | 100%  | 100%  |

三档预设（静音 / 均衡 / 性能）各 5 个控制点，可直接逐点微调（改了会自动切成「自定义」）。
曲线图上有一条橙色竖线标出**当前温度所在位置**，一眼看到跑在哪一段。
高温保护阈值默认 **90℃**（曲线到 95℃ 才满档，90℃ 强制满档作为兜底）。

> SMC 结构体布局是实测扫出来的，不是抄来的：
> `size=80，key@0，dataSize@28，cmd@42，data[32]@48`，命令 `9=READ_KEYINFO / 5=READ_BYTES`，
> 类型 `sp78` 的值 = `Int16(raw)/256`。其它尺寸/偏移一律 `kIOReturnBadArgument`。
> 想自己验一遍：`sh gui/check.sh` 会打印实时 CPU 温度。

**CPU 与 GPU 的负载：** CPU 占用率可读（`host_cpu_load_info`，界面实时显示）。
**GPU 占用率读不到** —— nullmoth 驱动没有暴露利用率，上游 PR #323 的作者也明确说明
需要另写一个 root 守护进程去轮询寄存器（`0x20802096`），目前没人实现。所以界面上
GPU 只显示温度，不显示利用率，不会拿假数据充数。

**GPU 温度也能读到 —— 但不在 SMC 里。** 这条路是查
[nullmoth/nvidia-macos-driver#323](https://github.com/nullmoth/nvidia-macos-driver/pull/323)
才发现的：开源 NVIDIA 驱动把 GPU 核心温度放在 **`NVAccel` 的 IORegistry 属性**
`PerformanceStatistics["Temperature(C)"]` 里，正是 iStat 读 GPU 面板用的那个键。
（驱动内部 250ms 读一次 TSENS，BAR0 偏移 `0x20460`，并做 1~125℃ 校验。）

> 注意：SMC 里的 `TG0P/TG0D/…` 在黑苹果上**根本没有**，所以只在 SMC 里扫键会误判成
> 「GPU 读不到」。本机实测 nullmoth 驱动 2.5.1：`Temperature(C)` = 47~48℃（待机）。
>
> 那个 PR 本身已关闭，但已安装的 2.5.1 驱动已经带这个功能（可能是另一笔提交合入的）。

温度可取自 **CPU / GPU / 两者较高值**（默认取较高值）：
水冷主要压 CPU，但 GPU 发热同样会把整机温度拉起来，取高值最稳。
界面会分别显示 CPU 与 GPU 的当前温度。

**内存温度确实读不到。** 实测扫了一遍 `TM0P/TM1P/TM0S/TM1S/TM0D/Tm0P/…` 全部无键。
原因有二：没装 `SMCSuperIO`（它才提供 CPU 之外的传感器），而且笔记本 DDR5 在黑苹果上
本来就没有 SMC 温度映射 —— 真机上有的内存传感器是靠 SMC 固件提供的，黑苹果没有。

高级设置里有「扫描」按钮，可列出当前 SMC 里所有能读到的温度键，自己核对。

取值优先级：**原生 SMC → 用户配置的外部命令 → 回退 CPU 负载**。
界面会直接显示当前实际用的是哪个源（如「SMC TC0P」）。
若你的机器 SMC 读不到，可以在设置里关掉「优先用原生 SMC」并填一条温度命令
（如 `osx-cpu-temp -c`，可 `brew install osx-cpu-temp`），有「探测温度命令」按钮自动找。
- 曲线是「输入百分数 → 占空比」的折线，默认 4 个点，可逐点微调；
  水泵另有**硬下限**（默认 50%），避免低负载时泵停转。
- 滞回阈值默认 3%：算出的占空比变化不到 3% 就不下发，防止泵的档位反复抖动。

### 源码结构

```
gui/Protocol.swift      协议常量与组帧（与 CLI 同源，逐字节一致）
gui/CoolerEngine.swift  BLE 引擎：建链/握手/保活/重连/优雅停止
gui/Settings.swift      配置持久化、曲线插值、CPU 采样、温度探针、LaunchAgent
gui/Views.swift         SwiftUI 控制面板 + AppModel 状态机
gui/main.swift          NSStatusBar + NSPopover 宿主
gui/build.sh            swiftc 直接编译成 .app（无需 Xcode/SwiftPM）
```

### 协议一致性回归检查

改完 `Protocol.swift` 跑一遍，会把组帧结果和回包解析跟逆向文档逐条比对（不连设备）：

```bash
sh gui/check.sh
```

覆盖 16 条命令帧 + 电压码 4 档 + 版本串 `Substring(17)` + 水表 `0x31/0x32` 解析 + 短包忽略，
全绿才说明和逆向结论一致。

### 发布前已修复的缺陷（v1.0.0）

| # | 问题                                                                        | 后果                                       |
| - | ------------------------------------------------------------------------- | ---------------------------------------- |
| 1 | 注水序列与 5 秒保活定时器冲突                                                          | 68 秒排气时序被反复打断，效果打折                       |
| 2 | 特征发现只处理 NUS 服务分支，其它服务直接 return                                            | 非 NUS 固件批次会**永久卡在「连接中」**                 |
| 3 | 建链后没有看门狗                                                                  | 服务发现/握手卡住时无任何兜底                          |
| 4 | `TempProbe` 在主线程同步 `readDataToEndOfFile()`                                | 用户填的温度命令一旦挂起，**整个菜单栏卡死**               |
| 5 | 日志用字符串本身当 `ForEach` 的 id                                                  | 重复日志行会让 SwiftUI 渲染错乱                     |
| 6 | `engine` / `smart` / `settings` 是嵌套 ObservableObject，AppModel 没转发变更        | **界面永远停在初始值**，状态、CPU 读数、目标档位都不刷新         |
| 7 | 蓝牙未就绪时每 1 秒重试并打印                                                          | 日志刷屏 + 定时器堆积                             |
| 8 | `retry()` 没清空 `peripheral`                                                | 服务发现失败后 `didDiscover` 被守卫挡住，**再也连不上**    |
| 9 | 写队列在断线期间无上限堆积                                                             | 长时间连不上时内存无意义增长                           |
| 10 | 只按设备名匹配                                                                   | 改名过的设备扫不到 —— 现在也认广播里的 NUS 服务 UUID       |
| 11 | 曲线数值放在 `Stepper` 的 label 里，同时加了 `.labelsHidden()`                     | **数字被一起隐藏，曲线看起来是空的** —— 数值改放独立 Text，并加了曲线缩略图 |
| 12 | 风扇灯只在 `on` 时发帧                                                            | 关灯后设备维持上次状态，**灯永远关不掉** → 每次都发（含 off）  |
| 13 | 拖滑块时每次配置变更都重建采样定时器                                                      | 无谓开销 → 间隔没变就不重建                          |
| 14 | `beginConnectCycle()` 缺「已经在连」的守卫                                            | 启动时的延迟重试会二次 attach → **重复握手、重复下发状态**   |
| 15 | 弹窗高度只按内容自适应                                                                  | 展开设置/日志后**顶出屏幕** → 按屏幕可用高度封顶 + 内容可滚动 |
| 16 | 逐帧 `-> FE ...` 与保活推送无条件打印                                                  | 日志被调试信息淹没 → 分级，默认只留状态变化与异常        |

### 日志分级

默认只记录状态变化与异常（连接/断开/握手/水表/告警/高温保护），**逐帧字节和保活推送不打印**。
排查问题时在「设置 → 高级 / 诊断」里打开「详细日志」，会额外打印每一帧的 hex 与保活记录。

### 已知限制

- 设备选择靠名字关键词 + NUS 广播 UUID，没有手动选设备的下拉框（一次只连一台）。
- 开机自启写的是二进制绝对路径，把 `.app` 挪位置后需要重新勾一次。
- 温度驱动依赖外部命令（如 `osx-cpu-temp`），需要自己装；取不到值会自动回退 CPU 负载。
- 未做代码签名（仅 ad-hoc），分发给别人时需在「系统设置 → 隐私与安全性」点「仍要打开」。
- 系统通知走的是 `NSUserNotificationCenter`（已废弃 API）：本机只有 Command Line Tools，
  其 SDK 里 `UserNotifications` 没有 Swift 模块（需完整 Xcode）。若将来系统不再投递，
  菜单栏 ⚠️ 与面板横幅仍会告警 —— 不单点依赖。
- **实测结论：`0x30` 在 LCT22002 v2.0.0.4 上不含遥测数据**。请求后回的是 24 字节
  `MCU F/W Version: 2.0.0.4`——就是把版本串重发一遍。这与文档里「0x30 与 `sw`
  处理器走同一条代码路径」的说法吻合（它从 flash 拷的那个「25 字节模板」其实就是版本串）。
  所以**这台设备上没有可取的内部温度/流量**，智能控制要温度只能靠外部命令。
  入口保留，供其它固件批次探测。

### 兜底：App 连不上时的无 UI 方案

若在这台黑苹果上 App 卡在连接（第三方蓝牙 dongle 上 CoreBluetooth 的已知毛病），
用 Python 版跑守护进程，同样支持智能控制：

```bash
python3 wcooler.py run --smart --smart-preset balanced --volt 8 \
        --session-attempts 20 --refresh 3
```

开机自启（`~/Library/LaunchAgents/com.wcooler.py.plist`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.wcooler.py</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string>
    <string>/Users/whitegold/Desktop/macos-watercooler/wcooler.py</string>
    <string>run</string><string>--smart</string><string>--volt</string><string>8</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
```

然后 `launchctl load ~/Library/LaunchAgents/com.wcooler.py.plist`。

## 2. open-revo 到底是怎么做的（逆向结论）

对 `open-revo.exe`（Tauri + Rust）静态分析和它自己的运行日志  
（`%APPDATA%\OpenRevo\open-revo.log`）可以确认，水冷相关的能力分成两层：

| 层                     | 通道                                                                                                                                  | macOS 可行性                  |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| 水冷魔盒本体（水泵档位/风扇/灯效/流量） | **BLE 外设**，Nordic UART Service 透传                                                                                                   | ✅ 用户态 CoreBluetooth 即可     |
| 机身功耗墙 / 风扇曲线 / 性能模式   | Windows **WMI 邮箱**：`root\wmi` 的 `OemWMIMethod!OemWMIfun`（回退 `AcpiTest_WMI`，in 64B / out 256B），例如 `set_cpu_spl = [0,251,0,23,2,<W>]` | ❌ macOS 没有 WMI，需 SSDT/kext |

机身功耗墙 / 风扇曲线 / 性能模式的 macOS 可行方案（含本机实测参数）见  
[`POWER-AND-FANS.md`](POWER-AND-FANS.md)。

也就是说：**「连接水冷」这个效果 90% 是蓝牙**，跟 open-revo 一样用 BLE 控制魔盒即可；  
剩下那 285W 之类的功耗墙加成，基本是 EC/固件自己检测到水管接上后放开的  
（建议在 Windows 上关掉 open-revo 插拔水管，用 HWiNFO 看 PL1/PL2 是否变化来验证；  
如果确实要软件触发，那就只能走 ACPI 热补丁 + Lilu 插件直接写 EC，风险和工作量都大得多）。

## 3. BLE 协议（权威版）

本实现依据 **Uniwill `GCUService.exe` 的逆向文档**（.NET IL，402,742 行，
`ikdasm` 反编译；另含 nRF52832 固件 `ble_app_uart_pca10040_s132.bin` 的 ARM Thumb
反汇编交叉验证）。这比 open-revo 日志的二次推断可靠得多 —— 下面的表就是官方文档。

设备名：`CoolingSystem LCT21001`（Mk1）/ `CoolingSystem LCT22002`（Mk2）。
XMG OASIS、TUXEDO Aquaris 等贴牌机是同一套。

GATT 是标准 **Nordic UART Service**（已由固件反汇编确认，勿再怀疑）：

```
service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
write    6E400002-B5A3-F393-E0A9-E50E24DCCA9E   # 主机 -> 魔盒 (TX)
notify   6E400003-B5A3-F393-E0A9-E50E24DCCA9E   # 魔盒 -> 主机 (RX)
```

所有命令都是 **8 字节**：`[0]=0xFE [1]=CMD [2]=on/off [3..6]=参数 [7]=0xEF`

| CMD  | 名称   | byte[2]    | byte[3]      | byte[4] | byte[5] | byte[6] | 例                                     |
| ---- | ---- | ---------- | ------------ | ------- | ------- | ------- | ------------------------------------- |
| 0x19 | 系统模式 | 见下表       |              |         |         |         | `FE 19 00 01 00 00 00 EF` 睡眠           |
| 0x1A | 系统使能 | `1`/`0`    | 0            | 0       | 0       | 0       | `FE 1A 01 00 00 00 00 EF`             |
| 0x1B | 风扇   | `1`/`0`    | **duty 0-100** | 0       | 0       | 0       | `FE 1B 01 32 00 00 00 EF` = 开、50%     |
| 0x1C | 水泵   | `1`/`0`    | **duty 0-100** | **电压码** | 0       | 0       | `FE 1C 01 64 03 00 00 EF` = 开、100%、8V |
| 0x1E | 冷头灯效 | `1`/`0`    | R            | G       | B       | 模式      | `FE 1E 01 00 FF 00 00 EF` = 绿、常亮      |
| 0x32 | 查询水表 | 0          | 0            | 0       | 0       | 0       | `FE 32 00 00 00 00 00 EF`             |
| 0x33 | 风扇灯效 | `1`/`0`    | R            | G       | B       | 模式      | `FE 33 01 00 00 FF 00 EF` = 蓝、常亮      |
| 0x38 | 断线   | 0          | 0            | 0       | 0       | 0       | `FE 38 00 00 00 00 00 EF`             |

**水泵电压码**（`0x1C` 的 byte[4]，`GCUService.PumpControl` 的 IL 直接给出）：

| 电压  | 码         |
| ---- | ---------- |
| 11V  | `0`（本机上限） |
| 12V  | `1`（固件支持，本机不用） |
| 7V   | `2`        |
| 8V   | `3`（默认）   |

> **本机（LCT22002）水泵最高 11V**，工具里已移除 12V 档；
> 引擎与 CLI 都会把越界值夹回允许档位（`clampVolt`），防止旧配置残留 12V。

**灯效模式**（byte[6]）：`0` 常亮 · `1` 呼吸 · `2` 炫彩 · `3` 呼吸变色

**系统模式 0x19**：

| byte[2] | byte[3] | 含义                        |
| ------- | ------- | ------------------------- |
| `00`    | `01`    | 睡眠                        |
| `01`    | `04`    | 开始注水/排气（byte[4]=`0x50`） |
| `00`    | `04`    | 停止注水                      |

### 握手（**强制步骤**）

向 TX 写 2 字节 `73 77`（ASCII `sw`，**不带** FE/EF 包裹），设备必须在 RX 上回一段
**≥18 字符**的 UTF-8 固件版本串：

```
CoolingSystem FW V1.00.00
                ^-- 主机取 Substring(17) 作为版本号
```

**收不到这串，连接就不算建立**（`GCUService` 的 `MergeFWversion` 才会把状态置为
`BLE_STATE.Connected`），后续控制帧大概率无效。本工具会在 4 秒后明确告警。

### 回包解析（设备 -> 主机）

```
if bytes[0] == 0xFE:
    if bytes[1] in (0x31, 0x32):   # 0x31=设备主动推送，0x32=查询应答
        meter_state = bytes[3]     # 2 = 流量正常，其它 = 异常/告警
else:
    fw_version = UTF8(bytes)       # 握手应答
```

主机**不轮询**水表，靠设备自己推 `0x31`。

### 时序

连接 → 发现 NUS → 订阅 RX → 写 `sw` → 收到版本串 → **立刻一次性恢复上次状态**
（泵 + 扇 + 冷头灯 + 风扇灯一股脑推下去）→ 之后按需写。
断开时发 `FE 38 ...`（Line-off）；睡眠发 `FE 19 00 01 ...`。

### ⚠️ 两处早期逆向写错、现已修正

1. **占空比是 0-100 的百分数，不是 raw 0-255。** 之前按 `pct × 2.55` 发出
   raw（45% → 115），固件解析异常。
2. **水泵帧是 duty 在前、电压码在后**（byte[3]=duty, byte[4]=volt_code）。
   之前写成「电压在前、占空比在后」，且把裸电压（7）当电压码发出去。

跑 `wcooler frames` 可离线打印全部帧逐字节核对。

## 4. 快速验证（Python，最省事）

```bash
pip3 install bleak
python3 wcooler.py scan                          # 先看设备名/地址
python3 wcooler.py frames                        # 离线打印将发的帧，核对编码
python3 wcooler.py run --volt 8 --duty 100 --fan 50
python3 wcooler.py run --volt 12 --duty 100 --fan 100 --led 0,0,255,2      # 满载 + 炫彩
python3 wcooler.py run --volt 8 --duty 100 --fan 50 --fan-led 0,0,255,2    # Mk2 才有风扇灯
python3 wcooler.py run --volt 8 --duty 100 --fan 50 --session-attempts 20  # 总掉线就加大重试
python3 wcooler.py probe                         # 扫占空比，找起转点
python3 wcooler.py prime                         # 注水/排气（约 68 秒）
python3 wcooler.py raw --hex "FE 1C 01 64 03 00 00 EF"
python3 wcooler.py off                           # 停泵停扇 + 0x38 断线
```

`Ctrl+C` 会先停泵再断开。若扫不到，先确认魔盒没被 Windows 那边（open-revo/ControlCenter）占着。

## 5. 原生版（Swift + CoreBluetooth）

```bash
swift build -c release
.build/release/wcooler scan
.build/release/wcooler frames --volt 8 --duty 100 --fan 50   # 离线核对帧
.build/release/wcooler run --volt 8 --duty 100 --fan 50
.build/release/wcooler prime          # 注水/排气
.build/release/wcooler probe          # 扫占空比，找起转点
.build/release/wcooler raw --hex "FE 1C 01 64 03 00 00 EF"
.build/release/wcooler sleep          # FE 19 00 01 ..
```

功能与 Python 版一致，另外带了：睡眠前停泵、唤醒后自动重扫重连、`SIGINT/SIGTERM` 优雅停泵。  
不想本机装 Xcode 的话，本仓库带 GitHub Actions（`.github/workflows/build.yml`），  
推上去由 macos runner 编出 `arm64 + x86_64` 通用二进制，产物在 Actions 的 artifact 里。

已构建好的产物：`dist/wcooler-macos-universal.zip`（也可以在  
<https://github.com/takoyakiwhite/wcooler-macos/actions> 的 artifact 里下）。  
下载后：`unzip wcooler-macos-universal.zip && chmod +x wcooler && ./wcooler scan`。

常驻：把 `wcooler run ...` 包一层 `launchd` agent（`KeepAlive=true`）即可开机自启、崩溃自拉。

## 6. 黑苹果前置条件

- 蓝牙必须是**可用的 BLE**：
  - Intel AX2xx/AX210 → `IntelBluetoothFirmware` + `BlueToolFixup`（+ `itlwm`/`AirportItlwm` 走 Wi-Fi）；
  - BCM94360 一类拆机卡 → 原生免驱，最省事。
- 命令行工具首次运行会弹「终端 想要使用蓝牙」，必须允许（系统设置 → 隐私与安全性 → 蓝牙）。
- 用 `launchd` 常驻时，给对应的 `.app`/二进制签个 ad-hoc 签名（`codesign -s -`）更稳。

## 7. 排错：卡在「发现目标」不动（connect 没回调）

日志停在

```
发现目标: CoolingSystem LCT22002 (638A…) rssi=-72
```

说明**已经扫到设备，但 `CBCentralManager.connect()` 一直没回调 `didConnect`/`didFailToConnect`**。
CoreBluetooth 的连接本身没有超时，所以旧版会永远挂在这里。

现在的处理（v2 新增）：

1. **不再依赖 `didConnect` 回调**：每 0.5 秒轮询一次 `peripheral.state`，
   只要变成 `connected` 就直接进入服务发现。这条最关键 —— 如果你看到**指示灯已经常亮**，
   说明链路其实通了，只是 CoreBluetooth 没把连接事件回调出来，轮询能直接绕过它；
2. 扫描回调里**隔一拍再 connect**，并且**先不停 `stopScan`**（连上之后再停）。
   `stopScan` 和 `connect` 紧挨着时，部分固件/黑苹果蓝牙栈会吞掉连接回调；
3. 挂 **12 秒超时看门狗**（`--connect-timeout` 可调）。超时会先用
   `retrievePeripherals(withIdentifiers:)` 再捞一次（捞到 `connected` 就复用），
   否则取消连接、重新扫描，**最多重试 3 次**，每次打印「连接中（第 N 次）… state=…」；
4. 启动前先查 `retrieveConnectedPeripherals`：**如果系统层面已经连着**（上次异常退出留下的残留，
   或别的进程握着），直接复用，**不再重复 connect** —— 重复 connect 是最常见的挂死原因；
5. 3 次都失败时打印完整的排查清单。

**跑之前先确认没有残留进程**，旧实例会一直握着这条连接，导致新实例怎么都连不上：

```bash
pgrep -x wcooler && pkill -x wcooler     # 注意用 -x，别用 -f（会匹配到你的 grep 命令本身）
```

手工排查顺序（如果重试仍失败）——**按命中率排序**：

1. **给魔盒断电重启**（拔掉供电/USB，等 10 秒再插回）。
   ⚠️ 这是卡在 `connecting` 最常见的原因：**指示灯常亮意味着魔盒自己认为「还连着某台主机」**，
   于是它拒绝新的连接请求，macOS 就只能一直挂在 `connecting`。
   重启魔盒会立刻清掉它那侧的连接状态，往往一次就通。
2. **本机这侧清残留连接态**：
   ```bash
   wcooler reset          # 取消所有残留的 connected/connecting 链路
   ```
   仍不行就关掉蓝牙 → 等 10 秒 → 重新打开。
3. 确认没有别的主机握着它（手机 App / Windows 的 open-revo、控制中心必须完全退出，不是最小化）；
4. 用 `wcooler scan` 再确认它还在广播、rssi 正常；
5. 用 `--address <UUID>` 精确指定，避免连到同名设备；
6. 黑苹果：`IntelBluetoothFirmware` + `BlueToolFixup` 是否都加载了；
   拿手机/手表试一次 BLE 连接，排除蓝牙栈本身的问题。

> 每次 `run` 启动时也会自动做一次残留连接清理（只在首次连接前执行一次），
> 日志里会打印 `清理残留连接态：…`。

注：`reset` 目前只有 Swift 版提供。

## 8. 排错：连上了但报「没有 NUS 服务」

> **已实测确认：本机这台 LCT22002 确实暴露 NUS**，日志里能看到
> `使用 NUS：写 6e400002-… / 通知 6e400003-…`。
> 所以正常情况下**不应该**看到这条。真出现了，通常是连接态不完整
> （残留连接 / 半建立链路）导致 GATT 没枚举全 —— 先给魔盒断电重启、
> 关蓝牙重开、清残留进程再试。

如果日志确实出现：

```
  >> 没有 NUS 服务（6E400001-B5A3-F393-E0A9-E50E24DCCA9E）
```

工具仍会自动回退：枚举**全部**服务与特征 → 挑一个「可写 + 可通知」的组合 → 照常用它发帧，
并在日志里打印选了哪个。想只看结构就跑：

现在工具会自动：枚举**全部**服务与特征 → 挑一个「可写 + 可通知」的组合 → 照常用它发帧，
并在日志里打印选了哪个。想只看结构就跑：

```bash
./wcooler info            # 列出全部服务/特征及属性，并把可读特征的值都读出来
```

信息还是不够就上 `sweep`——**不知道写通道是哪个，就把每个可写特征都试一遍**：

```bash
./wcooler sweep --dwell 8   # 逐个可写特征试发「握手 + 满档泵 + 满档扇」，每个停 8 秒
```

盯着水泵/风扇，看在哪一个特征上开始转；记下那个 UUID，之后用 `--write <UUID>` 固定它。

把 `info` 的输出贴出来，就能确定真实的写通道。如果自动挑的不对，可以手工指定：

```bash
./wcooler run --service <服务UUID> --write <写特征UUID> --notify <通知特征UUID>
```

拿到正确通道后，再考虑帧格式（`FE <cmd> ... EF`）是否也要跟着改 ——
可以对照 Windows 上 Control Center 实际发出的帧，用 `wcooler raw --hex "..."` 回放。

## 9. 排错：刚连上就断开（`!! 连接断开`）

日志形如：

```
使用 NUS：写 6e400002-... / 通知 6e400003-...
握手：写 "sw" (73 77)，等待固件版本串…
!! 连接断开
```

**好消息：能走到这一行，说明 NUS 服务和特征都对上了**，协议前提完全成立
（本机实测已确认 LCT22002 确实暴露 `6e400002` / `6e400003`）。

剩下的是「建链后立刻掉线」，CoreBluetooth 上很常见。处理方式：

1. **握手顺序必须是：先订阅 RX 通知，再写 `sw`。** 官方文档的连接步骤是
   `找到 TX → 在 RX 上启用通知 → 写 "sw" → 收版本串`。顺序反了设备可能直接断链。
   本工具已按此顺序实现。
2. **整体重试**：建链（连 + 订阅 + 握手）现在会整体重试，`--session-attempts`
   默认 8 次。总掉线就调到 20：
   ```bash
   python3 wcooler.py run --volt 8 --duty 100 --fan 50 --session-attempts 20
   ```
3. **清僵尸链路**：给魔盒断电重启（拔供电等 10 秒再插），或 `wcooler reset`（Swift 版）。
4. 运行过程中掉线会自动重建连接并重推状态帧，不需要手动重启。

## 10. 排错：连得上，但水泵/风扇没反应

按下面顺序排查，前三条能覆盖绝大多数情况。

**1）握手没完成（最常见，也最容易被忽略）**

官方逻辑是：**收不到 `sw` 的固件版本串，连接就不算建立**。日志里必须有：

```
  <- 握手应答：固件版本 "CoolingSystem FW V1.00.00" (版本段 = "V1.00.00")
```

如果 4 秒后出现 `!! 4 秒内没收到固件版本串`，那就是写通道或订阅不对 ——
先跑 `wcooler info` 看 GATT 结构，用 `--write` / `--notify` 手工指定，
再考虑是不是设备被别的主机握着、或需要点配对弹窗。

**2）占空比 / 电压码编码**

早期版本有两处编码错误（占空比按 raw 0-255 发、水泵帧里电压与 duty 位置颠倒），
现版本已按官方文档修正。想核对就跑：

```bash
wcooler frames --volt 8 --duty 100 --fan 50
#   水泵     0x1C   FE 1C 01 64 03 00 00 EF
#   风扇     0x1B   FE 1B 01 32 00 00 00 EF
```

`64`=100%、`32`=50%，`03`=8V 电压码 —— 与上表逐字节一致才对。

**3）起转阈值**

`duty` 太低泵/扇不动是物理特性。跑 `wcooler probe`，它会从 0% 扫到 100%、
每级停 6 秒，你直接看/听哪一级开始转，然后把那一级填回 `--fan` / `--duty`。
另外水泵电压档位也有影响：`--volt 12` 比 `--volt 7` 更容易起转。

**4）状态帧被固件看门狗停掉**

默认每 `--refresh` 秒（默认 5）重推一次泵 + 扇 + 灯状态帧。
若你确认官方主机不需要保活，可用 `--refresh 0` 关掉。

**5）写请求卡住导致后续帧全部没发出去**

旧实现用带响应写且没有超时，只要有一次 `didWriteValueFor` 不回调，
整个写队列就永久卡死 —— 日志里只会看到 `-> 73 77`（握手），后面什么都没有。
现在带 2 秒超时 + 重试，连续超时 2 次自动降级为无响应写。

**6）`0x1A` 系统使能**

`FE 1A 01 00 00 00 00 EF` 是固件命令但 Windows 主机从不发，本工具**默认发一次**
以确保输出级打开。想严格对齐官方行为就加 `--no-sysenable`。

## 11. 安全提醒

- **本机（LCT22002）水泵最高 11V**，工具只提供 7V / 8V / 11V 三档，默认 8V。
  固件虽支持 12V（码 `1`），但超出本机规格，已禁用；引擎与 CLI 都会把越界值夹回。
- **缺水时别让泵干转**：换水或首次加水后，用 `wcooler prime` 跑一遍官方的
  注水/排气序列（泵 100% @ 8V 转 5.5s、停 2.5s，共 8 个循环），把管路里的空气排干净。
- 退出前会先停泵停扇再发 `FE 38` 断线帧，别让泵在无水流状态下长时间空转。
- 水表状态（`0x31`/`0x32` 回包的 byte[3]）不等于 2 就是流量异常 ——
  官方逻辑此时会把 `IsMeterNormal` 置 false 并限制 GPU 超频，本工具会在日志里告警。
- 本协议来自 `GCUService.exe` 逆向 + nRF52832 固件反汇编交叉验证，
  Mk1（LCT21001）与 Mk2（LCT22002）的 CMD 集不同：`0x33` 风扇灯效**仅 Mk2 支持**，
  Mk1 上发它无效（也不会造成损害）。

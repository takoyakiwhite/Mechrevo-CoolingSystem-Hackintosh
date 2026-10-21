# macOS 上的「水冷连接效果」——复刻 open-revo 的水冷模块

机械革命（MECHREVO）40/50 系本子的「冰河/水冷魔盒」在 Windows 上由 open-revo / ControlCenter
接管。本目录是把它搬到 macOS 的最小实现：用 CoreBluetooth 直接跟水冷魔盒说话，
不依赖任何 Windows 组件。

## 1. open-revo 到底是怎么做的（逆向结论）

对 `open-revo.exe`（Tauri + Rust）静态分析和它自己的运行日志
（`%APPDATA%\OpenRevo\open-revo.log`）可以确认，水冷相关的能力分成两层：

| 层 | 通道 | macOS 可行性 |
| --- | --- | --- |
| 水冷魔盒本体（水泵档位/风扇/灯效/流量） | **BLE 外设**，Nordic UART Service 透传 | ✅ 用户态 CoreBluetooth 即可 |
| 机身功耗墙 / 风扇曲线 / 性能模式 | Windows **WMI 邮箱**：`root\wmi` 的 `OemWMIMethod!OemWMIfun`（回退 `AcpiTest_WMI`，in 64B / out 256B），例如 `set_cpu_spl = [0,251,0,23,2,<W>]` | ❌ macOS 没有 WMI，需 SSDT/kext |

机身功耗墙 / 风扇曲线 / 性能模式的 macOS 可行方案（含本机实测参数）见
[`POWER-AND-FANS.md`](POWER-AND-FANS.md)。

也就是说：**「连接水冷」这个效果 90% 是蓝牙**，跟 open-revo 一样用 BLE 控制魔盒即可；
剩下那 285W 之类的功耗墙加成，基本是 EC/固件自己检测到水管接上后放开的
（建议在 Windows 上关掉 open-revo 插拔水管，用 HWiNFO 看 PL1/PL2 是否变化来验证；
如果确实要软件触发，那就只能走 ACPI 热补丁 + Lilu 插件直接写 EC，风险和工作量都大得多）。

## 2. 抓到的 BLE 协议

水冷魔盒是个 BLE 外设，服务/特征是标准 Nordic UART：

```
service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
write    6E400002-B5A3-F393-E0A9-E50E24DCCA9E   # 主机 -> 魔盒
notify   6E400003-B5A3-F393-E0A9-E50E24DCCA9E   # 魔盒 -> 主机
```

帧格式 `FE <cmd> b1 b2 b3 b4 b5 EF`（8 字节，`FE` 头 `EF` 尾）：

| cmd  | 含义 | payload | 实测例 |
| ---- | ---- | ------- | ------ |
| —    | 握手 | 2 字节 `73 77`（ASCII `sw`，**不带** FE/EF） | `73 77` |
| 0x1C | 水泵 | `使能, 电压V, 占空比%, 0, 0` | `FE 1C 01 07 2D 00 00 EF` = 开、7V、45% |
| 0x1B | 风扇 | `使能, 占空比%, 0, 0, 0` | `FE 1B 01 3A 00 00 00 EF` = 开、58% |
| 0x1E | 灯效 | `开关, R, G, B, 模式` | `FE 1E 01 00 80 00 02 EF` = 绿、模式2 |
| 0x33 | 灯效 | 与 0x1E 相同（open-revo 两个 cmd 都发一遍） | `FE 33 01 00 80 00 02 EF` |
| 0x32 | 查询/保活 | 全 0，约每 3 秒一次 | `FE 32 00 00 00 00 00 EF` |

停止（退出/睡眠/合盖时 open-revo 的收尾）＝ 把 0x1C、0x1B、0x1E、0x33 都发一遍全 0 的帧，
顺序：先停泵 → 停风扇 → 关灯。

时序：连接后 `sw` 握手 → 推初始状态（泵、风扇、灯、查询）→ 之后有变化就写，
并每 ~3s 发一次 `0x32`；写入用带响应写（write with response），超时 ~1.5s。

## 3. 快速验证（Python，最省事）

```bash
pip3 install bleak
python3 wcooler.py scan                      # 先看设备名/地址
python3 wcooler.py run --pump 7 --duty 45 --fan 55 --led 0,128,0,2
python3 wcooler.py off                       # 只发停止帧
```

`Ctrl+C` 会先停泵再断开。若扫不到，先确认魔盒没被 Windows 那边（open-revo/ControlCenter）占着。

## 4. 原生版（Swift + CoreBluetooth）

```bash
swift build -c release
.build/release/wcooler scan
.build/release/wcooler run --pump 7 --duty 45 --fan 55
```

功能与 Python 版一致，另外带了：睡眠前停泵、唤醒后自动重扫重连、`SIGINT/SIGTERM` 优雅停泵。
不想本机装 Xcode 的话，本仓库带 GitHub Actions（`.github/workflows/build.yml`），
推上去由 macos runner 编出 `arm64 + x86_64` 通用二进制，产物在 Actions 的 artifact 里。

已构建好的产物：`dist/wcooler-macos-universal.zip`（也可以在
<https://github.com/takoyakiwhite/wcooler-macos/actions> 的 artifact 里下）。
下载后：`unzip wcooler-macos-universal.zip && chmod +x wcooler && ./wcooler scan`。

常驻：把 `wcooler run ...` 包一层 `launchd` agent（`KeepAlive=true`）即可开机自启、崩溃自拉。

## 5. 黑苹果前置条件

- 蓝牙必须是**可用的 BLE**：
  - Intel AX2xx/AX210 → `IntelBluetoothFirmware` + `BlueToolFixup`（+ `itlwm`/`AirportItlwm` 走 Wi-Fi）；
  - BCM94360 一类拆机卡 → 原生免驱，最省事。
- 命令行工具首次运行会弹「终端 想要使用蓝牙」，必须允许（系统设置 → 隐私与安全性 → 蓝牙）。
- 用 `launchd` 常驻时，给对应的 `.app`/二进制签个 ad-hoc 签名（`codesign -s -`）更稳。

## 6. 安全提醒

- 水泵电压/占空比不要超过官方软件的值（标准档 7V/45%，更高档位官方最高 12V）；
  魔盒固件自带 `safety_tripped` 保护，但别拿它当挡箭牌。
- 退出前一定发停止帧，别让泵在无水流保护的情况下长时间干转。
- 本协议来自日志逆向，不同批次固件可能不一致：改之前先跑 `scan` + 观察 `<-` 通知，
  或开 `open-revo` 的日志（设置里打开 log）再抓一次 `BLE_TX` 对照。

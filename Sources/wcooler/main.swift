// wcooler —— macOS 上的机械革命 / XMG OASIS / TUXEDO Aquaris 水冷魔盒控制器
//
// 协议依据：Uniwill GCUService.exe（.NET IL，402k 行）逆向文档
//   设备名：CoolingSystem LCT21001 (Mk1) / CoolingSystem LCT22002 (Mk2)
//   NUS 服务   6E400001-B5A3-F393-E0A9-E50E24DCCA9E
//   TX（主机写）6E400002-B5A3-F393-E0A9-E50E24DCCA9E
//   RX（通知）  6E400003-B5A3-F393-E0A9-E50E24DCCA9E
//
// 帧格式（固定 8 字节）：
//   [0]=0xFE [1]=CMD [2]=on/off [3..6]=参数 [7]=0xEF
//
// CMD 速查：
//   0x19 系统模式   [2][3]：00 01=睡眠  01 04=开始注水([4]=0x50)  00 04=停止注水
//   0x1A 系统使能   [2]=1/0           （固件命令，Windows 主机不发；这里默认发一次）
//   0x1B 风扇       [2]=on [3]=duty(0-100)
//   0x1C 水泵       [2]=on [3]=duty(0-100) [4]=电压码
//   0x1E 冷头灯效   [2]=on [3]=R [4]=G [5]=B [6]=模式
//   0x32 查询水表   （全 0；设备也会主动推 0x31）
//   0x33 风扇灯效   [2]=on [3]=R [4]=G [5]=B [6]=模式（仅 LCT22002）
//   0x38 断线       （断开连接时发，不是睡眠）
//
// 电压码（0x1C 的 byte[4]）：11V=0  12V=1  7V=2  8V=3
//
// 【两处曾经写错、现已修正的关键点】
//   1) 占空比是 **0-100 的百分数**，不是 raw 0-255。之前按 2.55 倍发成 raw，
//      45% 被发成 115，固件解析异常。
//   2) 水泵帧里 **duty 在前、电压码在后**（byte[3]=duty, byte[4]=volt_code）。
//      之前写成「电压在前、占空比在后」，电压码位置也被当成裸电压发送。
//
// 握手：向 TX 写 2 字节 73 77（ASCII "sw"，不带 FE/EF），设备必须在 RX 上
//       回一段 ≥18 字符的 UTF-8 固件版本串（如 "CoolingSystem FW V1.00.00"）。
//       **收到这串才算连接建立**；没收到说明写通道不对或链路不通。

import Foundation
import CoreBluetooth
import AppKit
import Dispatch
import Darwin

// MARK: - 协议常量

let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let nusWrite   = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
let nusNotify  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

/// 握手帧：ASCII "sw"，不带 0xFE/0xEF
let handshake = Data([0x73, 0x77])

enum Cmd: UInt8 {
    case systemMode   = 0x19
    case systemEnable = 0x1A
    case fan          = 0x1B
    case pump         = 0x1C
    case headLED      = 0x1E
    case queryMeter   = 0x32
    case fanLED       = 0x33
    case lineOff      = 0x38
}

/// 灯效模式（0x1E / 0x33 的 byte[6]）
enum LEDMode: Int, CaseIterable {
    case `static` = 0
    case breathe = 1
    case colorful = 2
    case breatheColor = 3

    var label: String {
        switch self {
        case .static: return "常亮"
        case .breathe: return "呼吸"
        case .colorful: return "炫彩"
        case .breatheColor: return "呼吸变色"
        }
    }
}

/// 水泵电压 -> 固件电压码（byte[4]）
/// IL 证据：11 -> 0，12 -> 1，7 -> 2，default -> 3（即 8V）
func voltCode(_ v: Int) -> UInt8 {
    switch v {
    case 11: return 0
    case 12: return 1
    case 7:  return 2
    default: return 3     // 8V
    }
}

func voltLabel(_ code: UInt8) -> String {
    switch code {
    case 0: return "11V"
    case 1: return "12V"
    case 2: return "7V"
    default: return "8V"
    }
}

// MARK: - 组帧

/// [0xFE, cmd, b2..b6, 0xEF]，参数不足补 0，超出截断
func frame(_ cmd: Cmd, _ payload: [UInt8]) -> Data {
    var body = Array(payload.prefix(5))
    while body.count < 5 { body.append(0) }
    return Data([0xFE, cmd.rawValue] + body + [0xEF])
}

/// 水泵：`FE 1C <on> <duty 0-100> <volt_code> 00 00 EF`
func pumpFrame(on: Bool, duty: Int, volt: Int) -> Data {
    let d = on ? max(0, min(100, duty)) : 0
    return frame(.pump, [on ? 1 : 0, UInt8(d), on ? voltCode(volt) : 0, 0, 0])
}

/// 风扇：`FE 1B <on> <duty 0-100> 00 00 00 EF`
func fanFrame(on: Bool, duty: Int) -> Data {
    let d = on ? max(0, min(100, duty)) : 0
    return frame(.fan, [on ? 1 : 0, UInt8(d), 0, 0, 0])
}

/// 冷头灯效：`FE 1E <on> R G B <mode> EF`
func headLEDFrame(on: Bool, r: Int, g: Int, b: Int, mode: Int) -> Data {
    frame(.headLED, [on ? 1 : 0,
                     UInt8(clamping: on ? r : 0),
                     UInt8(clamping: on ? g : 0),
                     UInt8(clamping: on ? b : 0),
                     UInt8(clamping: on ? mode : 0)])
}

/// 风扇灯效：`FE 33 <on> R G B <mode> EF`（仅 LCT22002 支持）
func fanLEDFrame(on: Bool, r: Int, g: Int, b: Int, mode: Int) -> Data {
    frame(.fanLED, [on ? 1 : 0,
                    UInt8(clamping: on ? r : 0),
                    UInt8(clamping: on ? g : 0),
                    UInt8(clamping: on ? b : 0),
                    UInt8(clamping: on ? mode : 0)])
}

/// 系统使能（固件命令，Windows 主机不发；这里默认发一次以确保输出级打开）
func systemEnableFrame(_ on: Bool) -> Data { frame(.systemEnable, [on ? 1 : 0, 0, 0, 0, 0]) }

/// 查询水表
let queryMeterFrame = frame(.queryMeter, [])

/// 断线（断开连接时发）
let lineOffFrame = frame(.lineOff, [])

/// 睡眠：`FE 19 00 01 00 00 00 EF`
let sleepFrame = frame(.systemMode, [0, 1, 0, 0, 0])

/// 注水/排气 —— 开始：`FE 19 01 04 50 00 00 EF`
let primeStartFrame = frame(.systemMode, [1, 4, 0x50, 0, 0])
/// 注水/排气 —— 停止：`FE 19 00 04 00 00 00 EF`
let primeStopFrame = frame(.systemMode, [0, 4, 0, 0, 0])

// MARK: - 回包解析

enum CoolerResponse {
    case firmwareVersion(String, short: String)
    case meter(state: UInt8, pushed: Bool)
    case unknown(Data)

    var description: String {
        switch self {
        case .firmwareVersion(let full, let short):
            return "固件版本 \"\(full)\" (版本段 = \"\(short)\")"
        case .meter(let state, let pushed):
            let ok = state == 2
            return "水表状态 \(state) = \(ok ? "流量正常" : "异常/告警")" + (pushed ? "（设备主动推送）" : "（查询应答）")
        case .unknown(let data):
            return "未知回包 \(hex(data))"
        }
    }
}

/// 按 GCUService 的 FormatValueByPresentation 逻辑解析：
///   bytes[0] == 0xFE 且 bytes[1] ∈ {0x31, 0x32} -> 水表状态，取 bytes[3]
///   否则整包按 UTF-8 解成固件版本串
func parseResponse(_ data: Data) -> CoolerResponse {
    guard data.count >= 4 else { return .unknown(data) }
    let b = [UInt8](data)
    if b[0] == 0xFE {
        if b[1] == 0x32 { return .meter(state: b[3], pushed: false) }
        if b[1] == 0x31 { return .meter(state: b[3], pushed: true) }
        return .unknown(data)
    }
    let full = String(data: data, encoding: .utf8) ?? ""
    // MergeFWversion: Substring(17)，要求至少 18 字符
    let short = full.count >= 18 ? String(full.dropFirst(17)) : full
    return .firmwareVersion(full, short: short)
}

// MARK: - 工具

func hex(_ d: Data) -> String {
    d.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

func parseHex(_ s: String) -> Data? {
    let cleaned = s.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
    var out = Data()
    var i = cleaned.startIndex
    while i < cleaned.endIndex {
        let j = cleaned.index(i, offsetBy: 2)
        guard let b = UInt8(cleaned[i..<j], radix: 16) else { return nil }
        out.append(b)
        i = j
    }
    return out
}

// MARK: - 离线自检：打印将要发送的帧

func printFrames(_ o: Options) {
    let fc = o.fanLED
    log("""
        将要发送的帧（volt=\(o.volt) -> 电压码 \(voltCode(o.volt))，duty 为 0-100 百分数）:

          握手           \(hex(handshake))
          系统使能 0x1A   \(hex(systemEnableFrame(o.systemEnable)))
          水泵     0x1C   \(hex(pumpFrame(on: true, duty: o.duty, volt: o.volt)))
          风扇     0x1B   \(hex(fanFrame(on: true, duty: max(o.fan, o.fanMin))))
          冷头灯   0x1E   \(hex(headLEDFrame(on: o.ledOn, r: o.headLED.0, g: o.headLED.1, b: o.headLED.2, mode: o.headLED.3)))
          风扇灯   0x33   \(hex(fanLEDFrame(on: fc != nil, r: fc?.0 ?? 0, g: fc?.1 ?? 0, b: fc?.2 ?? 0, mode: fc?.3 ?? 0)))
          查询     0x32   \(hex(queryMeterFrame))
          睡眠     0x19   \(hex(sleepFrame))
          注水开始 0x19   \(hex(primeStartFrame))
          注水停止 0x19   \(hex(primeStopFrame))
          断线     0x38   \(hex(lineOffFrame))

        对照官方文档：
          FE 1C 01 DD VV 00 00 EF   泵开，DD=duty(0-100)，VV=电压码(11V=0 12V=1 7V=2 8V=3)
          FE 1B 01 DD 00 00 00 EF   扇开，DD=duty(0-100)
          FE 1E 01 RR GG BB MM EF   冷头灯，MM=0常亮 1呼吸 2炫彩 3呼吸变色
          73 77                     握手（ASCII "sw"，无 FE/EF）
        """)
}

// MARK: - 参数

struct Options {
    var command = "run"
    var volt = 8           // 水泵电压：7 / 8 / 11 / 12
    var duty = 100         // 水泵占空比 0-100
    var fan = 50           // 风扇占空比 0-100
    var fanMin = 0         // 风扇下限（默认不干预）
    var refresh = 5.0      // 重推泵/扇帧的间隔（秒），0 = 不重推
    var headLED: (Int, Int, Int, Int) = (0, 255, 0, 0)   // R,G,B,mode
    var fanLED: (Int, Int, Int, Int)? = nil              // 默认不发风扇灯（Mk1 不支持）
    var ledOn = true
    var systemEnable = true  // 握手后是否发 FE 1A 01 ..（固件命令，主机默认不发）
    var name: String?
    var address: String?
    var timeout: Double = 8.0
    var connectTimeout = 60.0
    var maxAttempts = 8
    var rawHex: String?
    var serviceUUID: String?
    var writeUUID: String?
    var notifyUUID: String?
    var dwell = 8.0
}

func usage() -> Never {
    log("""
    用法:
      wcooler scan   [--timeout 8]
      wcooler info   [--name 子串] [--address UUID]        # 枚举 GATT，不发控制帧
      wcooler run    [--volt 8] [--duty 100] [--fan 50]
                     [--head-led 0,255,0,0] [--fan-led 0,0,255,0] [--no-led]
                     [--no-sysenable] [--refresh 5] [--fan-min 0]
                     [--name 子串] [--address UUID] [--max-attempts 8]
      wcooler off    [--name 子串] [--address UUID]        # 停泵停扇 + 0x38 断线
      wcooler sleep  [--name 子串] [--address UUID]        # FE 19 00 01 .. 进睡眠
      wcooler prime  [--name 子串] [--address UUID]        # 注水/排气（约 68 秒）
      wcooler probe  [--volt 8] [--name 子串]              # 扫占空比找起转点
      wcooler raw    --hex "FE 1C 01 64 03 00 00 EF" [--name 子串]
      wcooler sweep  [--name 子串] [--dwell 8]             # 逐个可写特征试发
      wcooler frames [--volt 8] [--duty 100] [--fan 50]     # 离线打印将发的帧（不连蓝牙）
      wcooler reset  [--name 子串] [--address UUID]         # 清残留连接态（卡 connecting 时用）

    说明:
      --volt   7|8|11|12  -> 电压码 2|3|0|1
      --led 模式           0=常亮 1=呼吸 2=炫彩 3=呼吸变色
      非 NUS 固件可用 --service/--write/--notify 手工指定 UUID

    常用:
      wcooler scan
      wcooler run --volt 8 --duty 100 --fan 50
      wcooler run --volt 12 --duty 100 --fan 100 --head-led 0,0,255,2
      wcooler prime            # 换水/首次加水后排空气
    """)
    exit(2)
}

func parseArgs() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var o = Options()
    guard let cmd = args.first else { usage() }
    let valid = ["scan", "run", "off", "sleep", "prime", "probe", "raw", "info", "sweep",
                 "frames", "reset"]
    guard valid.contains(cmd) else { usage() }
    o.command = cmd
    args.removeFirst()

    func next() -> String { args.isEmpty ? "" : args.removeFirst() }
    func rgb(_ s: String, default def: (Int, Int, Int, Int)) -> (Int, Int, Int, Int) {
        let parts = s.split(separator: ",").compactMap { Int($0) }
        return parts.count == 4 ? (parts[0], parts[1], parts[2], parts[3]) : def
    }

    while let a = args.first {
        args.removeFirst()
        switch a {
        case "--volt", "--pump":
            let v = Int(next()) ?? o.volt
            o.volt = [7, 8, 11, 12].contains(v) ? v : o.volt
        case "--duty": o.duty = max(0, min(100, Int(next()) ?? o.duty))
        case "--fan":  o.fan  = max(0, min(100, Int(next()) ?? o.fan))
        case "--fan-min": o.fanMin = max(0, min(100, Int(next()) ?? o.fanMin))
        case "--refresh": o.refresh = Double(next()) ?? o.refresh
        case "--head-led": o.headLED = rgb(next(), default: o.headLED)
        case "--led":      o.headLED = rgb(next(), default: o.headLED)   // 兼容旧名
        case "--fan-led":  o.fanLED  = rgb(next(), default: (0, 0, 255, 0))
        case "--no-led": o.ledOn = false
        case "--no-sysenable": o.systemEnable = false
        case "--hex": o.rawHex = next()
        case "--name": o.name = next()
        case "--address": o.address = next()
        case "--timeout": o.timeout = Double(next()) ?? o.timeout
        case "--connect-timeout":
            o.connectTimeout = max(5.0, Double(next()) ?? o.connectTimeout)
        case "--service": o.serviceUUID = next()
        case "--write": o.writeUUID = next()
        case "--notify": o.notifyUUID = next()
        case "--dwell": o.dwell = Double(next()) ?? o.dwell
        case "--max-attempts": o.maxAttempts = max(1, Int(next()) ?? o.maxAttempts)
        case "-h", "--help": usage()
        default:
            log("未知参数: \(a)")
            usage()
        }
    }
    if o.command == "frames" { printFrames(o); exit(0) }
    return o
}

// MARK: - 主逻辑

final class WCooler: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let opts: Options
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var discovered: [CBUUID: [CBCharacteristic]] = [:]
    private var pendingServices = 0
    private var keepAlive: Timer?
    private var found: [(CBPeripheral, Int)] = []
    private var sessionStarted = false
    private var shuttingDown = false
    private var connectAttempts = 0
    private var connectPoll: DispatchWorkItem?
    private var lastLoggedState: CBPeripheralState = .disconnected
    private var connectStartedAt = Date()
    private var lastHeartbeatSec = 0
    private var didClearStale = false

    private var gotHandshakeReply = false
    private var firmwareVersion: String?
    private var meterState: UInt8?

    private var probeStep = 0
    private var probePhase = 0     // 0 = 风扇，1 = 水泵
    private var primeCycle = 0
    private var primeStage = 0

    // 写队列（带超时/重试，杜绝「一次没回调就永久卡死」）
    private struct WriteItem {
        let id: UInt64
        let char: CBCharacteristic
        let data: Data
        let tag: String
        var attempts: Int
    }
    private var queue: [WriteItem] = []
    private var pending: WriteItem?
    private var writeTimer: DispatchWorkItem?
    private var writeSeq: UInt64 = 0
    private var preferResponse = true
    private var timeouts = 0

    init(_ opts: Options) {
        self.opts = opts
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: 扫描 / 连接

    private func matches(_ p: CBPeripheral, _ adv: [String: Any]) -> Bool {
        if let addr = opts.address, !addr.isEmpty {
            return p.identifier.uuidString.lowercased() == addr.lowercased()
        }
        let n = ((adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "")
        if let want = opts.name, !want.isEmpty {
            return n.lowercased().contains(want.lowercased())
        }
        let l = n.lowercased()
        for k in ["coolingsystem", "cooler", "cooling", "lct", "mech", "revo",
                  "water", "liquid", "pump", "水冷", "冰河"] {
            if l.contains(k) { return true }
        }
        return false
    }

    private func stateName(_ s: CBPeripheralState) -> String {
        switch s {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .connected:    return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default:   return "unknown(\(s.rawValue))"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if opts.command == "reset" {
                log("蓝牙就绪，清理残留连接态…")
                after(0.5) { [weak self] in
                    guard let self else { return }
                    let n = self.clearStaleConnections()
                    log(n == 0 ? "没有残留连接态。若魔盒指示灯仍常亮，给它断电重启一次。"
                               : "已取消 \(n) 条残留连接。等 3 秒让链路完全释放后重跑 wcooler run。")
                    self.after(1.0) { exit(0) }
                }
                return
            }
            if opts.command != "scan" && reuseExistingConnection() { return }
            log("蓝牙就绪，开始扫描…")
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            if opts.command == "scan" {
                after(opts.timeout) { self.finishScan() }
            } else {
                after(opts.timeout * 2) {
                    if self.peripheral == nil && self.connectAttempts == 0 && !self.shuttingDown {
                        log("扫描超时，没找到目标设备。先用 `wcooler scan` 看看。")
                        exit(1)
                    }
                }
            }
        case .poweredOff:
            log("蓝牙未开启。检查：系统设置 → 蓝牙；黑苹果还要确认蓝牙 kext 正常。")
        case .unauthorized:
            log("蓝牙权限被拒绝：系统设置 → 隐私与安全性 → 蓝牙，允许本终端。")
        case .unsupported:
            log("本机没有可用的蓝牙（BLE）适配器。")
        default:
            log("蓝牙状态: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "?"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        var detail: [String] = []
        if !services.isEmpty {
            detail.append("    广播服务: \(services.map { $0.uuidString }.joined(separator: ", "))")
        }
        if let md = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            detail.append("    厂商数据: \(hex(md))")
        }
        if let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (u, d) in sd.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                detail.append("    服务数据 \(u.uuidString): \(hex(d))")
            }
        }
        if let conn = advertisementData["kCBAdvDataIsConnectable"] as? NSNumber {
            detail.append("    可连接位: \(conn.boolValue ? "是" : "否")")
        }

        if opts.command == "scan" {
            if !found.contains(where: { $0.0.identifier == peripheral.identifier }) {
                found.append((peripheral, RSSI.intValue))
                let hasNUS = services.contains(nusService)
                log("\(peripheral.identifier.uuidString)  rssi=\(RSSI)  name=\(name)\(hasNUS ? "  [NUS]" : "")")
                for line in detail { log(line) }
            }
            return
        }

        guard !sessionStarted else { return }
        guard matches(peripheral, advertisementData) || services.contains(nusService) else { return }
        if let cur = self.peripheral {
            if cur.identifier == peripheral.identifier { return }
            if cur.state == .connecting || cur.state == .connected { return }
        }

        log("发现目标: \(name) (\(peripheral.identifier.uuidString)) rssi=\(RSSI)")
        for line in detail { log(line) }
        self.peripheral = peripheral
        peripheral.delegate = self
        after(0.25) { [weak self] in self?.startConnect() }
    }

    private func reuseExistingConnection() -> Bool {
        var pool = central.retrieveConnectedPeripherals(withServices: [nusService])
        if let addr = opts.address, !addr.isEmpty, let uuid = UUID(uuidString: addr) {
            pool.append(contentsOf: central.retrievePeripherals(withIdentifiers: [uuid]))
        }
        guard let p = pool.first(where: { $0.state == .connected }) else { return false }
        log("系统已有到 \(p.name ?? "?") 的连接，直接复用。")
        onConnected(p)
        return true
    }

    private func onConnected(_ p: CBPeripheral) {
        connectPoll?.cancel(); connectPoll = nil
        central.stopScan()
        peripheral = p
        p.delegate = self
        connectAttempts = 0
        log("已连接，枚举服务…")
        p.discoverServices(nil)
    }

    /// 清掉残留的僵尸连接态。上次进程被 kill / 崩溃后，蓝牙控制器里的 ACL 链路可能
    /// 还没释放 —— 表现就是魔盒指示灯常亮（它认为还连着）、但 CoreBluetooth 一直卡在
    /// connecting。先主动取消一遍，给新连接腾出干净的链路。
    private func clearStaleConnections() -> Int {
        var pool = central.retrieveConnectedPeripherals(withServices: [nusService])
        if let addr = opts.address, !addr.isEmpty, let uuid = UUID(uuidString: addr) {
            pool.append(contentsOf: central.retrievePeripherals(withIdentifiers: [uuid]))
        }
        var n = 0
        for p in pool where p.state == .connecting || p.state == .connected {
            log("  清理残留连接态：\(p.name ?? "?") state=\(stateName(p.state))")
            central.cancelPeripheralConnection(p)
            n += 1
        }
        return n
    }

    private func startConnect() {
        guard let p = peripheral, !shuttingDown else { return }
        if p.state == .connected { onConnected(p); return }

        if connectAttempts == 0 && !didClearStale {
            didClearStale = true
            if clearStaleConnections() > 0 { after(1.0) { [weak self] in self?.startConnect() }; return }
        }

        connectAttempts += 1
        lastHeartbeatSec = 0
        lastLoggedState = p.state
        connectStartedAt = Date()
        log("连接中（第 \(connectAttempts) 次）… state=\(stateName(p.state))")
        central.connect(p, options: nil)
        // 本机（第三方蓝牙 dongle）实测：didConnect 可能永不回调，必须轮询 state。
        // 实测「短超时取消 → 重扫 → 再连」的循环才撞得上，死等反而一直卡住。
        scheduleConnectPoll(Date().addingTimeInterval(min(opts.connectTimeout, 15.0)))
    }

    private func scheduleConnectPoll(_ deadline: Date) {
        connectPoll?.cancel()
        let wi = DispatchWorkItem { [weak self] in
            guard let self, let pp = self.peripheral, !self.shuttingDown else { return }
            let waited = -self.connectStartedAt.timeIntervalSinceNow

            switch pp.state {
            case .connected:
                log("  state=connected（didConnect 未回调，轮询兜住），进入服务发现。")
                self.onConnected(pp)
                return
            case .connecting:
                if pp.state != self.lastLoggedState {
                    self.lastLoggedState = pp.state
                    log("  state -> connecting")
                }
                let sec = Int(waited)
                if sec >= 5, sec % 5 == 0, sec != self.lastHeartbeatSec {
                    self.lastHeartbeatSec = sec
                    log("  仍在 connecting… 已等待 \(sec)s")
                }
                if Date() >= deadline { self.handleConnectTimeout(pp); return }
                self.scheduleConnectPoll(deadline)
                return
            case .disconnected:
                if waited < 2.0 { self.scheduleConnectPoll(deadline); return }
                if pp.state != self.lastLoggedState {
                    self.lastLoggedState = pp.state
                    log("  state -> disconnected（本次连接失败）")
                }
                self.retryConnect()
                return
            default:
                if pp.state != self.lastLoggedState {
                    self.lastLoggedState = pp.state
                    log("  state -> \(self.stateName(pp.state))")
                }
                if Date() >= deadline { self.handleConnectTimeout(pp); return }
                self.scheduleConnectPoll(deadline)
                return
            }
        }
        connectPoll = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: wi)
    }

    private func handleConnectTimeout(_ p: CBPeripheral) {
        log("  连接超时：\(Int(min(opts.connectTimeout, 15.0)))s 内没到 connected。")
        if let known = central.retrievePeripherals(withIdentifiers: [p.identifier]).first,
           known.state == .connected {
            log("  retrievePeripherals 显示它已 connected —— 直接复用。")
            onConnected(known)
            return
        }
        central.cancelPeripheralConnection(p)
        retryConnect()
    }

    private func retryConnect() {
        guard !shuttingDown else { return }
        if connectAttempts >= opts.maxAttempts {
            log("""
                连不上。按这个顺序试（前两条命中率最高）：

                  1) 给魔盒**断电重启**（拔掉它的供电/USB，等 10 秒再插回）。
                     指示灯常亮 = 魔盒自己认为「还连着某台主机」，于是拒绝新连接 ——
                     这是卡在 connecting 最常见的原因，重启魔盒能立刻清掉它那侧的状态。
                  2) 本机这侧清残留：  wcooler reset
                     再不行就关掉蓝牙 → 等 10 秒 → 重新打开。
                  3) 没有残留 wcooler 进程：pgrep -x wcooler，有就 pkill -x wcooler
                  4) 没被别的主机占着（手机 App / Windows 侧 Control Center、open-revo 全退出）
                  5) 系统设置 → 蓝牙 里若能看到它，先「忽略此设备」再重连
                  6) 若弹配对请求必须点「配对/允许」（SSH 下弹不出来，要在本机「终端」App 跑）
                  7) 用 --address <UUID> 精确指定（UUID 见 `wcooler scan` 输出）
                """)
            exit(1)
        }
        if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        peripheral = nil
        sessionStarted = false
        after(1.5) { [weak self] in
            guard let self, !self.shuttingDown, self.peripheral == nil else { return }
            log("重新扫描…（第 \(self.connectAttempts + 1) 次）")
            self.central.scanForPeripherals(withServices: nil,
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    private func finishScan() {
        central.stopScan()
        if found.isEmpty {
            log("没扫到设备。确认水冷魔盒已通电、没被别的设备占着连接。")
        } else {
            log("提示：用 --name 或 --address 指定目标，然后运行 wcooler run。")
        }
        exit(0)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onConnected(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("连接失败: \(error?.localizedDescription ?? "未知错误")")
        retryConnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        keepAlive?.invalidate()
        if shuttingDown { exit(0) }
        log("连接断开: \(error?.localizedDescription ?? "对端主动断开")")
        exit(1)
    }

    // MARK: 服务 / 特征

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("发现服务失败: \(error.localizedDescription)")
            exit(1)
        }
        guard let services = peripheral.services, !services.isEmpty else {
            log("没有发现任何服务。")
            exit(1)
        }
        log("共 \(services.count) 个服务：")
        for s in services { log("  \(s.uuid.uuidString)") }
        if !services.contains(where: { $0.uuid == nusService }) {
            log("  >> 没有 NUS 服务。LCT21001/LCT22002 应当有 \(nusService.uuidString)，")
            log("     下面枚举全部特征并自动挑一个「可写 + 可通知」的组合。")
        }
        pendingServices = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            log("  发现特征失败 \(service.uuid.uuidString): \(error.localizedDescription)")
        }
        let chars = service.characteristics ?? []
        discovered[service.uuid] = chars
        log("  \(service.uuid.uuidString)：")
        if chars.isEmpty { log("      (无)") }
        for c in chars { log("      \(c.uuid.uuidString)  [\(props(c))]") }

        pendingServices -= 1
        if pendingServices <= 0 { resolveCharacteristics() }
    }

    private func resolveCharacteristics() {
        if opts.command == "info" { readAllReadable(); return }
        if opts.command == "sweep" { runSweep(); return }

        var chosenWrite: CBCharacteristic?
        var chosenNotify: CBCharacteristic?
        var chosenService: CBUUID?

        if let ws = opts.writeUUID {
            let wc = CBUUID(string: ws)
            for (svc, chars) in discovered {
                if let c = chars.first(where: { $0.uuid == wc }) {
                    chosenWrite = c; chosenService = svc
                    chosenNotify = chars.first(where: { $0.properties.contains(.notify) })
                    break
                }
            }
            if chosenWrite == nil { log("没找到 --write 指定的特征 \(ws)"); exit(1) }
            log("使用手工指定的写特征 \(wc.uuidString)")
        } else if let chars = discovered[nusService],
                  let w = chars.first(where: { $0.uuid == nusWrite }) {
            chosenWrite = w
            chosenService = nusService
            chosenNotify = chars.first(where: { $0.uuid == nusNotify })
            log("使用 NUS：写 \(nusWrite.uuidString) / 通知 \(nusNotify.uuidString)")
        } else {
            outer: for (svc, chars) in discovered {
                let w = chars.first(where: { $0.properties.contains(.write)
                                          || $0.properties.contains(.writeWithoutResponse) })
                let n = chars.first(where: { $0.properties.contains(.notify)
                                          || $0.properties.contains(.indicate) })
                if let w, let n { chosenWrite = w; chosenNotify = n; chosenService = svc; break outer }
            }
            if chosenWrite == nil {
                for (svc, chars) in discovered {
                    if let w = chars.first(where: { $0.properties.contains(.write)
                                                 || $0.properties.contains(.writeWithoutResponse) }) {
                        chosenWrite = w; chosenService = svc; break
                    }
                }
            }
            guard let w = chosenWrite else {
                log("这个设备没有任何可写特征，控制不了。上面就是它全部的 GATT 结构。")
                exit(1)
            }
            log(">> NUS 不存在，回退使用服务 \(chosenService?.uuidString ?? "?")")
            log("   写特征 \(w.uuid.uuidString)  [\(props(w))]")
            log(chosenNotify == nil ? "   （该服务没有 notify 特征）" : "   通知特征 \(chosenNotify!.uuid.uuidString)")
        }

        if let ns = opts.notifyUUID {
            let nc = CBUUID(string: ns)
            for (_, chars) in discovered {
                if let c = chars.first(where: { $0.uuid == nc }) { chosenNotify = c; break }
            }
        }

        writeCharacteristic = chosenWrite
        notifyCharacteristic = chosenNotify

        if let n = chosenNotify, n.properties.contains(.notify) || n.properties.contains(.indicate) {
            peripheral?.setNotifyValue(true, for: n)
            after(1.2) { if !self.sessionStarted { self.beginSession() } }
        } else {
            beginSession()
        }
    }

    private func props(_ c: CBCharacteristic) -> String {
        var s: [String] = []
        if c.properties.contains(.read) { s.append("read") }
        if c.properties.contains(.write) { s.append("write") }
        if c.properties.contains(.writeWithoutResponse) { s.append("writeNR") }
        if c.properties.contains(.notify) { s.append("notify") }
        return s.joined(separator: "|")
    }

    private func readAllReadable() {
        guard let p = peripheral else { return }
        var n = 0
        for (_, chars) in discovered {
            for c in chars where c.properties.contains(.read) { n += 1; p.readValue(for: c) }
        }
        log("\n读取 \(n) 个可读特征…")
        after(4.0) { [weak self] in
            log("\ninfo 结束。")
            self?.requestShutdown()
        }
    }

    private var sweepTargets: [CBCharacteristic] = []
    private var sweepIndex = 0

    private func runSweep() {
        sweepTargets.removeAll()
        for (_, chars) in discovered {
            for c in chars where c.properties.contains(.write)
                                  || c.properties.contains(.writeWithoutResponse) { sweepTargets.append(c) }
        }
        guard !sweepTargets.isEmpty else { log("没有任何可写特征。"); exit(1) }
        log("\n=== sweep：对 \(sweepTargets.count) 个可写特征逐个试发 ===")
        log("每个停 \(Int(opts.dwell)) 秒，盯住水泵/风扇看哪一个开始转。\n")
        sweepStep()
    }

    private func sweepStep() {
        guard sweepIndex < sweepTargets.count else {
            log("\n=== sweep 结束。用 --write <UUID> 指定动起来的那个 ===")
            requestShutdown()
            return
        }
        let c = sweepTargets[sweepIndex]
        log("--- [\(sweepIndex + 1)/\(sweepTargets.count)] \(c.uuid.uuidString) ---")
        enqueue(c, handshake, "handshake 'sw'")
        after(0.3) { [weak self] in
            guard let self else { return }
            self.enqueue(c, pumpFrame(on: true, duty: 100, volt: 12), "pump 12V/100%")
            self.enqueue(c, fanFrame(on: true, duty: 100), "fan 100%")
        }
        after(max(2.0, opts.dwell)) { [weak self] in
            guard let self else { return }
            self.enqueue(c, pumpFrame(on: false, duty: 0, volt: 0), "stop pump")
            self.enqueue(c, fanFrame(on: false, duty: 0), "stop fan")
            self.sweepIndex += 1
            self.after(1.0) { self.sweepStep() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { log("订阅通知失败: \(error.localizedDescription)") }
        if !sessionStarted { beginSession() }
    }

    // MARK: 会话

    private func beginSession() {
        guard !sessionStarted, let wc = writeCharacteristic else { return }
        sessionStarted = true

        log("\n握手：写 \"sw\" (73 77)，等待固件版本串…")
        enqueue(wc, handshake, "handshake 'sw'")

        // 4 秒内没等到版本串就明确告警 —— 按官方逻辑，收不到就是连接没建立
        after(4.0) { [weak self] in
            guard let self, !self.shuttingDown else { return }
            if !self.gotHandshakeReply {
                log("""
                    !! 4 秒内没收到固件版本串。按 GCUService 的逻辑，收不到这串就**不算连上**，
                       后续控制帧大概率无效。可能原因：
                         · 写通道选错了 —— 跑 `wcooler info` 看 GATT 结构，用 --write 手工指定；
                         · 该特征不支持 notify，回包收不到 —— 换 --notify 指定；
                         · 设备被别的主机握着，或需要配对确认。
                    """)
            }
        }

        after(0.5) { [weak self] in
            guard let self, let wc = self.writeCharacteristic, !self.shuttingDown else { return }

            // 系统使能：固件命令，Windows 主机不发，但默认发一次确保输出级打开
            if self.opts.systemEnable && self.opts.command != "raw" {
                self.enqueue(wc, systemEnableFrame(true), "system enable (0x1A)")
            }

            switch self.opts.command {
            case "raw":
                guard let s = self.opts.rawHex, let data = parseHex(s) else {
                    log("--hex 解析失败，示例：--hex \"FE 1C 01 64 03 00 00 EF\"")
                    exit(2)
                }
                self.enqueue(wc, data, "raw")
                self.after(1.5) { self.requestShutdown() }
                return

            case "probe":
                self.runProbe()
                return

            case "sleep":
                self.enqueue(wc, sleepFrame, "sleep (0x19 00 01)")
                self.after(1.0) { self.requestShutdown() }
                return

            case "off":
                self.sendStopFrames()
                self.enqueue(wc, lineOffFrame, "line-off (0x38)")
                self.after(1.2) { self.requestShutdown() }
                return

            case "prime":
                self.runPrime()
                return

            default:   // run
                self.applyRunState(initial: true)
            }
        }

        let interval = opts.refresh
        if interval >= 1.0 && opts.command == "run" {
            keepAlive = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self, self.writeCharacteristic != nil, !self.shuttingDown else { return }
                self.applyRunState(initial: false)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            log("系统即将睡眠：停泵…")
            self?.sendStopFrames()
        }

        if opts.command == "run" {
            log("""
                运行中，Ctrl+C 退出（先停泵停扇再断开）。
                  泵 \(self.opts.duty)% @ \(voltLabel(voltCode(self.opts.volt)))（电压码 \(voltCode(self.opts.volt))）
                  扇 \(max(self.opts.fan, self.opts.fanMin))%
                """ + (interval >= 1.0 ? "每 \(Int(interval))s 重推一次状态帧。\n" : "不重推状态帧（--refresh 0）。\n"))
        }
    }

    /// 官方逻辑：握手完成后主机立刻「恢复上次保存的状态」——泵/扇/灯一股脑推下去
    private func applyRunState(initial: Bool) {
        guard let wc = writeCharacteristic, !shuttingDown else { return }
        let duty = max(0, min(100, opts.duty))
        let fanDuty = max(0, min(100, max(opts.fan, opts.fanMin)))
        let tag = initial ? "restore" : "keepalive"

        enqueue(wc, pumpFrame(on: true, duty: duty, volt: opts.volt),
                "\(tag) pump \(duty)% @ \(voltLabel(voltCode(opts.volt)))")
        after(0.12) { [weak self] in
            guard let self, let wc = self.writeCharacteristic, !self.shuttingDown else { return }
            self.enqueue(wc, fanFrame(on: true, duty: fanDuty), "\(tag) fan \(fanDuty)%")
        }
        after(0.24) { [weak self] in
            guard let self, let wc = self.writeCharacteristic, !self.shuttingDown else { return }
            if self.opts.ledOn {
                let (r, g, b, m) = self.opts.headLED
                self.enqueue(wc, headLEDFrame(on: true, r: r, g: g, b: b, mode: m),
                             "\(tag) head led (\(r),\(g),\(b)) mode=\(m)")
                if let (fr, fg, fb, fm) = self.opts.fanLED {
                    self.enqueue(wc, fanLEDFrame(on: true, r: fr, g: fg, b: fb, mode: fm),
                                 "\(tag) fan led (\(fr),\(fg),\(fb)) mode=\(fm)")
                }
            } else {
                self.enqueue(wc, headLEDFrame(on: false, r: 0, g: 0, b: 0, mode: 0), "\(tag) head led off")
                self.enqueue(wc, fanLEDFrame(on: false, r: 0, g: 0, b: 0, mode: 0), "\(tag) fan led off")
            }
        }
    }

    // MARK: probe —— 扫占空比找起转点（duty 是 0-100 百分数）

    private func runProbe() {
        log("\n=== probe：逐级扫占空比（0-100 百分数），每级 6 秒 ===")
        log("盯住风扇/水泵，记下起转的那一级。\n")
        stepProbe([0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    }

    private func stepProbe(_ steps: [Int]) {
        guard let wc = writeCharacteristic, !shuttingDown else { return }
        if probePhase == 0 {
            if probeStep >= steps.count {
                probePhase = 1; probeStep = 0
                log("\n--- 换水泵（电压固定 \(voltLabel(voltCode(opts.volt)))）---\n")
                stepProbe(steps)
                return
            }
            let d = steps[probeStep]
            log("风扇 duty=\(d)%  <- 看风扇")
            enqueue(wc, fanFrame(on: true, duty: d), "probe fan \(d)%")
            probeStep += 1
            after(6.0) { [weak self] in self?.stepProbe(steps) }
        } else {
            if probeStep >= steps.count {
                log("\n=== probe 结束。用 --fan / --duty 填起转的百分数 ===")
                requestShutdown()
                return
            }
            let d = steps[probeStep]
            log("水泵 duty=\(d)%  <- 看水泵")
            enqueue(wc, pumpFrame(on: true, duty: d, volt: opts.volt), "probe pump \(d)%")
            probeStep += 1
            after(6.0) { [weak self] in self?.stepProbe(steps) }
        }
    }

    // MARK: prime —— 注水/排气（官方时序，约 68 秒）

    private func runPrime() {
        guard let wc = writeCharacteristic, !shuttingDown else { return }
        log("\n=== 注水/排气序列开始（约 68 秒，8 个循环）===")
        enqueue(wc, primeStartFrame, "prime start (0x19 01 04 50)")
        enqueue(wc, fanFrame(on: true, duty: 50), "fan 50%")
        after(1.0) { [weak self] in self?.primeLoop() }
    }

    private func primeLoop() {
        guard let wc = writeCharacteristic, !shuttingDown else { return }
        if primeCycle >= 8 {
            enqueue(wc, primeStopFrame, "prime stop (0x19 00 04)")
            log("=== 注水/排气完成 ===")
            after(1.0) { self.requestShutdown() }
            return
        }
        switch primeStage {
        case 0:
            enqueue(wc, pumpFrame(on: false, duty: 0, volt: 0), "prime pump off")
            primeStage = 1
            after(0.5) { [weak self] in self?.primeLoop() }
        case 1:
            log("  循环 \(primeCycle + 1)/8：泵 100% @ 8V，5.5s")
            enqueue(wc, pumpFrame(on: true, duty: 100, volt: 8), "prime pump 100% @ 8V")
            primeStage = 2
            after(5.5) { [weak self] in self?.primeLoop() }
        default:
            enqueue(wc, pumpFrame(on: false, duty: 0, volt: 0), "prime pump off")
            primeStage = 0
            primeCycle += 1
            after(2.5) { [weak self] in self?.primeLoop() }
        }
    }

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    private func sendStopFrames() {
        guard let wc = writeCharacteristic else { return }
        enqueue(wc, pumpFrame(on: false, duty: 0, volt: 0), "stop pump")
        enqueue(wc, fanFrame(on: false, duty: 0), "stop fan")
        enqueue(wc, headLEDFrame(on: false, r: 0, g: 0, b: 0, mode: 0), "stop head led")
        enqueue(wc, fanLEDFrame(on: false, r: 0, g: 0, b: 0, mode: 0), "stop fan led")
    }

    func requestShutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        keepAlive?.invalidate()
        log("退出：停泵停扇…")
        sendStopFrames()
        if let wc = writeCharacteristic { enqueue(wc, lineOffFrame, "line-off (0x38)") }
        after(1.5) {
            if let p = self.peripheral, p.state == .connected || p.state == .connecting {
                self.central.cancelPeripheralConnection(p)
            }
            self.after(0.6) { exit(0) }
        }
    }

    // MARK: 写队列

    private func enqueue(_ c: CBCharacteristic, _ data: Data, _ tag: String) {
        writeSeq += 1
        queue.append(WriteItem(id: writeSeq, char: c, data: data, tag: tag, attempts: 0))
        pumpQueue()
    }

    private func pumpQueue() {
        guard pending == nil, !queue.isEmpty else { return }
        guard let p = peripheral, p.state == .connected else { return }
        var item = queue.removeFirst()
        item.attempts += 1
        pending = item

        let canResponse = item.char.properties.contains(.write)
        let type: CBCharacteristicWriteType =
            (preferResponse && canResponse) ? .withResponse : .withoutResponse

        log("  -> \(hex(item.data))  \(item.tag)\(type == .withResponse ? "" : " [无响应写]")")
        p.writeValue(item.data, for: item.char, type: type)

        if type == .withResponse {
            let id = item.id
            let wi = DispatchWorkItem { [weak self] in
                guard let self, let cur = self.pending, cur.id == id else { return }
                self.timeouts += 1
                self.pending = nil
                if self.timeouts >= 2 {
                    self.preferResponse = false
                    log("  (写响应连续超时，后续改用无响应写)")
                }
                if cur.attempts < 3 {
                    log("  (写超时 #\(cur.attempts)，重试 \(cur.tag))")
                    self.queue.insert(cur, at: 0)
                    self.pumpQueue()
                } else {
                    log("  (放弃 \(cur.tag))")
                    self.pumpQueue()
                }
            }
            writeTimer?.cancel()
            writeTimer = wi
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: wi)
        } else {
            pending = nil
            after(0.06) { [weak self] in self?.pumpQueue() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let was = pending
        writeTimer?.cancel()
        writeTimer = nil
        pending = nil
        if let error = error {
            log("  写失败: \(error.localizedDescription)")
            if let w = was, w.attempts < 3 {
                var retry = w
                retry.attempts += 1
                queue.insert(retry, at: 0)
            }
        } else {
            timeouts = 0
        }
        after(0.06) { [weak self] in self?.pumpQueue() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        if characteristic.uuid == notifyCharacteristic {
            let r = parseResponse(data)
            switch r {
            case .firmwareVersion(let full, let short):
                gotHandshakeReply = true
                firmwareVersion = short
                log("  <- 握手应答：\(r.description)")
                if full.count < 18 {
                    log("     （版本串不足 18 字符，GCUService 会取 Substring(17)，可能解析异常）")
                }
            case .meter(let state, _):
                if meterState != state {
                    meterState = state
                    log("  <- \(r.description)")
                    if state != 2 {
                        log("     !! 流量异常：官方逻辑会把 IsMeterNormal 置 false 并限制 GPU 超频")
                    }
                }
            case .unknown:
                log("  <- \(r.description)")
            }
            return
        }

        // info 命令读回来的特征值
        var ascii = ""
        if let s = String(data: data, encoding: .utf8) {
            ascii = String(s.map { ch -> Character in
                guard let v = ch.asciiValue, v >= 32, v < 127 else { return "." }
                return ch
            })
        }
        log("  \(characteristic.uuid.uuidString) = \(hex(data))\(ascii.isEmpty ? "" : "  \"\(ascii)\"")")
    }
}

// MARK: - 入口

setvbuf(stdout, nil, _IONBF, 0)

let options = parseArgs()
let cooler = WCooler(options)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { cooler.requestShutdown() }
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { cooler.requestShutdown() }
sigterm.resume()

RunLoop.main.run()

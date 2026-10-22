import Foundation
import CoreBluetooth

// MARK: - 协议（依据 Uniwill GCUService.exe IL 逆向 + nRF52832 固件反汇编）

let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let nusWrite   = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
let nusNotify  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

/// 握手帧：ASCII "sw"，不带 0xFE/0xEF
let handshakeBytes = Data([0x73, 0x77])

enum Cmd: UInt8 {
    case systemMode     = 0x19
    case systemEnable   = 0x1A
    case fan            = 0x1B
    case pump           = 0x1C
    case headLED        = 0x1E
    case resetAll       = 0x1F
    case sendTelemetry  = 0x30
    case queryMeter     = 0x32
    case fanLED         = 0x33
    case lineOff        = 0x38
}

/// 灯效模式：0 常亮 / 1 呼吸 / 2 炫彩 / 3 呼吸变色
enum LEDMode: Int, CaseIterable, Identifiable {
    case `static` = 0, breathe = 1, colorful = 2, breatheColor = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .static: return "常亮"
        case .breathe: return "呼吸"
        case .colorful: return "炫彩"
        case .breatheColor: return "呼吸变色"
        }
    }
}

/// 本机（LCT22002）的水泵电压上限是 **11V**，不提供 12V 档。
/// 固件本身支持 12V（码 1），但超出本机上限不用。
let allowedVolts = [7, 8, 11]
let maxVolt = 11

/// 夹到允许档位内；不在列表里就取最接近且不超过上限的档
func clampVolt(_ v: Int) -> Int {
    if allowedVolts.contains(v) { return v }
    return allowedVolts.reduce(allowedVolts[0]) { abs($0 - v) < abs($1 - v) ? $0 : $1 }
}

/// 水泵电压 -> 固件电压码（11V=0 12V=1 7V=2 8V=3）
func voltCode(_ v: Int) -> UInt8 {
    switch clampVolt(v) { case 11: return 0; case 7: return 2; case 8: return 3; default: return 3 }
}
func voltLabel(_ code: UInt8) -> String {
    switch code { case 0: return "11V"; case 1: return "12V"; case 2: return "7V"; default: return "8V" }
}

func frame(_ cmd: Cmd, _ payload: [UInt8]) -> Data {
    var body = Array(payload.prefix(5))
    while body.count < 5 { body.append(0) }
    return Data([0xFE, cmd.rawValue] + body + [0xEF])
}

/// 水泵 `FE 1C <on> <duty 0-100> <volt_code> 00 00 EF`
func pumpFrame(on: Bool, duty: Int, volt: Int) -> Data {
    let d = on ? max(0, min(100, duty)) : 0
    return frame(.pump, [on ? 1 : 0, UInt8(d), on ? voltCode(volt) : 0, 0, 0])
}
/// 风扇 `FE 1B <on> <duty 0-100> 00 00 00 EF`
func fanFrame(on: Bool, duty: Int) -> Data {
    let d = on ? max(0, min(100, duty)) : 0
    return frame(.fan, [on ? 1 : 0, UInt8(d), 0, 0, 0])
}
func headLEDFrame(on: Bool, r: Int, g: Int, b: Int, mode: Int) -> Data {
    frame(.headLED, [on ? 1 : 0] + (on ? [r, g, b, mode] : [0, 0, 0, 0]).map { UInt8(clamping: $0) })
}
func fanLEDFrame(on: Bool, r: Int, g: Int, b: Int, mode: Int) -> Data {
    frame(.fanLED, [on ? 1 : 0] + (on ? [r, g, b, mode] : [0, 0, 0, 0]).map { UInt8(clamping: $0) })
}
func systemEnableFrame(_ on: Bool) -> Data { frame(.systemEnable, [on ? 1 : 0, 0, 0, 0, 0]) }

/// 请求遥测（固件会回一个 25 字节通知）。文档说其格式尚未分析 ——
/// 本工具会把它原样记进日志，便于离线解出温度/流量等字段。
let telemetryFrame = frame(.sendTelemetry, [])
/// 把所有输出复位到默认值（固件命令，主机从不发）
let resetAllFrame = frame(.resetAll, [])

let queryMeterFrame = frame(.queryMeter, [])
let lineOffFrame    = frame(.lineOff, [])
let sleepFrame      = frame(.systemMode, [0, 1, 0, 0, 0])
let primeStartFrame = frame(.systemMode, [1, 4, 0x50, 0, 0])
let primeStopFrame  = frame(.systemMode, [0, 4, 0, 0, 0])

// MARK: - 回包解析

enum CoolerResponse {
    case firmwareVersion(String, short: String)
    case meter(state: UInt8, pushed: Bool)
    case partial(Data)
    case unknown(Data)
}

/// bytes[0]==0xFE 且 bytes[1]∈{0x31,0x32} -> 水表状态取 bytes[3]；否则整包按 UTF-8 解为版本串
func parseResponse(_ data: Data) -> CoolerResponse {
    let b = [UInt8](data)
    if b.count >= 4 && b[0] == 0xFE {
        if b[1] == 0x31 { return .meter(state: b[3], pushed: true) }
        if b[1] == 0x32 { return .meter(state: b[3], pushed: false) }
        return .unknown(data)
    }
    let s = String(data: data, encoding: .utf8) ?? ""
    // 建链瞬间偶尔先吐一个不完整的短包（解出来是乱码），忽略它
    if s.count < 4 || s.contains("\u{FFFD}") { return .partial(data) }
    return .firmwareVersion(s, short: s.count >= 18 ? String(s.dropFirst(17)) : s)
}

func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }

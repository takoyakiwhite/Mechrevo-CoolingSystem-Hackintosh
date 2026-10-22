// 协议一致性回归检查：把组帧结果与 Uniwill GCUService 逆向文档逐条比对。
// 用法： sh gui/check.sh      （改了 Protocol.swift 之后务必跑一遍）
import Foundation
import CoreBluetooth

private var failures = 0

func ck(_ name: String, _ got: String, _ want: String) {
    let ok = got == want
    if !ok { failures += 1 }
    print((ok ? "✅" : "❌") + " \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(got)" + (ok ? "" : "  期望 \(want)"))
}
ck("握手 sw",            hex(handshakeBytes), "73 77")
ck("系统使能 0x1A",       hex(systemEnableFrame(true)),  "FE 1A 01 00 00 00 00 EF")
ck("泵 100% @8V",        hex(pumpFrame(on: true, duty: 100, volt: 8)),  "FE 1C 01 64 03 00 00 EF")
ck("12V 被夹到 11V",      hex(pumpFrame(on: true, duty: 45, volt: 12)),  "FE 1C 01 2D 00 00 00 EF")
ck("泵 45% @7V",         hex(pumpFrame(on: true, duty: 45, volt: 7)),   "FE 1C 01 2D 02 00 00 EF")
ck("泵 45% @11V",        hex(pumpFrame(on: true, duty: 45, volt: 11)),  "FE 1C 01 2D 00 00 00 EF")
ck("泵关",               hex(pumpFrame(on: false, duty: 100, volt: 8)), "FE 1C 00 00 00 00 00 EF")
ck("扇 50%",             hex(fanFrame(on: true, duty: 50)),             "FE 1B 01 32 00 00 00 EF")
ck("扇关",               hex(fanFrame(on: false, duty: 50)),            "FE 1B 00 00 00 00 00 EF")
ck("冷头灯 绿常亮",      hex(headLEDFrame(on: true, r: 0, g: 255, b: 0, mode: 0)), "FE 1E 01 00 FF 00 00 EF")
ck("冷头灯关",           hex(headLEDFrame(on: false, r: 0, g: 255, b: 0, mode: 0)), "FE 1E 00 00 00 00 00 EF")
ck("风扇灯 蓝炫彩",      hex(fanLEDFrame(on: true, r: 0, g: 0, b: 255, mode: 2)), "FE 33 01 00 00 FF 02 EF")
ck("查询水表 0x32",      hex(queryMeterFrame),  "FE 32 00 00 00 00 00 EF")
ck("睡眠",               hex(sleepFrame),       "FE 19 00 01 00 00 00 EF")
ck("注水开始",           hex(primeStartFrame),  "FE 19 01 04 50 00 00 EF")
ck("注水停止",           hex(primeStopFrame),   "FE 19 00 04 00 00 00 EF")
ck("断线 0x38",          hex(lineOffFrame),     "FE 38 00 00 00 00 00 EF")
ck("请求遥测 0x30",        hex(telemetryFrame),   "FE 30 00 00 00 00 00 EF")
ck("复位所有 0x1F",        hex(resetAllFrame),    "FE 1F 00 00 00 00 00 EF")

// 回包解析
let fw = parseResponse(Data("MCU F/W Version: 2.0.0.4".utf8))
if case .firmwareVersion(let full, let short) = fw { ck("版本串解析", "\(short)", "2.0.0.4"); _ = full }
let m1 = parseResponse(Data([0xFE,0x31,0x00,0x02,0x00,0x00,0x00,0xEF]))
if case .meter(let s, let pushed) = m1 { ck("水表推送解析", "state=\(s) pushed=\(pushed)", "state=2 pushed=true") }
let m2 = parseResponse(Data([0xFE,0x32,0x00,0x03,0x00,0x00,0x00,0xEF]))
if case .meter(let s, let pushed) = m2 { ck("水表应答解析", "state=\(s) pushed=\(pushed)", "state=3 pushed=false") }
if case .partial = parseResponse(Data([0x00,0x31])) { print("✅ 短包被忽略") } else { print("❌ 短包未忽略") }

// 曲线插值
print("✅ 均衡泵曲线 0/50/100 ->", [0,50,100].map { Int(interpolate(Preset.balanced.pumpCurve, Double($0)).rounded()) })



// 智能曲线验算：默认映射 45~95℃，看各温度下的泵/扇占空比是否合理
let tMin = 45.0, tMax = 95.0
let pumpMin = 50
print("\n智能曲线（均衡预设，映射 \(Int(tMin))~\(Int(tMax))°C）:")
for t in stride(from: 50.0, through: 95.0, by: 5.0) {
    let x = (t - tMin) / (tMax - tMin) * 100.0
    let pump = max(pumpMin, Int(interpolate(Preset.balanced.pumpCurve, x).rounded()))
    let fan = Int(interpolate(Preset.balanced.fanCurve, x).rounded())
    print(String(format: "  %5.0f°C -> 泵 %3d%%   扇 %3d%%", t, pump, fan))
}

print(failures == 0 ? "\n全部通过：帧编码与回包解析与逆向文档一致。" : "\n有 \(failures) 项不一致！")
// 温度命令探测（不装工具时应返回 nil，走 CPU 负载回退）
if let (t, key) = SMCReader.shared.cpuTemperature() {
    print(String(format: "✅ 原生 SMC CPU 温度：%.2f°C（键 %@）", t, key))
} else {
    print("原生 SMC 读不到 CPU 温度（回退外部命令 / CPU 负载）")
}
// GPU 温度不在 SMC 里 —— 在 nullmoth 驱动 NVAccel 的 PerformanceStatistics["Temperature(C)"]
if let g = GPUReader.shared.gpuTemperature() {
    print(String(format: "✅ NVAccel GPU 温度：%.0f°C", g))
} else {
    print("读不到 GPU 温度（未装 nullmoth 驱动，或驱动未暴露 Temperature(C)）")
}

exit(failures == 0 ? 0 : 1)
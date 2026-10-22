import Foundation
import IOKit

/// 通过 IOKit 直接读 SMC 温度，零依赖（不需要 root，也不需要外部命令）。
///
/// 结构体布局是实测扫出来的（本机 AppleSMC 只认这一组值，其它一律 BadArgument）：
///   size = 80，key@0，dataSize@28，cmd@42，data[32]@48
/// 命令：9 = READ_KEYINFO，5 = READ_BYTES；温度类型 `sp78`，值 = Int16(raw) / 256。
///
/// 实测可用键（i9-14900HX + VirtualSMC/SMCProcessor）：
///   TC0P 53℃（CPU 包/邻近）、TC0D/E/F 54℃（核心）、TC1c/2c/3c 46~47℃
/// GPU 键（TG0P 等）在本机不存在 —— N 卡在 macOS 下没有温度传感器通道。
final class SMCReader {
    static let shared = SMCReader()

    private let SZ = 80
    private let OFF_SIZE = 28
    private let OFF_CMD = 42
    private let OFF_DATA = 48
    private let CMD_READ_KEYINFO: UInt8 = 9
    private let CMD_READ_BYTES: UInt8 = 5

    private var conn: io_connect_t = 0
    private let lock = NSLock()
    /// 每键独立缓存：扫描全部传感器时不能共用一个时间戳，否则后面的键会误命中缓存
    private var cache: [String: (at: Date, value: Double)] = [:]

    /// CPU 温度候选键（实测本机全部可用，见下方注释）
    private let cpuKeys = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC0p",
                           "TC1c", "TC2c", "TC3c"]

    private init() {
        let svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        IOServiceOpen(svc, mach_task_self_, 0, &conn)
    }

    var available: Bool { conn != 0 && cpuTemperature() != nil }

    private func packKey(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for (i, ch) in s.utf8.enumerated() { v |= UInt32(ch) << (8 * (3 - i)) }
        return v
    }

    private func call(key: String, cmd: UInt8, size: UInt8) -> [UInt8]? {
        var inp = [UInt8](repeating: 0, count: SZ)
        inp.withUnsafeMutableBytes {
            $0.storeBytes(of: packKey(key), toByteOffset: 0, as: UInt32.self)
        }
        inp[OFF_SIZE] = size
        inp[OFF_CMD] = cmd
        var out = [UInt8](repeating: 0, count: SZ)
        var outSize = SZ
        let kr = inp.withUnsafeMutableBytes { i in
            out.withUnsafeMutableBytes { o in
                IOConnectCallStructMethod(conn, 2, i.baseAddress!, SZ, o.baseAddress!, &outSize)
            }
        }
        return kr == 0 ? out : nil
    }

    /// 读一个 SMC 键，返回摄氏度；读不到返回 nil
    func celsius(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        // 150ms 内复用缓存：SMC 本身更新也不快，没必要每帧都打内核
        if let hit = cache[key], -hit.at.timeIntervalSinceNow < 0.15 { return hit.value }
        guard let info = call(key: key, cmd: CMD_READ_KEYINFO, size: 0),
              info[OFF_SIZE] > 0,
              let val = call(key: key, cmd: CMD_READ_BYTES, size: info[OFF_SIZE]) else { return nil }
        let raw = Int16(bitPattern: UInt16(val[OFF_DATA]) << 8 | UInt16(val[OFF_DATA + 1]))
        let t = Double(raw) / 256.0
        guard t > -40, t < 140 else { return nil }   // 过滤明显不合理的值
        cache[key] = (Date(), t)
        return t
    }

    /// CPU 温度：取所有可用 CPU 传感器里的**最高值**（控制要看最热的那个，
    /// 只看单个键会低估发热）。返回 (值, 最热的键)
    func cpuTemperature() -> (Double, String)? {
        var best: (Double, String)? = nil
        for k in cpuKeys {
            guard let t = celsius(k) else { continue }
            if best == nil || t > best!.0 { best = (t, k) }
        }
        return best
    }

    /// 扫描已知温度键，返回所有能读到的 —— 供「可用传感器」诊断显示。
    /// 实测本机：只有 CPU 系列可用；内存/GPU/主板全部读不到（没装 SMCSuperIO，
    /// 且笔记本 DDR5 在黑苹果上本来就没有 SMC 映射）。
    func scanSensors() -> [(key: String, celsius: Double)] {
        let keys = cpuKeys + [
            "TM0P", "TM1P", "TM0S", "TM1S", "TM0D", "Tm0P",          // 内存
            "TG0P", "TG0D", "TGDD", "TG1P",                          // GPU
            "TA0P", "TA1P", "TH0P", "Ts0P", "Tp0P", "TN0D", "TW0P",  // 主板/环境
            "TB0T",                                                  // 电池
        ]
        var out: [(String, Double)] = []
        for k in keys { if let t = celsius(k) { out.append((k, t)) } }
        return out
    }

    /// GPU 温度。本机（N 卡 / 无 SMCSuperIO）读不到，返回 nil。
    func gpuTemperature() -> (Double, String)? {
        for k in ["TG0P", "TG0D", "TGDD", "TG1P", "TG0T"] {
            if let t = celsius(k) { return (t, k) }
        }
        return nil
    }
}

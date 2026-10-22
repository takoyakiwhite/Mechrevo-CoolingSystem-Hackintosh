import Foundation
import IOKit

/// 读 GPU 核心温度 —— 走 nullmoth 开源 NVIDIA 驱动暴露的 IORegistry 属性。
///
/// **关键点：这个温度不在 SMC 里。** SMC 的 `TG0P/TG0D/…` 在黑苹果上根本没有，
/// 所以早前只在 SMC 里扫键会误判「GPU 温度读不到」。驱动实际把它放在
/// `NVAccel` 的 `PerformanceStatistics` 字典里，键名 `Temperature(C)` ——
/// 也正是 iStat / 活动监视器读 GPU 面板用的那个键。
///
/// 驱动内部是 250ms 定时读 TSENS（BAR0 偏移 0x20460），并做 1~125℃ 的合理性校验。
/// 需要安装 nullmoth/nvidia-macos-driver；本机 2.5.1 实测可用（待机 47~48℃）。
final class GPUReader {
    static let shared = GPUReader()

    private var service: io_object_t = 0

    private init() {
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("NVAccel"))
    }

    var available: Bool { service != 0 }

    /// GPU 核心温度（摄氏度）；没装驱动或读不到时返回 nil
    func gpuTemperature() -> Double? {
        guard service != 0 else { return nil }
        guard let ps = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? [String: Any] else { return nil }
        let raw = ps["Temperature(C)"]
        if let t = raw as? Int { return Double(t) }
        if let t = raw as? Double { return t }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }
}

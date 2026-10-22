import Foundation
import AppKit
import Combine
import Darwin

// MARK: - 曲线

struct CurvePoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: Double      // 输入（0-100，负载百分数或温度归一化后的百分数）
    var y: Double      // 输出占空比 0-100
}

struct Curve: Codable, Equatable {
    var points: [CurvePoint]
    static let `default` = Curve(points: [
        CurvePoint(x: 0,   y: 50),
        CurvePoint(x: 25,  y: 60),
        CurvePoint(x: 50,  y: 75),
        CurvePoint(x: 75,  y: 90),
        CurvePoint(x: 100, y: 100),
    ])
}

/// 线性插值；x 超出范围则取端点
func interpolate(_ c: Curve, _ x: Double) -> Double {
    let pts = c.points.sorted { $0.x < $1.x }
    guard let first = pts.first, let last = pts.last else { return 0 }
    if x <= first.x { return first.y }
    if x >= last.x { return last.y }
    for i in 0..<pts.count - 1 {
        let a = pts[i], b = pts[i + 1]
        if x >= a.x && x <= b.x {
            let span = max(0.0001, b.x - a.x)
            let t = (x - a.x) / span
            return a.y + (b.y - a.y) * t
        }
    }
    return last.y
}

// MARK: - 预设

enum Preset: String, CaseIterable, Identifiable, Codable {
    case silent, balanced, performance, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .silent: return "静音"
        case .balanced: return "均衡"
        case .performance: return "性能"
        case .custom: return "自定义"
        }
    }
    /// 曲线按「温度归一化百分比」设计：默认映射 45℃ -> 0%、95℃ -> 100%。
    /// 本机实测：待机约 52~58℃，中载约 70℃，满载约 90~100℃。
    var pumpCurve: Curve {
        switch self {
        case .silent:      return Curve(points: [.init(x: 0, y: 45), .init(x: 25, y: 55),
                                                 .init(x: 50, y: 68), .init(x: 75, y: 82),
                                                 .init(x: 100, y: 95)])
        case .balanced:    return Curve(points: [.init(x: 0, y: 50), .init(x: 25, y: 60),
                                                 .init(x: 50, y: 75), .init(x: 75, y: 90),
                                                 .init(x: 100, y: 100)])
        case .performance: return Curve(points: [.init(x: 0, y: 70), .init(x: 25, y: 85),
                                                 .init(x: 50, y: 100), .init(x: 75, y: 100),
                                                 .init(x: 100, y: 100)])
        case .custom:      return .default
        }
    }
    var fanCurve: Curve {
        switch self {
        case .silent:      return Curve(points: [.init(x: 0, y: 20), .init(x: 25, y: 28),
                                                 .init(x: 50, y: 42), .init(x: 75, y: 62),
                                                 .init(x: 100, y: 85)])
        case .balanced:    return Curve(points: [.init(x: 0, y: 25), .init(x: 25, y: 35),
                                                 .init(x: 50, y: 55), .init(x: 75, y: 80),
                                                 .init(x: 100, y: 100)])
        case .performance: return Curve(points: [.init(x: 0, y: 45), .init(x: 25, y: 65),
                                                 .init(x: 50, y: 85), .init(x: 75, y: 100),
                                                 .init(x: 100, y: 100)])
        case .custom:      return .default
        }
    }
}

/// 温度取自哪个器件。本机 CPU 与 GPU 都能读到，一般取两者较高值最稳妥 ——
/// 水冷主要压 CPU，但 GPU 发热同样会把整机温度拉起来。
enum TempSource: String, Codable, CaseIterable, Identifiable {
    case hottest, cpu, gpu
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hottest: return "CPU/GPU 取高"
        case .cpu: return "仅 CPU"
        case .gpu: return "仅 GPU"
        }
    }
}

// MARK: - 配置

struct Config: Codable, Equatable {
    var volt: Int = 8                       // 只允许 7 / 8 / 11（本机上限 11V）
    var smartEnabled: Bool = true
    var preset: Preset = .balanced
    var pumpCurve: Curve = Preset.balanced.pumpCurve
    var fanCurve: Curve = Preset.balanced.fanCurve

    /// 智能模式下的硬下限，避免泵停转
    var pumpMin: Int = 50
    var fanMin: Int = 0

    /// 手动模式的固定档位
    var manualPumpDuty: Int = 100
    var manualFanDuty: Int = 50

    var headLED: LEDSetting = LEDSetting(on: true, r: 0, g: 255, b: 0, mode: 0)
    var fanLED: LEDSetting = LEDSetting(on: false, r: 0, g: 80, b: 255, mode: 2)

    /// 智能控制的输入源：false = CPU 负载，true = 温度。
    /// 默认开：本机已实测 CPU（SMC）与 GPU（NVAccel）都能读到；
    /// 两边都读不到时会自动回退到 CPU 负载。
    var useTemperature: Bool = true
    /// 温度取哪个器件（默认取 CPU/GPU 较高值）
    var tempSource: TempSource = .hottest
    /// 温度优先用原生 SMC 读取（零依赖、免 root）；关掉则只用下面的外部命令
    var preferSMC: Bool = true
    /// 例如 `osx-cpu-temp -c`；输出里的第一个数字会被当作摄氏度。
    /// 仅当 SMC 读不到（或关掉 preferSMC）时才用。
    var tempCommand: String = ""
    /// 温度映射区间。本机实测待机 52~58℃、满载 90~100℃，故下限设 45 而非 40
    /// （40 会让待机就已经跑到曲线中段，白噪音大）
    var tempMin: Double = 45
    var tempMax: Double = 95

    /// 控制回路采样间隔（秒）与滞回阈值（占空比变化小于该值就不下发）
    var sampleInterval: Double = 3.0
    var hysteresis: Int = 3

    /// 是否发 `FE 1A 01 ...`（系统使能）。
    /// 这是**固件内部的一个布尔标志位**（写入 RAM 0x20002b01，同时把 0x200033c8 清 0），
    /// Windows 主机从来不发它 —— 既然官方不发设备也能正常工作，说明默认值就是使能状态，
    /// 所以这帧对功能没有影响。默认关，严格对齐官方行为。
    var sendSystemEnable: Bool = false

    /// 高温/高负载保护：输入超过阈值就强制满档（泵 100% + 扇 100%）
    /// 90℃ 是曲线的兜底 —— 曲线在 95℃ 才到 100%，90℃ 强制满档能提前兜住
    var overheatEnabled: Bool = true
    var overheatThreshold: Double = 90      // 温度模式=°C，CPU 模式=%

    /// 系统通知
    var notifyMeter: Bool = true            // 流量异常
    var notifyDisconnect: Bool = true       // 掉线 / 恢复

    /// 详细日志：逐帧打印收发字节 + 保活推送。正式使用默认关。
    var verbose: Bool = false

    var launchAtLogin: Bool = false
}

// MARK: - 持久化

final class SettingsStore: ObservableObject {
    @Published var cfg: Config {
        didSet { save() }
    }
    private let key = "wcooler.config.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode(Config.self, from: d) {
            cfg = c
        } else {
            cfg = Config()
        }
        // 保险：曲线为空就没法插值（也画不出来），回落到均衡预设
        if cfg.pumpCurve.points.isEmpty { cfg.pumpCurve = Preset.balanced.pumpCurve }
        if cfg.fanCurve.points.isEmpty { cfg.fanCurve = Preset.balanced.fanCurve }
        // 保险：旧配置里可能存了 12V，本机上限是 11V，夹回来
        if !allowedVolts.contains(cfg.volt) { cfg.volt = clampVolt(cfg.volt) }
    }
    func save() {
        if let d = try? JSONEncoder().encode(cfg) { UserDefaults.standard.set(d, forKey: key) }
    }
    func applyPreset(_ p: Preset) {
        guard p != .custom else { cfg.preset = p; return }
        cfg.preset = p
        cfg.pumpCurve = p.pumpCurve
        cfg.fanCurve = p.fanCurve
    }
}

// MARK: - CPU 负载采样

final class CPUMonitor {
    private var prev: (user: Double, sys: Double, idle: Double, nice: Double)?

    /// 返回 0-100 的整体 CPU 占用
    func load() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let cur = (Double(info.cpu_ticks.0), Double(info.cpu_ticks.1),
                   Double(info.cpu_ticks.2), Double(info.cpu_ticks.3))
        defer { prev = cur }
        guard let p = prev else { return 0 }
        let dUser = cur.0 - p.0, dSys = cur.1 - p.1, dIdle = cur.2 - p.2, dNice = cur.3 - p.3
        let total = dUser + dSys + dIdle + dNice
        guard total > 0 else { return 0 }
        return (dUser + dSys + dNice) / total * 100.0
    }
}

// MARK: - 外部温度探针

final class TempProbe {
    private let lock = NSLock()
    private var cache: Double?
    private var busy = false

    /// 立刻返回上一次成功读到的温度（首帧可能是 nil），同时在后台刷新。
    /// 绝不阻塞主线程 —— 用户填的命令可能挂起，同步读会把整个菜单栏卡死。
    func celsius(_ command: String) -> Double? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else {
            lock.lock(); cache = nil; lock.unlock()
            return nil
        }
        if !busy {
            busy = true
            DispatchQueue.global(qos: .utility).async {
                let v = Self.run(cmd)
                self.lock.lock(); self.cache = v; self.busy = false; self.lock.unlock()
            }
        }
        lock.lock(); let v = cache; lock.unlock()
        return v
    }

    /// 常见温度命令候选。SMC 的 IOKit 通道在不少黑苹果上读不了（VirtualSMC 用户端
    /// 打不开 / AppleSMC 直接 BadArgument），所以退而求其次：找已安装的温度命令。
    static let candidates = [
        "osx-cpu-temp -c",
        "osx-cpu-temp",
        "/usr/local/bin/osx-cpu-temp -c",
        "/opt/homebrew/bin/osx-cpu-temp -c",
        "istats cpu --value-only",
        "istats extra --value-only",
    ]

    /// 依次尝试候选命令，返回第一个能取到合理温度（0~130℃）的。
    /// **必须在后台线程调用** —— 每条命令最多阻塞 2.5 秒。
    static func detect() -> String? {
        for cmd in candidates {
            if let v = run(cmd), v > 0, v < 130 { return cmd }
        }
        return nil
    }

    /// 在后台线程执行；2.5 秒还没退出就强杀，避免后台线程也永久挂住
    static func run(_ cmd: String) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
            if p.isRunning { p.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8) else { return nil }
        guard let re = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return Double(s[r])
    }
}

// MARK: - 开机自启

enum LaunchAtLogin {
    private static let label = "com.wcooler.gui"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool, executable: String) -> Bool {
        let fm = FileManager.default
        if !on {
            try? fm.removeItem(at: plistURL)
            return true
        }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
        ]
        do {
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: dict,
                                                           format: .xml, options: 0)
            try data.write(to: plistURL)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 系统通知


enum Notifier {
    private static var ready = false

    static func requestAuthorization() { ready = true }

    /// 用 AppKit 的 NSUserNotificationCenter：Command Line Tools 的 SDK 里
    /// UserNotifications 没有 Swift 模块（要完整 Xcode 才有），所以走这条路。
    /// 它是 deprecated API，若系统不再投递，菜单栏 ⚠️ 与面板横幅仍会告警 —— 不单点依赖。
    static func notify(title: String, body: String) {
        guard ready else { return }
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        n.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(n)
    }
}

// MARK: - 智能控制器

final class SmartController: ObservableObject {
    @Published var inputValue: Double = 0      // 负载% 或 温度℃
    @Published var inputIsTemp = false
    /// 当前实际使用的输入源，界面上直接显示，方便确认到底在按什么控制
    @Published var tempSourceName = "CPU 负载"
    /// 分别记录 CPU / GPU 温度，界面上分开显示
    @Published var cpuTemp: Double?
    @Published var gpuTemp: Double?
    @Published var cpuKey: String?
    @Published var gpuKey: String?
    /// CPU 占用率（0~100）。GPU 占用率目前拿不到：nullmoth 驱动未暴露利用率，
    /// 需要一个 root 守护进程轮询 0x20802096 才行（见上游 PR #323 的说明）。
    @Published var cpuLoad: Double = 0
    @Published var targetPump = 0
    @Published var targetFan = 0

    private let cpu = CPUMonitor()
    private let probe = TempProbe()
    private var lastPump = -999
    private var lastFan = -999

    /// 手动模式下不会调用 evaluate，但界面仍要显示 CPU 占用率，这里单独刷新
    func refreshLoad() { cpuLoad = cpu.load() }

    /// 采样输入并算出目标占空比；返回是否值得下发
    func evaluate(cfg: Config) -> (pump: Int, fan: Int, changed: Bool) {
        var normalized: Double
        // CPU 负载每轮只采样一次：CPUMonitor 靠两次快照做差，重复调用会得到 0
        cpuLoad = cpu.load()
        // 温度取值链：CPU(SMC) / GPU(NVAccel) → 外部命令 → 回退 CPU 负载
        var celsius: Double? = nil
        // 注意别叫 cpu/gpu —— 会和 CPUMonitor 实例属性同名，把它遮蔽掉
        let cpuT = (cfg.useTemperature && cfg.preferSMC) ? SMCReader.shared.cpuTemperature() : nil
        let gpuT = cfg.useTemperature ? GPUReader.shared.gpuTemperature() : nil

        cpuTemp = cpuT?.0
        gpuTemp = gpuT
        cpuKey = cpuT?.1
        gpuKey = gpuT == nil ? nil : "NVAccel"

        if cfg.useTemperature {
            switch cfg.tempSource {
            case .cpu:     celsius = cpuT?.0 ?? gpuT
            case .gpu:     celsius = gpuT ?? cpuT?.0
            case .hottest:
                if let c = cpuT?.0, let g = gpuT { celsius = max(c, g) }
                else { celsius = cpuT?.0 ?? gpuT }
            }
            if celsius != nil {
                var parts: [String] = []
                if let c = cpuT?.0, let k = cpuT?.1 { parts.append(String(format: "%@ %.0f°C", k, c)) }
                if let g = gpuT { parts.append(String(format: "GPU %.0f°C", g)) }
                tempSourceName = parts.joined(separator: " · ")
            }
        }

        if celsius == nil, cfg.useTemperature, !cfg.tempCommand.isEmpty,
           let t = probe.celsius(cfg.tempCommand) {
            celsius = t
            tempSourceName = cfg.tempCommand
        }
        if let c = celsius {
            inputIsTemp = true
            inputValue = c
            let span = max(1, cfg.tempMax - cfg.tempMin)
            normalized = (c - cfg.tempMin) / span * 100.0
        } else {
            inputIsTemp = false
            inputValue = cpuLoad                 // 开头已采样，别再调一次 load()
            normalized = inputValue
            tempSourceName = cfg.useTemperature ? "CPU 负载（温度不可用）" : "CPU 负载"
        }
        normalized = max(0, min(100, normalized))

        let pump = max(cfg.pumpMin, Int(interpolate(cfg.pumpCurve, normalized).rounded()))
        let fan = max(cfg.fanMin, Int(interpolate(cfg.fanCurve, normalized).rounded()))
        targetPump = pump
        targetFan = fan

        let changed = abs(pump - lastPump) >= cfg.hysteresis || abs(fan - lastFan) >= cfg.hysteresis
        if changed { lastPump = pump; lastFan = fan }
        return (pump, fan, changed)
    }

    func reset() { lastPump = -999; lastFan = -999 }
}

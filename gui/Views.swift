import SwiftUI
import AppKit
import Combine

// 兼容旧系统：不用 .secondary / foregroundStyle（需要 macOS 12+ / 14+）
private let dim = Color(NSColor.secondaryLabelColor)

/// 把内容高度上报给宿主，用于设置弹窗高度
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// macOS 11 没有 `View.onChange(of:perform:)`，这里用 Binding 桥接一个兼容写法
extension Binding where Value == Bool {
    func onChangeCompat(_ action: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { wrappedValue }, set: { v in wrappedValue = v; action(v) })
    }
}

// MARK: - 顶层状态机：把引擎、设置、智能控制粘起来

final class AppModel: ObservableObject {
    var engine = CoolerEngine()
    var settings = SettingsStore()
    var smart = SmartController()

    /// 「可用传感器」扫描结果
    @Published var sensors: [(key: String, celsius: Double)] = []

    /// 「控制温度」究竟来自哪个传感器，直接标出来，免得和后面的原始读数混淆
    var controlSourceLabel: String? {
        guard smart.inputIsTemp else { return nil }
        switch settings.cfg.tempSource {
        case .cpu: return "仅 CPU"
        case .gpu: return "仅 GPU"
        case .hottest:
            if let c = smart.cpuTemp, let g = smart.gpuTemp {
                return c >= g ? "来自 CPU" : "来自 GPU"
            }
            return nil
        }
    }

    /// 当前输入归一化到 0~100 后的值，用于在曲线图上标出当前位置
    var normalizedInput: Double? {
        let cfg = settings.cfg
        guard smart.inputIsTemp else { return smart.inputValue }   // CPU 负载本身就是 0~100
        let span = max(1, cfg.tempMax - cfg.tempMin)
        return min(100, max(0, (smart.inputValue - cfg.tempMin) / span * 100.0))
    }

    /// 面板内容的实测高度（由 ContentView 用 GeometryReader 上报）。
    /// 不能依赖 NSHostingView 的 fittingSize —— 外层套了 ScrollView 后它会偏小，
    /// 导致面板永远缩到最小高度。
    @Published var contentHeight: CGFloat = 0

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        settings.$cfg
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] cfg in self?.onConfigChanged(cfg) }
            .store(in: &cancellables)

        // 关键：engine / smart / settings 都是独立的 ObservableObject，
        // SwiftUI 只订阅了 AppModel 的 objectWillChange，嵌套对象的 @Published
        // 变化不会自动传播 —— 不转发的话界面永远停在初始值。
        for src in [engine.objectWillChange, smart.objectWillChange, settings.objectWillChange] {
            src.sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    func start() {
        Notifier.requestAuthorization()
        engine.onStatusChange = { [weak self] ev in self?.handle(ev) }
        engine.sendSystemEnable = settings.cfg.sendSystemEnable
        engine.verbose = settings.cfg.verbose
        engine.start()
        detectTemperatureSource(report: false)
        engine.appendLog("配置：电压 \(settings.cfg.volt)V"
            + "，模式 \(settings.cfg.smartEnabled ? "智能" : "手动")"
            + "，0x1A 系统使能 \(settings.cfg.sendSystemEnable ? "开" : "关")")
        pushCurrent()
        scheduleLoopIfNeeded()
        syncLaunchAtLogin()
    }

    // MARK: 事件 -> 系统通知

    private func handle(_ ev: EngineEvent) {
        let cfg = settings.cfg
        switch ev {
        case .connected(let info):
            if cfg.notifyDisconnect {
                Notifier.notify(title: "水冷魔盒已连接", body: "固件 \(info)")
            }
        case .disconnected(let reason):
            if cfg.notifyDisconnect {
                Notifier.notify(title: "水冷魔盒已断开", body: reason)
            }
        case .meterAbnormal(let st):
            if cfg.notifyMeter {
                Notifier.notify(title: "⚠️ 流量异常",
                                body: "水表状态 \(st)（正常应为 2）。请检查水路，避免水泵干转。")
            }
        case .meterNormal:
            break
        case .overheat(let v):
            Notifier.notify(title: "高温保护已触发", body: v)
        }
    }

    // MARK: 高温/高负载保护

    private var overheated = false

    /// 返回 true 表示已按满档处理，本次不再走曲线
    private func checkOverheat(_ cfg: Config, value: Double) -> Bool {
        guard cfg.overheatEnabled else { overheated = false; return false }
        if value >= cfg.overheatThreshold {
            if !overheated {
                overheated = true
                engine.apply(pumpDuty: 100, volt: cfg.volt, fanDuty: 100,
                             head: cfg.headLED, fan: cfg.fanLED)
                let unit = smart.inputIsTemp ? "°C" : "%"
                let msg = String(format: "输入 %.0f%@ ≥ 阈值 %.0f%@，已强制泵 100%% + 扇 100%%",
                                 value, unit, cfg.overheatThreshold, unit)
                log(msg)
                handle(.overheat(value: msg))      // 统一走事件分发，别在这里单独弹
            }
            return true
        }
        // 回落 5 度/百分点后再交回曲线控制，避免在阈值附近反复横跳
        if value < cfg.overheatThreshold - 5 { overheated = false }
        return false
    }

    private func log(_ s: String) { engine.appendLog(s) }

    /// 导出日志到 ~/Library/Logs，排查时直接贴文件即可
    func exportLog() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("wcooler-\(Int(Date().timeIntervalSince1970)).log")
        let text = engine.logLines.joined(separator: "\n")
        try? text.write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }

    private func scheduleLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1.0, settings.cfg.sampleInterval),
                                     repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let cfg = settings.cfg
        guard cfg.smartEnabled else { smart.refreshLoad(); return }
        let r = smart.evaluate(cfg: cfg)
        if checkOverheat(cfg, value: smart.inputValue) { return }
        guard r.changed else { return }
        // 风扇灯帧必须**每次都发**（就算 off）：只在 on 时发的话，
        // 关灯后设备会维持上一次的状态，灯永远关不掉。
        engine.apply(pumpDuty: r.pump, volt: cfg.volt, fanDuty: r.fan,
                     head: cfg.headLED, fan: cfg.fanLED)
    }

    private func onConfigChanged(_ cfg: Config) {
        syncLaunchAtLogin()
        engine.sendSystemEnable = cfg.sendSystemEnable
        engine.verbose = cfg.verbose
        scheduleLoopIfNeeded()
        if !cfg.smartEnabled {
            engine.apply(pumpDuty: cfg.manualPumpDuty, volt: cfg.volt, fanDuty: cfg.manualFanDuty,
                         head: cfg.headLED, fan: cfg.fanLED)
        } else {
            smart.reset()
            tick()
        }
    }

    /// 采样间隔没变就别重建定时器：拖滑块时配置会高频变更，
    /// 每次都 invalidate + 重建没必要。
    private var loopInterval: Double = -1
    private func scheduleLoopIfNeeded() {
        let iv = max(1.0, settings.cfg.sampleInterval)
        if abs(iv - loopInterval) < 0.01 { return }
        loopInterval = iv
        scheduleLoop()
    }

    func pushCurrent() {
        let cfg = settings.cfg
        // 风扇灯帧始终下发（含 off）：只在 on 时发的话，关灯后设备会维持上次状态
        if cfg.smartEnabled {
            let r = smart.evaluate(cfg: cfg)
            engine.apply(pumpDuty: r.pump, volt: cfg.volt, fanDuty: r.fan,
                         head: cfg.headLED, fan: cfg.fanLED)
        } else {
            engine.apply(pumpDuty: cfg.manualPumpDuty, volt: cfg.volt, fanDuty: cfg.manualFanDuty,
                         head: cfg.headLED, fan: cfg.fanLED)
        }
    }

    private func syncLaunchAtLogin() {
        guard settings.cfg.launchAtLogin != LaunchAtLogin.isEnabled else { return }
        guard let exe = Bundle.main.executablePath, !exe.isEmpty else {
            engine.appendLog("开机自启：拿不到可执行文件路径，已跳过")
            return
        }
        _ = LaunchAtLogin.setEnabled(settings.cfg.launchAtLogin, executable: exe)
    }

    /// 探测可用的温度命令（后台执行，找到就写回配置）。
    /// SMC 通道在不少黑苹果上不可用，所以只能靠外部命令；没装就回退 CPU 负载。
    func detectTemperatureSource(report: Bool = true) {
        guard settings.cfg.useTemperature else { return }
        // SMC 能用就别费劲去 shell 里试 6 条命令（每条最多 2.5 秒）
        if settings.cfg.preferSMC && SMCReader.shared.available {
            if report { engine.appendLog("温度源：原生 SMC 可用，无需外部命令") }
            return
        }
        if !settings.cfg.tempCommand.isEmpty && !report { return }
        DispatchQueue.global(qos: .utility).async {
            let found = TempProbe.detect()
            DispatchQueue.main.async {
                if let f = found {
                    self.settings.cfg.tempCommand = f
                    self.engine.appendLog("温度源：已识别 \(f)")
                } else {
                    self.engine.appendLog(
                        "温度源：没找到可用的温度命令（可 brew install osx-cpu-temp），"
                        + "已回退到 CPU 负载")
                }
            }
        }
    }

    func reconnect() {
        engine.stop(graceful: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.engine.start()
            self?.pushCurrent()
        }
    }

    func quit() {
        engine.stop(graceful: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { NSApp.terminate(nil) }
    }
}

// MARK: - 颜色桥接

func rgbBinding(_ led: Binding<LEDSetting>) -> Binding<Color> {
    Binding(
        get: {
            let s = led.wrappedValue
            return Color(red: Double(s.r) / 255, green: Double(s.g) / 255, blue: Double(s.b) / 255)
        },
        set: { c in
            let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? NSColor(red: 0, green: 1, blue: 0, alpha: 1)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getRed(&r, green: &g, blue: &b, alpha: &a)
            led.wrappedValue.r = Int(round(r * 255))
            led.wrappedValue.g = Int(round(g * 255))
            led.wrappedValue.b = Int(round(b * 255))
        }
    )
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLog = false
    @State private var showSettings = false
    @State private var priming = false

    var body: some View {
        // 整体可滚动：内容再长也不会把面板顶出屏幕
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                if let a = model.engine.alert { alertBanner(a) }
                header
                Divider()
                controlSection
                Divider()
                ledSection
                Divider()
                actions
                if showSettings { Divider(); settingsSection }
                if showLog { Divider(); logSection }
                HStack {
                    Button(showSettings ? "隐藏设置" : "设置") { showSettings.toggle() }
                        .buttonStyle(.link)
                    Button(showLog ? "隐藏日志" : "日志") { showLog.toggle() }
                        .buttonStyle(.link)
                    Spacer()
                    Button("退出") { model.quit() }
                        .buttonStyle(.link)
                }
            }
            .padding(14)
            .frame(width: 340)
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
            })
        }
        .frame(width: 340)
        .onPreferenceChange(ContentHeightKey.self) { model.contentHeight = $0 }
    }

    // MARK: 告警横幅

    private func alertBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            Text(text).font(.caption2).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("知道了") { model.engine.alert = nil }
                .controlSize(.mini)
        }
        .padding(6)
        .background(Color.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 9, height: 9)
                Text(model.engine.state.rawValue).font(.headline)
                Spacer()
                if let fw = model.engine.firmware {
                    Text("FW \(fw)")
                        .font(.caption).foregroundColor(dim)
                        .help("版本串首位即世代：2.x = LCT22002(Mk2)，1.x = LCT21001(Mk1)")
                }
                // 只在拿到固件版本后显示机型 —— 未连接时 isMk2 是默认值，显示出来是误导
                if model.engine.firmware != nil {
                    Text(model.engine.isMk2 ? "Mk2" : "Mk1")
                        .font(.caption2).foregroundColor(dim)
                        .help(model.engine.isMk2 ? "LCT22002：支持风扇灯效 0x33"
                                                 : "LCT21001：固件不支持风扇灯效 0x33")
                }
            }
            HStack(spacing: 10) {
                meterTag
                if let r = model.engine.rssi {
                    Text("rssi \(r)").font(.caption).foregroundColor(dim)
                }
                Text("泵 \(model.engine.pumpDuty)% · 扇 \(model.engine.fanDuty)%")
                    .font(.caption).foregroundColor(dim)
            }
            if let e = model.engine.lastError {
                Text(e).font(.caption).foregroundColor(.red)
            }
        }
    }

    private var stateColor: Color {
        switch model.engine.state {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .gray
        default: return .orange
        }
    }

    private var meterTag: some View {
        Group {
            if let ok = model.engine.meterOK {
                Text(ok ? "水表 正常" : "水表 异常")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(ok ? Color.green.opacity(0.18) : Color.red.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("水表 --").font(.caption).foregroundColor(dim)
            }
        }
    }

    // MARK: 控制

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("智能控制", isOn: $model.settings.cfg.smartEnabled)

            HStack {
                Text("水泵电压").font(.caption2)
                Picker("", selection: $model.settings.cfg.volt) {
                    Text("7V").tag(7); Text("8V").tag(8); Text("11V").tag(11)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("上限 11V").font(.caption2).foregroundColor(dim)
            }
            .help("本机（LCT22002）水泵最高 11V，已移除 12V 档")

            if model.settings.cfg.smartEnabled {
                HStack(spacing: 2) {
                    // 单位单独用常规字体：℃ 是 U+2103（CJK 兼容字符），
                    // 等宽字体 SF Mono 里没有这个字形，会被渲染成空白。
                    Text(model.smart.inputIsTemp ? "控制温度" : "CPU")
                        .font(.caption2).foregroundColor(dim)
                    Text(String(format: "%.0f", model.smart.inputValue))
                        .font(.system(.callout, design: .monospaced))
                    Text(model.smart.inputIsTemp ? "°C" : "%")
                        .font(.callout)
                    if let src = model.controlSourceLabel {
                        Text(src).font(.caption2).foregroundColor(dim)
                    }
                }
                .help("「控制温度」= 真正驱动泵/扇曲线的那个数值，由「温度取自」决定"
                      + "（默认取 CPU 与 GPU 的较高值）；后面两个是各自的原始读数。"
                      + "它会被映射到 45~95℃ 区间，再查曲线得出泵/扇占空比。")

                // 温度与占用率分开一行列出；GPU 占用率本机拿不到，如实标注
                HStack(spacing: 10) {
                    if let c = model.smart.cpuTemp {
                        Text(String(format: "CPU %.0f°C %.0f%%", c, model.smart.cpuLoad))
                            .font(.caption).foregroundColor(dim)
                    } else {
                        Text(String(format: "CPU 负载 %.0f%%", model.smart.cpuLoad))
                            .font(.caption).foregroundColor(dim)
                    }
                    if let g = model.smart.gpuTemp {
                        Text(String(format: "GPU %.0f°C", g))
                            .font(.caption).foregroundColor(dim)
                    }
                    Spacer()
                    Text("目标 泵 \(model.smart.targetPump)% · 扇 \(model.smart.targetFan)%")
                        .font(.caption).foregroundColor(dim)
                }
                .help("CPU 占用率来自 host_cpu_load_info。"
                      + "GPU 占用率本机拿不到：nullmoth 驱动未暴露利用率，"
                      + "需要一个 root 守护进程轮询寄存器才行。")
                Picker("", selection: Binding(
                    get: { model.settings.cfg.preset },
                    set: { model.settings.applyPreset($0) }
                )) {
                    ForEach(Preset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                curveEditor(title: "水泵曲线", curve: $model.settings.cfg.pumpCurve,
                            preset: $model.settings.cfg.preset, color: .blue)
                curveEditor(title: "风扇曲线", curve: $model.settings.cfg.fanCurve,
                            preset: $model.settings.cfg.preset, color: .green)

                HStack {
                    Text("泵下限").font(.caption2)
                    Slider(value: Binding(get: { Double(model.settings.cfg.pumpMin) },
                                          set: { model.settings.cfg.pumpMin = Int($0) }),
                           in: 0...100, step: 5)
                    Text("\(model.settings.cfg.pumpMin)%")
                        .font(.system(.caption2, design: .monospaced))
                }
            } else {
                sliderRow("水泵", value: $model.settings.cfg.manualPumpDuty)
                sliderRow("风扇", value: $model.settings.cfg.manualFanDuty)
                Button("立即应用") { model.pushCurrent() }.controlSize(.small)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).frame(width: 34, alignment: .leading).font(.caption2)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0) }),
                   in: 0...100, step: 5)
            Text("\(value.wrappedValue)%")
                .font(.system(.caption2, design: .monospaced)).frame(width: 38)
        }
    }

    private func curveEditor(title: String, curve: Binding<Curve>,
                             preset: Binding<Preset>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2).foregroundColor(dim)
                Spacer()
                Text("输入=负载/温度 · 输出=占空比").font(.caption2).foregroundColor(dim)
            }
            curveChart(curve.wrappedValue, color: color,
                       marker: model.normalizedInput)
            ForEach(curve.wrappedValue.points.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    // 注意：数值不能放在 Stepper 的 label 里 —— 加了 .labelsHidden()
                    // 会把 label 一起隐藏，结果只剩 +/- 按钮、曲线看起来是空的。
                    Text("\(Int(curve.wrappedValue.points[i].x))%")
                        .font(.system(.caption2, design: .monospaced))
                        .frame(width: 32, alignment: .trailing)
                    Stepper("", value: Binding(
                        get: { curve.wrappedValue.points[i].x },
                        set: { curve.wrappedValue.points[i].x = $0
                               preset.wrappedValue = .custom }),
                            in: 0...100, step: 10).labelsHidden()
                    Text("→").font(.caption2).foregroundColor(dim)
                    Stepper("", value: Binding(
                        get: { curve.wrappedValue.points[i].y },
                        set: { curve.wrappedValue.points[i].y = $0
                               preset.wrappedValue = .custom }),
                            in: 0...100, step: 5).labelsHidden()
                    Text("\(Int(curve.wrappedValue.points[i].y))%")
                        .font(.system(.caption2, design: .monospaced))
                        .frame(width: 38, alignment: .leading)
                    Spacer()
                }
            }
        }
    }

    /// 曲线缩略图：一眼看出形状对不对，也能直观确认曲线不是空的。
    /// marker = 当前输入在曲线上的位置（0~100），能直接看到现在跑在哪一段。
    private func curveChart(_ curve: Curve, color: Color, marker: Double? = nil) -> some View {
        let pts = curve.points.sorted { $0.x < $1.x }
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(NSColor.controlBackgroundColor))
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Path { p in
                        for i in 1..<4 {
                            let y = h * CGFloat(i) / 4.0
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: w, y: y))
                        }
                    }
                    .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)

                    Path { p in
                        for (i, pt) in pts.enumerated() {
                            let x = w * CGFloat(min(100, max(0, pt.x)) / 100.0)
                            let y = h - h * CGFloat(min(100, max(0, pt.y)) / 100.0)
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(color, lineWidth: 1.6)

                    ForEach(pts.indices, id: \.self) { i in
                        let x = w * CGFloat(min(100, max(0, pts[i].x)) / 100.0)
                        let y = h - h * CGFloat(min(100, max(0, pts[i].y)) / 100.0)
                        Circle().fill(color)
                            .frame(width: 5, height: 5)
                            .position(x: x, y: y)
                    }

                    // 当前输入所在位置：一条竖线 + 交点，直观看到现在跑在哪一段
                    if let m = marker {
                        let mx = w * CGFloat(min(100, max(0, m)) / 100.0)
                        let my = h - h * CGFloat(min(100, max(0, interpolate(curve, m))) / 100.0)
                        Path { p in
                            p.move(to: CGPoint(x: mx, y: 0))
                            p.addLine(to: CGPoint(x: mx, y: h))
                        }
                        .stroke(Color.orange.opacity(0.6), lineWidth: 1)
                        Circle().stroke(Color.orange, lineWidth: 1.5)
                            .frame(width: 7, height: 7)
                            .position(x: mx, y: my)
                    }
                }
            }
        }
        .frame(height: 46)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: 灯效

    private var ledSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ledRow("冷头灯", led: $model.settings.cfg.headLED)
            if model.engine.isMk2 {
                ledRow("风扇灯", led: $model.settings.cfg.fanLED)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundColor(.orange)
                    Text("本机是 Mk1（LCT21001），固件不支持风扇灯效 0x33，已隐藏")
                        .font(.caption2).foregroundColor(dim)
                }
            }
        }
    }

    private func ledRow(_ title: String, led: Binding<LEDSetting>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: led.on).labelsHidden()
            Text(title).font(.caption2).frame(width: 42, alignment: .leading)
            ColorPicker("", selection: rgbBinding(led)).labelsHidden().frame(width: 44)
            Picker("", selection: led.mode) {
                ForEach(LEDMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden().frame(width: 92)
            Spacer()
        }
    }

    // MARK: 操作

    private var actions: some View {
        HStack(spacing: 8) {
            Button(priming ? "注水中…" : "注水/排气") {
                priming = true
                model.engine.prime { priming = false }
            }
            .disabled(priming || !model.engine.connected)
            .controlSize(.small)

            Button("重连") { model.reconnect() }.controlSize(.small)
            Spacer()
        }
    }

    /// 高级 / 诊断：日常用不到，收在这里不占主面板
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("高级 / 诊断").font(.caption2).foregroundColor(dim)
            HStack(spacing: 8) {
                Button("0x30 探测") { model.engine.requestTelemetry() }
                    .controlSize(.small)
                    .disabled(!model.engine.connected)
                    .help("请求 0x30。v2.0.0.4 实测只回版本串，供其它固件批次探测")
                Button("复位输出") { model.engine.resetAll() }
                    .controlSize(.small)
                    .disabled(!model.engine.connected)
                    .help("把所有输出复位到固件默认值（0x1F）")
                Spacer()
            }
            Toggle("详细日志（逐帧打印收发的字节）", isOn: $model.settings.cfg.verbose)
            if let t = model.engine.lastTelemetry {
                Text("最近 0x30 回包：\(t)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(dim).lineLimit(3)
            }
            Button("导出日志到 ~/Library/Logs") {
                let path = model.exportLog()
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .controlSize(.small)

            Divider()
            HStack {
                Text("可用传感器").font(.caption2).foregroundColor(dim)
                Spacer()
                Button("扫描") { model.sensors = SMCReader.shared.scanSensors() }
                    .controlSize(.mini)
            }
            if model.sensors.isEmpty {
                Text("点「扫描」列出 SMC 里能读到的温度键")
                    .font(.caption2).foregroundColor(dim)
            } else {
                ForEach(model.sensors, id: \.key) { s in
                    Text(String(format: "  %@  %.1f°C", s.key, s.celsius))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(dim)
                }
                Text("内存/GPU/主板在本机无传感器：没装 SMCSuperIO，"
                     + "且 N 卡与笔记本 DDR5 在 macOS 下本来就没有 SMC 温度映射")
                    .font(.caption2).foregroundColor(dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("开机自启", isOn: $model.settings.cfg.launchAtLogin)
            Toggle("握手后发 0x1A 系统使能", isOn: $model.settings.cfg.sendSystemEnable)
            Text("0x1A 只是固件内部的一个标志位（置 RAM 标志 + 清一个计数器）。"
                 + "官方主机从不发它，设备默认就是使能状态，所以开与关对功能没有影响 —— "
                 + "默认关，严格对齐官方行为。")
                .font(.caption2).foregroundColor(dim)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("用温度驱动智能控制",
                   isOn: $model.settings.cfg.useTemperature
                    .onChangeCompat { on in if on { model.detectTemperatureSource() } })
            if model.settings.cfg.useTemperature {
                HStack {
                    Text("温度取自").font(.caption2)
                    Picker("", selection: $model.settings.cfg.tempSource) {
                        ForEach(TempSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Text("当前：\(model.smart.tempSourceName)")
                    .font(.caption2).foregroundColor(dim).lineLimit(2)
                Toggle("优先用原生 SMC 读取（免 root）", isOn: $model.settings.cfg.preferSMC)
                if !model.settings.cfg.preferSMC {
                    Button("探测温度命令") { model.detectTemperatureSource() }
                        .controlSize(.mini)
                    Text("已配置：\(model.settings.cfg.tempCommand.isEmpty ? "（无）" : model.settings.cfg.tempCommand)")
                        .font(.caption2).foregroundColor(dim).lineLimit(2)
                }
                Text("GPU 温度：本机无可用传感器（N 卡在 macOS 下没有温度通道），"
                     + "只能用 CPU 温度驱动")
                    .font(.caption2).foregroundColor(dim).fixedSize(horizontal: false, vertical: true)
            }
            if model.settings.cfg.useTemperature {
                TextField("温度命令，如 osx-cpu-temp -c", text: $model.settings.cfg.tempCommand)
                    .textFieldStyle(.roundedBorder).font(.caption2)
                HStack(spacing: 2) {
                    Text("映射").font(.caption2)
                    Slider(value: $model.settings.cfg.tempMin, in: 20...70, step: 1)
                    Text(String(format: "%.0f", model.settings.cfg.tempMin))
                        .font(.system(.caption2, design: .monospaced))
                    Text("→").font(.caption2)
                    Text(String(format: "%.0f", model.settings.cfg.tempMax))
                        .font(.system(.caption2, design: .monospaced))
                    Text("°C").font(.caption2)
                    Slider(value: $model.settings.cfg.tempMax, in: 60...120, step: 1)
                }
            }
            HStack {
                Text("采样间隔").font(.caption2)
                Slider(value: $model.settings.cfg.sampleInterval, in: 1...15, step: 1)
                Text("\(Int(model.settings.cfg.sampleInterval))s")
                    .font(.system(.caption2, design: .monospaced))
            }
            HStack {
                Text("滞回阈值").font(.caption2)
                Slider(value: Binding(get: { Double(model.settings.cfg.hysteresis) },
                                      set: { model.settings.cfg.hysteresis = Int($0) }),
                       in: 1...20, step: 1)
                Text("\(model.settings.cfg.hysteresis)%")
                    .font(.system(.caption2, design: .monospaced))
            }

            Divider()
            Text("保护与通知").font(.caption2).foregroundColor(dim)
            Toggle("高温/高负载强制满档", isOn: $model.settings.cfg.overheatEnabled)
            if model.settings.cfg.overheatEnabled {
                HStack(spacing: 2) {
                    Text("阈值").font(.caption2)
                    Slider(value: $model.settings.cfg.overheatThreshold, in: 50...100, step: 1)
                    Text("\(Int(model.settings.cfg.overheatThreshold))")
                        .font(.system(.caption2, design: .monospaced))
                    Text(model.settings.cfg.useTemperature ? "°C" : "%")
                        .font(.caption2)
                }
            }
            Toggle("流量异常时通知", isOn: $model.settings.cfg.notifyMeter)
            Toggle("掉线/恢复时通知", isOn: $model.settings.cfg.notifyDisconnect)

            Divider()
            advancedSection
        }
    }

    // MARK: 日志

    private var logSection: some View {
        // 外层已经是 ScrollView，这里不要再嵌一层（嵌套滚动会抢手势）
        VStack(alignment: .leading, spacing: 1) {
            // 用行号当 id：日志内容会重复，用字符串当 id 会渲染错乱
            ForEach(Array(model.engine.logLines.suffix(80).enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(dim)
    }
}

import Foundation
import CoreBluetooth
import Combine

// MARK: - 灯效设置

struct LEDSetting: Codable, Equatable {
    var on: Bool = true
    var r: Int = 0
    var g: Int = 255
    var b: Int = 0
    var mode: Int = 0
}

// MARK: - 引擎状态

enum EngineState: String {
    case idle = "未连接"
    case scanning = "扫描中"
    case connecting = "连接中"
    case handshake = "握手中"
    case connected = "已连接"
    case failed = "连接失败"
}

/// 值得打扰用户的事件（交给 AppModel 决定是否弹系统通知）
enum EngineEvent {
    case connected(info: String)
    case disconnected(reason: String)
    case meterAbnormal(state: Int)
    case meterNormal
    case overheat(value: String)
}

/// BLE 引擎：负责建链、握手、保活、收包与优雅停止。
/// 全部跑在主队列上，方便直接驱动 SwiftUI。
final class CoolerEngine: NSObject, ObservableObject,
                          CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: 对外状态

    @Published var state: EngineState = .idle
    @Published var firmware: String?
    @Published var meterOK: Bool?
    @Published var rssi: Int?
    @Published var lastError: String?
    @Published var logLines: [String] = []
    @Published var pumpDuty = 0
    @Published var fanDuty = 0
    @Published var volt = 8
    @Published var deviceName: String?
    /// LCT22002（固件 2.x）= Mk2，支持 0x33 风扇灯；LCT21001（1.x）= Mk1，不支持
    @Published var isMk2 = true
    /// 最近一次遥测原文（25 字节），供排查/离线分析用
    @Published var lastTelemetry: String?
    /// 非空时在面板顶部显示告警横幅、菜单栏图标变 ⚠️。
    /// 这条链路不依赖系统通知 —— 通知可能被系统静默，横幅不会。
    @Published var alert: String?

    var connected: Bool { state == .connected }

    /// 握手后是否发 `FE 1A 01 ...` 系统使能。这是固件命令，Windows 主机从不发；
    /// 默认开着（更保险），可在设置里关掉以严格对齐官方行为。
    var sendSystemEnable = true

    /// 详细日志：开启后才会逐帧打印 `-> FE ...` / 保活推送等调试信息。
    /// 正式使用默认关闭，日志里只保留状态变化与异常。
    var verbose = false

    /// 状态事件回调（用于弹系统通知）
    var onStatusChange: ((EngineEvent) -> Void)?

    // MARK: 内部

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var scanTimer: Timer?
    private var keepAlive: Timer?
    private var connectPoll: Timer?
    private var attachWatchdog: Timer?
    private var connectStartedAt = Date()

    /// 没有 NUS 时进入回退模式：枚举全部特征再挑一对
    private var fallbackMode = false
    private var discovered: [CBUUID: [CBCharacteristic]] = [:]

    private var queue: [(data: Data, tag: String)] = []
    private var writing = false
    private var writeTimer: DispatchWorkItem?

    /// 刚发了 0x30 遥测请求，下一包按遥测原文处理（否则会被当成固件版本串）
    private var awaitingTelemetry = false

    private var wantRun = false
    private var attempt = 0
    private let maxAttempts = 10
    /// 注水序列期间暂停保活，否则 5 秒一次的保活帧会打断 68 秒的时序
    private var priming = false
    private var waitingForPower = false

    /// 当前要维持的状态（保活与重连后恢复都用它）
    private var current = CurrentState()
    struct CurrentState {
        var pumpDuty = 0
        var fanDuty = 0
        var volt = 8
        var head: LEDSetting? = nil
        var fan: LEDSetting? = nil
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: 生命周期

    func start() {
        wantRun = true
        attempt = 0
        log("启动，开始查找水冷魔盒…")
        beginConnectCycle()
    }

    func stop(graceful: Bool = true) {
        wantRun = false
        scanTimer?.invalidate(); keepAlive?.invalidate(); connectPoll?.invalidate()
        if graceful, peripheral?.state == .connected {
            log("停止：停泵停扇…")
            enqueue(pumpFrame(on: false, duty: 0, volt: 0), "stop pump")
            enqueue(fanFrame(on: false, duty: 0), "stop fan")
            enqueue(headLEDFrame(on: false, r: 0, g: 0, b: 0, mode: 0), "stop head led")
            enqueue(fanLEDFrame(on: false, r: 0, g: 0, b: 0, mode: 0), "stop fan led")
            enqueue(lineOffFrame, "line-off 0x38")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.teardown() }
        } else {
            teardown()
        }
    }

    private func teardown() {
        scanTimer?.invalidate(); keepAlive?.invalidate()
        connectPoll?.invalidate(); attachWatchdog?.invalidate()
        if let p = peripheral, p.state == .connected || p.state == .connecting {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil; writeChar = nil; notifyChar = nil
        priming = false
        fallbackMode = false
        discovered.removeAll()
        queue.removeAll(); writing = false
        state = .idle
        meterOK = nil
    }

    /// 更新要维持的状态并立刻下发
    func apply(pumpDuty: Int, volt: Int, fanDuty: Int, head: LEDSetting?, fan: LEDSetting?) {
        current.pumpDuty = max(0, min(100, pumpDuty))
        current.volt = clampVolt(volt)      // 绝不越过本机上限 11V
        current.fanDuty = max(0, min(100, fanDuty))
        current.head = head
        current.fan = fan
        self.pumpDuty = current.pumpDuty
        self.volt = volt
        self.fanDuty = current.fanDuty
        pushState(tag: "apply")
    }

    // MARK: 注水 / 排气

    func prime(completion: (() -> Void)? = nil) {
        guard connected else { log("未连接，无法注水。"); completion?(); return }
        guard !priming else { log("注水序列已在运行中。"); return }
        priming = true
        log("注水/排气序列开始（约 68 秒）")
        enqueue(primeStartFrame, "prime start")
        enqueue(fanFrame(on: true, duty: 50), "fan 50%")
        var cycle = 0
        func step() {
            guard cycle < 8 else {
                enqueue(primeStopFrame, "prime stop")
                priming = false
                log("注水/排气完成，恢复常规档位")
                pushState(tag: "post-prime restore")
                completion?()
                return
            }
            enqueue(pumpFrame(on: false, duty: 0, volt: 0), "prime pump off")
            after(0.5) {
                guard self.priming else { return }        // 中途断开/停止就退出序列
                self.log("  循环 \(cycle + 1)/8：泵 100% @ 8V，5.5s")
                self.enqueue(pumpFrame(on: true, duty: 100, volt: 8), "prime pump")
                self.after(5.5) {
                    guard self.priming else { return }
                    self.enqueue(pumpFrame(on: false, duty: 0, volt: 0), "prime pump off")
                    self.after(2.5) { guard self.priming else { return }; cycle += 1; step() }
                }
            }
        }
        after(1.0) { step() }
    }

    func sleepDevice() {
        guard connected else { return }
        enqueue(sleepFrame, "sleep")
    }

    /// 请求 0x30。文档称其为「发送遥测」（25 字节模板），但**实测在 LCT22002 v2.0.0.4 上
    /// 只是把固件版本串重发一遍**，拿不到温度/流量。保留入口供其它固件批次探测。
    func requestTelemetry() {
        guard connected else { log("未连接，无法请求 0x30。"); return }
        awaitingTelemetry = true
        enqueue(telemetryFrame, "0x30 request")
        after(3.0) {
            if self.awaitingTelemetry {
                self.awaitingTelemetry = false
                self.logDebug("（3 秒内没收到遥测回包）")
            }
        }
    }

    /// 把所有输出复位到固件默认值
    func resetAll() {
        guard connected else { log("未连接，无法复位。"); return }
        log("复位所有输出到默认值（0x1F）")
        enqueue(resetAllFrame, "reset all 0x1F")
        after(0.5) { self.pushState(tag: "reset-all restore") }
    }

    // MARK: 连接循环

    private func beginConnectCycle() {
        guard wantRun else { return }
        // 关键守卫：已经在连（或已连上）就别再走一遍。
        // 否则「蓝牙未就绪」那条 3 秒后的延迟调用会在连上之后再次进来，
        // 命中下面的「复用已有连接」分支 -> 二次 attach / 二次握手 / 重复下发状态。
        if let cur = peripheral, cur.state == .connected || cur.state == .connecting { return }

        guard central.state == .poweredOn else {
            // 只在状态刚变成「未就绪」时提示一次，否则蓝牙一直关着就会刷屏
            if !waitingForPower {
                waitingForPower = true
                let s = central.state.rawValue
                log(s == 0 ? "蓝牙初始化中…" : "蓝牙未就绪（state=\(s)），等待中…")
            }
            after(3.0) { self.beginConnectCycle() }
            return
        }
        waitingForPower = false
        // 系统层面已经连着就复用
        if let p = central.retrieveConnectedPeripherals(withServices: [nusService])
            .first(where: { $0.state == .connected }) {
            log("复用系统已有的连接。")
            attach(p)
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.peripheral == nil { self.retry() }
        }
    }

    private func retry() {
        guard wantRun else { return }
        central.stopScan()
        scanTimer?.invalidate(); connectPoll?.invalidate(); attachWatchdog?.invalidate()
        // 必须清空：didDiscover 有 `self.peripheral == nil` 的守卫，
        // 不清的话重扫后永远进不去连接流程（服务发现失败时会卡死在这里）。
        peripheral = nil
        writeChar = nil; notifyChar = nil
        priming = false
        fallbackMode = false
        discovered.removeAll()
        attempt += 1
        if attempt > maxAttempts {
            state = .failed
            lastError = "已重试 \(maxAttempts) 次仍未连上"
            log("连接失败：\(lastError!)。将每 20 秒重试一次。")
            attempt = 0
            after(20) { self.beginConnectCycle() }
            return
        }
        after(1.5) { self.beginConnectCycle() }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantRun && peripheral == nil { beginConnectCycle() }
        case .poweredOff:
            log("蓝牙已关闭。"); state = .idle
        case .unauthorized:
            log("没有蓝牙权限：系统设置 → 隐私与安全性 → 蓝牙")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wantRun, self.peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let l = name.lowercased()
        let byName = ["coolingsystem", "cooler", "lct", "mech", "revo", "water", "liquid"]
            .contains { l.contains($0) }
        // 也认广播里的 NUS 服务 UUID —— 改名过的设备也能命中
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard byName || advServices.contains(nusService) else { return }

        rssi = RSSI.intValue
        log("发现 \(name) rssi=\(RSSI.intValue)")
        central.stopScan()
        scanTimer?.invalidate()
        self.peripheral = peripheral
        state = .connecting
        connectStartedAt = Date()
        central.connect(peripheral, options: nil)
        startConnectPoll()
    }

    /// didConnect 在这台机器上可能永不回调，所以轮询 state 兜底
    private func startConnectPoll() {
        connectPoll?.invalidate()
        connectPoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard let p = self.peripheral else { t.invalidate(); return }
            if p.state == .connected {
                t.invalidate()
                self.log("state=connected（didConnect 未回调，轮询兜住）")
                self.attach(p)
                return
            }
            let waited = -self.connectStartedAt.timeIntervalSinceNow
            if p.state == .disconnected && waited > 2 {
                t.invalidate()
                self.peripheral = nil
                self.retry()
                return
            }
            if waited > 15 {
                t.invalidate()
                self.log("单次连接超时（15s），重试。")
                central.cancelPeripheralConnection(p)
                self.peripheral = nil
                self.retry()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectPoll?.invalidate()
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("连接失败：\(error?.localizedDescription ?? "未知")")
        self.peripheral = nil
        retry()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("连接断开：\(error?.localizedDescription ?? "对端断开")")
        onStatusChange?(.disconnected(reason: error?.localizedDescription ?? "对端断开"))
        keepAlive?.invalidate(); attachWatchdog?.invalidate()
        writeChar = nil; notifyChar = nil
        queue.removeAll(); writing = false
        priming = false
        fallbackMode = false
        discovered.removeAll()
        meterOK = nil
        guard wantRun else { state = .idle; return }
        state = .idle
        attempt = 0
        after(2.0) { self.beginConnectCycle() }
    }

    // MARK: 服务发现与握手

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        // 服务发现/握手看门狗：没有 NUS 的固件批次会在特征发现那一步直接 return，
        // 之后没有任何回调能把我们带回重试流程 —— 没有它就会永久卡在「连接中」。
        scheduleAttachWatchdog()
        p.discoverServices(nil)
    }

    private func scheduleAttachWatchdog() {
        attachWatchdog?.invalidate()
        attachWatchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.state != .connected {
                self.log("建链看门狗：20s 内没完成服务发现或握手，重连。")
                if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                self.peripheral = nil
                self.retry()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { log("发现服务失败：\(e.localizedDescription)") }
        guard let services = peripheral.services, !services.isEmpty else {
            log("没有发现任何服务"); retry(); return
        }
        if !services.contains(where: { $0.uuid == nusService }) {
            log("没有 NUS 服务，实际服务：\(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
            log("改为枚举全部特征并回退挑选「可写 + 可通知」组合。")
            fallbackMode = true
        }
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        // 非 NUS 固件：等所有服务的特征都发现完，再统一挑一对写/通知特征
        if fallbackMode {
            discovered[service.uuid] = service.characteristics ?? []
            if discovered.count >= (peripheral.services?.count ?? 0) { resolveFallback() }
            return
        }
        guard service.uuid == nusService else { return }
        let chars = service.characteristics ?? []
        writeChar = chars.first { $0.uuid == nusWrite }
        notifyChar = chars.first { $0.uuid == nusNotify }
        guard writeChar != nil else { log("NUS 里没有写特征"); retry(); return }
        log("NUS 就绪：写 \(nusWrite.uuidString)")
        if let n = notifyChar {
            peripheral.setNotifyValue(true, for: n)
            // 官方顺序：先在 RX 上开通知，再写 "sw"
            after(0.6) { self.doHandshake() }
        } else {
            log("（RX 特征不存在，收不到版本串，仍尝试握手）")
            doHandshake()
        }
    }

    /// 没有 NUS 时的兜底：优先挑同时具备 write 与 notify 的服务，否则任意可写特征
    private func resolveFallback() {
        var chosenWrite: CBCharacteristic?
        var chosenNotify: CBCharacteristic?
        outer: for (_, chars) in discovered {
            let w = chars.first { $0.properties.contains(.write)
                               || $0.properties.contains(.writeWithoutResponse) }
            let n = chars.first { $0.properties.contains(.notify)
                               || $0.properties.contains(.indicate) }
            if let w, let n { chosenWrite = w; chosenNotify = n; break outer }
        }
        if chosenWrite == nil {
            for (_, chars) in discovered {
                if let w = chars.first(where: { $0.properties.contains(.write)
                                             || $0.properties.contains(.writeWithoutResponse) }) {
                    chosenWrite = w
                    break
                }
            }
        }
        guard let w = chosenWrite else {
            log("这个设备没有任何可写特征，控制不了。"); retry(); return
        }
        writeChar = w
        notifyChar = chosenNotify
        log(">> 回退使用写特征 \(w.uuid.uuidString)")
        if let n = chosenNotify {
            peripheral?.setNotifyValue(true, for: n)
            after(0.6) { self.doHandshake() }
        } else {
            doHandshake()
        }
    }

    private func doHandshake() {
        state = .handshake
        log("握手：写 \"sw\" (73 77)")
        enqueue(handshakeBytes, "handshake 'sw'")
        // 4 秒内没收到版本串就重来
        after(4.0) {
            if self.state == .handshake {
                self.log("没收到固件版本串，重新连接…")
                if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error { log("订阅通知失败：\(e.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        if characteristic.uuid != notifyChar?.uuid { return }

        // 遥测回包优先分流：它不是 0xFE 帧，会被 parseResponse 当成固件版本串
        if awaitingTelemetry, data.first != 0xFE {
            awaitingTelemetry = false
            let ascii = String(data: data, encoding: .utf8)?
                .map { c -> Character in
                    guard let v = c.asciiValue, v >= 32, v < 127 else { return "." }
                    return c
                }
            lastTelemetry = hex(data)
            let text = String(data: data, encoding: .utf8) ?? ""
            logDebug("0x30 回包 \(data.count) 字节：\(hex(data))")
            if let fw = firmware, text.contains(fw) || fw.isEmpty == false && text == "MCU F/W Version: \(fw)" {
                // 实测：LCT22002 v2.0.0.4 的 0x30 只是把版本串重发一遍，
                // 与官方文档「和 sw 处理器走同一条代码路径」的说法吻合 —— 拿不到温度/流量。
                logDebug("  （此固件的 0x30 只是重复版本串，不含遥测数据）")
            } else if let a = ascii, !a.allSatisfy({ $0 == "." }) {
                logDebug("  可读部分：\(a)")
            }
            return
        }

        switch parseResponse(data) {
        case .firmwareVersion(let full, let short):
            firmware = short
            deviceName = peripheral.name
            // 版本串首位即世代：2.x = LCT22002(Mk2)，1.x = LCT21001(Mk1)
            isMk2 = short.first != "1"
            state = .connected
            attempt = 0
            lastError = nil
            attachWatchdog?.invalidate()
            log("连接已建立：\(peripheral.name ?? "?")，固件 \(short)（\(full)）"
                + "，机型 \(isMk2 ? "Mk2（支持风扇灯）" : "Mk1（无风扇灯）")")
            onStatusChange?(.connected(info: short))
            alert = nil
            if self.sendSystemEnable {
                enqueue(systemEnableFrame(true), "system enable 0x1A")
            }
            after(0.3) { self.pushState(tag: "restore") }
            startKeepAlive()
        case .meter(let st, _):
            let ok = st == 2
            if meterOK != ok {
                log("水表状态 \(st) = \(ok ? "流量正常" : "异常/告警")")
                onStatusChange?(ok ? .meterNormal : .meterAbnormal(state: Int(st)))
                alert = ok ? nil : "流量异常（水表状态 \(st)）。请检查水路，避免水泵干转。"
            }
            meterOK = ok
        case .partial:
            break
        case .unknown:
            log("未知回包 \(hex(data))")
        }
    }

    // MARK: 保活

    private func startKeepAlive() {
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushState(tag: "keepalive") }
        }
    }

    private func pushState(tag: String) {
        guard connected, let _ = writeChar else { return }
        guard !priming else { return }        // 注水序列自己控制泵，别插嘴
        enqueue(pumpFrame(on: true, duty: current.pumpDuty, volt: current.volt),
                "\(tag) pump \(current.pumpDuty)% @ \(voltLabel(voltCode(current.volt)))")
        enqueue(fanFrame(on: true, duty: current.fanDuty), "\(tag) fan \(current.fanDuty)%")
        if let h = current.head {
            enqueue(headLEDFrame(on: h.on, r: h.r, g: h.g, b: h.b, mode: h.mode), "\(tag) head led")
        }
        if let f = current.fan {
            enqueue(fanLEDFrame(on: f.on, r: f.r, g: f.g, b: f.b, mode: f.mode), "\(tag) fan led")
        }
    }

    // MARK: 写队列

    private func enqueue(_ data: Data, _ tag: String) {
        // 断线期间 pumpQueue 会直接 return，队列可能无限堆积 —— 设一个上限
        if queue.count > 40 { queue.removeFirst(queue.count - 40) }
        queue.append((data, tag))
        pumpQueue()
    }

    private func pumpQueue() {
        guard !writing, !queue.isEmpty else { return }
        guard let p = peripheral, p.state == .connected, let c = writeChar else { return }
        let item = queue.removeFirst()
        writing = true
        let canResponse = c.properties.contains(.write)
        let type: CBCharacteristicWriteType = canResponse ? .withResponse : .withoutResponse
        logDebug("  -> \(hex(item.data))  \(item.tag)")
        p.writeValue(item.data, for: c, type: type)

        if type == .withResponse {
            let wi = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.writing = false            // 超时就放弃这一帧，继续下一帧，绝不卡死
                self.pumpQueue()
            }
            writeTimer?.cancel()
            writeTimer = wi
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: wi)
        } else {
            writing = false
            after(0.06) { self.pumpQueue() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        writeTimer?.cancel()
        writing = false
        if let e = error { log("  写失败：\(e.localizedDescription)") }
        after(0.06) { self.pumpQueue() }
    }

    // MARK: 工具

    private func after(_ s: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) {
            Task { @MainActor in block() }
        }
    }

    private func log(_ s: String) { appendLog(s) }

    /// 调试级日志（逐帧字节、保活推送等），只有开了「详细日志」才会出现
    private func logDebug(_ s: String) { guard verbose else { return }; appendLog(s) }

    /// 供外部（AppModel）写入日志
    func appendLog(_ s: String) {
        DispatchQueue.main.async {
            self.logLines.append(s)
            if self.logLines.count > 200 { self.logLines.removeFirst(self.logLines.count - 200) }
        }
    }
}

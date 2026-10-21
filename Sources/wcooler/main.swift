// wcooler —— macOS 上的机械革命「水冷魔盒」控制器
//
// 协议来源：逆向 open-revo（Tauri/Rust）的 BLE 模块 + 其运行日志中的 BLE_TX 记录。
// 水冷魔盒是 BLE 外设，走 Nordic UART Service（NUS）透传：
//   service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
//   write   6E400002-B5A3-F393-E0A9-E50E24DCCA9E   (主机 -> 魔盒)
//   notify  6E400003-B5A3-F393-E0A9-E50E24DCCA9E   (魔盒 -> 主机)
//
// 帧格式： FE <cmd> <b1> <b2> <b3> <b4> <b5> EF
//   0x1C 水泵  b1=使能 b2=电压(V) b3=占空比(%)
//   0x1B 风扇  b1=使能 b2=占空比(%)
//   0x1E 灯效  b1=开关 b2..b4=RGB b5=模式
//   0x33 灯效  与 0x1E 同 payload（open-revo 成对发送）
//   0x32 查询  每 ~3s 一次查询/保活
// 握手不是 FE..EF 帧，而是 2 字节 0x73 0x77（ASCII "sw"）。

import Foundation
import CoreBluetooth
import AppKit
import Dispatch
import Darwin

// MARK: - 协议

let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let nusWrite = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
let nusNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

let handshake = Data([0x73, 0x77])

func frame(_ cmd: UInt8, _ payload: [UInt8]) -> Data {
    var body = Array(payload.prefix(5))
    while body.count < 5 { body.append(0) }
    return Data([0xFE, cmd] + body + [0xEF])
}

func pumpFrame(_ on: Bool, volt: Int, duty: Int) -> Data {
    frame(0x1C, [on ? 1 : 0,
                 UInt8(clamping: on ? volt : 0),
                 UInt8(clamping: on ? duty : 0), 0, 0])
}

func fanFrame(_ on: Bool, duty: Int) -> Data {
    frame(0x1B, [on ? 1 : 0, UInt8(clamping: on ? duty : 0), 0, 0, 0])
}

func ledFrames(on: Bool, r: Int, g: Int, b: Int, mode: Int) -> [Data] {
    let p: [UInt8] = [on ? 1 : 0,
                      UInt8(clamping: on ? r : 0),
                      UInt8(clamping: on ? g : 0),
                      UInt8(clamping: on ? b : 0),
                      UInt8(clamping: on ? mode : 0)]
    return [frame(0x1E, p), frame(0x33, p)]
}

let queryFrame = frame(0x32, [])

func hex(_ d: Data) -> String {
    d.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

// MARK: - 参数

struct Options {
    var command = "run"
    var pump = 7
    var duty = 45
    var fan = 55
    var led: (Int, Int, Int, Int) = (0, 128, 0, 2)
    var ledOn = true
    var name: String?
    var address: String?
    var timeout: Double = 8.0
}

func usage() -> Never {
    log("""
    用法:
      wcooler scan [--timeout 8]
      wcooler run  [--pump 7] [--duty 45] [--fan 55] [--led 0,128,0,2] [--no-led]
                   [--name 子串] [--address UUID] [--timeout 8]
      wcooler off  [--name 子串] [--address UUID]

    先扫一遍看设备名：  wcooler scan
    典型标准档：        wcooler run --pump 7 --duty 45 --fan 55
    """)
    exit(2)
}

func parseArgs() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var o = Options()
    guard let cmd = args.first else { usage() }
    guard ["scan", "run", "off"].contains(cmd) else { usage() }
    o.command = cmd
    args.removeFirst()

    func next() -> String { args.isEmpty ? "" : args.removeFirst() }

    while let a = args.first {
        args.removeFirst()
        switch a {
        case "--pump": o.pump = Int(next()) ?? o.pump
        case "--duty": o.duty = Int(next()) ?? o.duty
        case "--fan": o.fan = Int(next()) ?? o.fan
        case "--no-led": o.ledOn = false
        case "--led":
            let parts = next().split(separator: ",").compactMap { Int($0) }
            if parts.count == 4 { o.led = (parts[0], parts[1], parts[2], parts[3]) }
        case "--name": o.name = next()
        case "--address": o.address = next()
        case "--timeout": o.timeout = Double(next()) ?? o.timeout
        case "-h", "--help": usage()
        default:
            log("未知参数: \(a)")
            usage()
        }
    }
    return o
}

// MARK: - 主逻辑

final class WCooler: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let opts: Options
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var queue: [(CBCharacteristic, Data, String)] = []
    private var writing = false
    private var keepAlive: Timer?
    private var found: [(CBPeripheral, Int)] = []
    private var sessionStarted = false
    private var shuttingDown = false

    init(_ opts: Options) {
        self.opts = opts
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: 扫描/连接

    private func matches(_ p: CBPeripheral, _ adv: [String: Any]) -> Bool {
        if let addr = opts.address, !addr.isEmpty {
            return p.identifier.uuidString.lowercased() == addr.lowercased()
        }
        if let want = opts.name, !want.isEmpty {
            let n = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
            return n.lowercased().contains(want.lowercased())
        }
        let n = ((adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "").lowercased()
        return n.contains("cooler") || n.contains("mech") || n.contains("water") || n.contains("水冷")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("蓝牙就绪，开始扫描…")
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            if opts.command == "scan" {
                DispatchQueue.main.asyncAfter(deadline: .now() + opts.timeout) {
                    self.finishScan()
                }
            } else {
                // run/off 也设一个扫描上限，避免永远挂着
                DispatchQueue.main.asyncAfter(deadline: .now() + opts.timeout * 2) {
                    if self.peripheral == nil {
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

        if opts.command == "scan" {
            if !found.contains(where: { $0.0.identifier == peripheral.identifier }) {
                found.append((peripheral, RSSI.intValue))
                let hasNUS = services.contains(nusService)
                log("\(peripheral.identifier.uuidString)  rssi=\(RSSI)  name=\(name)\(hasNUS ? "  [NUS]" : "")")
            }
            return
        }

        guard !sessionStarted else { return }
        guard matches(peripheral, advertisementData) || services.contains(nusService) else { return }

        log("发现目标: \(name) (\(peripheral.identifier.uuidString)) rssi=\(RSSI)")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    private func finishScan() {
        central.stopScan()
        if found.isEmpty {
            log("没扫到设备。确认水冷魔盒已通电、没被别的设备（比如 Windows 侧 open-revo）占着连接。")
        } else {
            log("提示：用 --name 或 --address 指定目标，然后运行 wcooler run。")
        }
        exit(0)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("已连接，发现服务…")
        peripheral.discoverServices([nusService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败: \(error?.localizedDescription ?? "未知错误")")
        exit(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        keepAlive?.invalidate()
        if shuttingDown { exit(0) }
        log("连接断开: \(error?.localizedDescription ?? "对端主动断开")")
        exit(1)
    }

    // MARK: 服务/特征

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("发现服务失败: \(error.localizedDescription)")
            exit(1)
        }
        guard let services = peripheral.services, !services.isEmpty else {
            log("没有发现任何服务。")
            exit(1)
        }
        for s in services where s.uuid == nusService {
            peripheral.discoverCharacteristics([nusWrite, nusNotify], for: s)
        }
        if peripheral.services?.contains(where: { $0.uuid == nusService }) != true {
            log("没有 NUS 服务（\(nusService)），这个设备可能不是水冷魔盒。")
            exit(1)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            log("发现特征失败: \(error.localizedDescription)")
            exit(1)
        }
        for c in service.characteristics ?? [] {
            if c.uuid == nusWrite { writeCharacteristic = c }
            if c.uuid == nusNotify { peripheral.setNotifyValue(true, for: c) }
        }
        guard writeCharacteristic != nil else {
            log("没找到写特征（6E400002…）。")
            exit(1)
        }
        if !sessionStarted {
            if service.characteristics?.contains(where: { $0.uuid == nusNotify }) == true {
                // 等 didUpdateNotificationStateFor 再开始会话
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if !self.sessionStarted { self.beginSession() }
                }
            } else {
                beginSession()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("订阅通知失败: \(error.localizedDescription)")
        }
        if !sessionStarted { beginSession() }
    }

    // MARK: 会话

    private func beginSession() {
        guard !sessionStarted, let wc = writeCharacteristic else { return }
        sessionStarted = true
        log("握手 + 推初始状态…")

        enqueue(wc, handshake, "handshake")
        enqueue(wc, pumpFrame(false, volt: 0, duty: 0), "pump init")
        enqueue(wc, fanFrame(true, duty: opts.fan), "fan \(opts.fan)%")
        enqueue(wc, pumpFrame(true, volt: opts.pump, duty: opts.duty), "pump \(opts.pump)V/\(opts.duty)%")
        if opts.ledOn {
            let (r, g, b, m) = opts.led
            for f in ledFrames(on: true, r: r, g: g, b: b, mode: m) {
                enqueue(wc, f, "led rgb(\(r),\(g),\(b)) mode=\(m)")
            }
        } else {
            for f in ledFrames(on: false, r: 0, g: 0, b: 0, mode: 0) { enqueue(wc, f, "led off") }
        }
        enqueue(wc, queryFrame, "query")

        keepAlive = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, let wc = self.writeCharacteristic else { return }
            self.enqueue(wc, queryFrame, "query")
        }

        // 睡眠前收尾，唤醒后重连
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            log("系统即将睡眠：停泵…")
            self?.sendStopFrames()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.peripheral?.state != .connected {
                log("唤醒后重连…")
                self.sessionStarted = false
                self.central.scanForPeripherals(withServices: nil, options: nil)
            }
        }

        log("运行中，Ctrl+C 退出（会先停泵再断开）。")
    }

    private func sendStopFrames() {
        guard let wc = writeCharacteristic else { return }
        enqueue(wc, pumpFrame(false, volt: 0, duty: 0), "shutdown pump")
        enqueue(wc, fanFrame(false, duty: 0), "shutdown fan")
        for f in ledFrames(on: false, r: 0, g: 0, b: 0, mode: 0) { enqueue(wc, f, "shutdown led") }
    }

    func requestShutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        keepAlive?.invalidate()
        log("退出：发送停止帧…")
        sendStopFrames()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
        }
    }

    // MARK: 写队列

    private func enqueue(_ c: CBCharacteristic, _ data: Data, _ tag: String) {
        queue.append((c, data, tag))
        pumpQueue()
    }

    private func pumpQueue() {
        guard !writing, let next = queue.first, let p = peripheral, p.state == .connected else { return }
        queue.removeFirst()
        writing = true
        log("  -> \(hex(next.1))  \(next.2)")
        p.writeValue(next.1, for: next.0, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        writing = false
        if let error = error { log("  写失败: \(error.localizedDescription)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.pumpQueue() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let data = characteristic.value {
            log("  <- \(hex(data))")
        }
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

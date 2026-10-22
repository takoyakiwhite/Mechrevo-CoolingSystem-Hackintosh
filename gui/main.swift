import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: AppModel!
    private var iconTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 只驻留菜单栏，不显示 Dock 图标

        model = AppModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(togglePopover(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(model))

        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateIcon(); self?.syncPopoverSize()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let m = self.model
            DispatchQueue.main.async { m?.engine.stop(graceful: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let m = self.model
            DispatchQueue.main.async {
                m?.engine.start()
                m?.pushCurrent()
            }
        }

        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.engine.stop(graceful: true)
    }

    /// 面板开着时内容高度还会变（展开设置/日志），高度要跟着走，且始终不越界
    private func syncPopoverSize() {
        guard popover.isShown, let b = statusItem.button else { return }
        let screen = b.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 900) - 80
        let want = model.contentHeight > 0 ? model.contentHeight + 8 : 520
        let h = min(max(240, available), max(240, want))
        if abs(popover.contentSize.height - h) > 1 {
            popover.contentSize = NSSize(width: 340, height: h)
        }
    }

    private func updateIcon() {
        guard let b = statusItem.button else { return }
        let e = model.engine
        let name: String
        var color: NSColor = .secondaryLabelColor
        // 有告警时优先显示 ⚠️ —— 不依赖系统通知，图标本身就能看到问题
        if e.alert != nil {
            b.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                              accessibilityDescription: "水冷告警")
            b.contentTintColor = .systemRed
            b.title = " ⚠️"
            return
        }
        switch e.state {
        case .connected:
            name = "drop.fill"
            color = (e.meterOK ?? true) ? .systemGreen : .systemOrange
        case .failed:
            name = "exclamationmark.triangle.fill"; color = .systemRed
        case .scanning, .connecting, .handshake:
            name = "drop"; color = .systemOrange
        case .idle:
            name = "drop"; color = .secondaryLabelColor
        }
        b.image = NSImage(systemSymbolName: name, accessibilityDescription: "水冷魔盒")
        b.contentTintColor = color
        // 菜单栏寸土寸金：显示控制温度比显示泵占空比更有信息量（后者在面板里能看到）
        b.title = (e.state == .connected && model.smart.inputIsTemp)
            ? String(format: " %.0f°", model.smart.inputValue) : ""
    }

    /// 右键快捷菜单：不展开面板也能切预设 / 注水 / 复位
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        let presets = NSMenuItem(title: "预设", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in Preset.allCases where p != .custom {
            let item = NSMenuItem(title: p.label, action: #selector(choosePreset(_:)),
                                  keyEquivalent: "")
            item.representedObject = p.rawValue
            item.target = self
            sub.addItem(item)
        }
        presets.submenu = sub
        m.addItem(presets)
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "注水/排气", action: #selector(doPrime(_:)), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "0x30 探测", action: #selector(doTelemetry(_:)), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "复位所有输出", action: #selector(doReset(_:)), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "重连", action: #selector(doReconnect(_:)), keyEquivalent: ""))
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "退出", action: #selector(doQuit(_:)), keyEquivalent: "q"))
        for i in m.items where i.target == nil { i.target = self }
        return m
    }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = Preset(rawValue: raw) else { return }
        model.settings.applyPreset(p)
        model.pushCurrent()
    }
    @objc private func doPrime(_: Any?) { model.engine.prime() }
    @objc private func doTelemetry(_: Any?) { model.engine.requestTelemetry() }
    @objc private func doReset(_: Any?) { model.engine.resetAll() }
    @objc private func doReconnect(_: Any?) { model.reconnect() }
    @objc private func doQuit(_: Any?) { model.quit() }

    @objc private func togglePopover(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        // 右键 -> 快捷菜单；左键 -> 控制面板
        if let ev = NSApp.currentEvent, ev.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            b.performClick(nil)
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.menu = nil      // 用完就摘掉，否则左键也会弹菜单
            }
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            // 按内容自适应，但**必须按屏幕可用高度封顶** —— 否则展开设置/日志后
            // 面板会顶出屏幕外。内容本身是 ScrollView，超了就内部滚动。
            syncPopoverSize()      // 高度取「内容实测」与「屏幕可用」的较小值，绝不越界
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

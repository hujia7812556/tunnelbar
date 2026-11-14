import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var isTerminating = false

    /// 同一应用只运行一份，随后创建原生窗口和菜单栏入口。
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        installApplicationMenu()
        let model = AppModel()
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "TunnelBar"
        window.minSize = NSSize(width: 860, height: 560)
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TunnelBarMainWindow")
        window.center()
        self.window = window
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "TunnelBar")
        statusItem?.button?.toolTip = "TunnelBar"
        if statusItem?.button?.image == nil { statusItem?.button?.title = "TB" }
        rebuildStatusMenu()
        subscription = model.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildStatusMenu() }
        showWindow(nil)
    }

    /// 保留标准编辑快捷键，使原生表单可正常复制粘贴。
    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 TunnelBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TunnelBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// 菜单显示主机状态，当前连接或重连中的主机点击后执行主动断开。
    private func rebuildStatusMenu() {
        guard let model = model else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 TunnelBar", action: #selector(showWindow(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        for profile in model.profiles {
            let state = model.state(for: profile.id)
            let item = NSMenuItem(title: "\(profile.name) · \(state.phase.title)", action: #selector(toggleHost(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id.uuidString
            item.state = state.phase == .connected ? .on : .off
            menu.addItem(item)
        }
        if model.profiles.isEmpty {
            let empty = NSMenuItem(title: "尚未添加主机", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TunnelBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    /// 从菜单栏或 Dock 重新展示现有窗口，不重复创建连接管理器。
    @objc private func showWindow(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单操作仅传递主机标识，由后台处理连接状态变化。
    @objc private func toggleHost(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value), let model = model else { return }
        if model.state(for: id).phase.isActive { model.disconnect(id) } else { model.connect(id) }
    }

    /// 关闭主窗口只隐藏，保持菜单栏和端口转发运行。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Dock 或 Finder 再次打开时恢复主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    /// 从系统设置切回时刷新通知权限。
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.becameActive()
    }

    /// 先异步关闭自有 SSH 连接，再允许应用退出；退出过程不逐主机发通知。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = model else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        model.shutdown {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

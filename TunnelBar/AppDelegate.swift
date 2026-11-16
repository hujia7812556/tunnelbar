import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let tunnelBarAddHost = Notification.Name("TunnelBar.addHost")
    static let tunnelBarToggleSidebar = Notification.Name("TunnelBar.toggleSidebar")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
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
        window.minSize = NSSize(width: 900, height: 560)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "TunnelBarToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        let hostingView = NSHostingView(rootView: ContentView(model: model))
        // 窗口决定可用尺寸，避免表格的理想高度反向撑大托管视图。
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TunnelBarMainWindow")
        window.center()
        self.window = window
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "TunnelBar")?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        statusItem?.button?.image?.isTemplate = true
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
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "文件")
        let add = NSMenuItem(title: "新建主机…", action: #selector(addHost(_:)), keyEquivalent: "n")
        add.target = self
        file.addItem(add)
        fileItem.submenu = file
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "显示")
        let sidebar = NSMenuItem(title: "显示／隐藏侧栏", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        sidebar.target = self
        view.addItem(sidebar)
        viewItem.submenu = view
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }

    /// 标题栏只保留全局导航和添加主机，主机操作留在详情区域。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("toggleHostSidebar"), .flexibleSpace, NSToolbarItem.Identifier("addHost")]
    }

    /// 原生工具栏沿用默认项目，不引入额外配置。
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// 用系统符号创建工具栏项目，使系统处理悬停和深浅色外观。
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        if itemIdentifier.rawValue == "toggleHostSidebar" {
            item.label = "显示／隐藏侧栏"
            item.toolTip = "显示／隐藏侧栏（⌃⌘S）"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
            item.action = #selector(toggleSidebar(_:))
        } else {
            item.label = "添加主机"
            item.toolTip = "添加主机（⌘N）"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: item.label)
            item.action = #selector(addHost(_:))
        }
        return item
    }

    /// 配置读取失败时同步禁用工具栏中的写操作。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier.rawValue != "addHost" || model?.configurationIssue == nil
    }

    /// 交给主窗口弹出已有的主机编辑表单。
    @objc private func addHost(_ sender: Any?) {
        showWindow(nil)
        NotificationCenter.default.post(name: .tunnelBarAddHost, object: nil)
    }

    /// 切换侧栏只影响显示，不修改任何连接配置。
    @objc private func toggleSidebar(_ sender: Any?) {
        NotificationCenter.default.post(name: .tunnelBarToggleSidebar, object: nil)
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
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单操作仅传递主机标识，由后台处理连接状态变化。
    @objc private func toggleHost(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value), let model = model else { return }
        if model.state(for: id).phase.isActive { model.disconnect(id) } else { model.connect(id) }
    }

    /// 关闭主窗口时隐藏 Dock 图标，保持菜单栏和端口转发运行。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
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

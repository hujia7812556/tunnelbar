import AppKit

// AppKit 持有应用生命周期，SwiftUI 只负责窗口内容。
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
application.run()

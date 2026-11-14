import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onPermissionChange: ((Bool) -> Void)?

    /// 前台运行时也允许用户选择接收系统横幅通知。
    override init() {
        super.init()
        center.delegate = self
    }

    /// 读取当前权限，不在应用启动时自动弹出授权请求。
    func refreshPermission() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.onPermissionChange?(settings.authorizationStatus == .denied) }
        }
    }

    /// 仅在用户开启主机通知开关时申请一次；拒绝后由系统设置调整。
    func requestPermission() {
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            if settings.authorizationStatus == .notDetermined {
                self.center.requestAuthorization(options: [.alert]) { _, _ in self.refreshPermission() }
            } else {
                self.refreshPermission()
            }
        }
    }

    /// 通知只使用主机显示名称与经过归纳的状态，不附带 SSH 原始输出。
    func post(name: String, event: ConnectionEvent) {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = name
            content.body = event.text
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            self?.center.add(request, withCompletionHandler: nil)
        }
    }

    /// 使用系统通知中心呈现前台状态变化，不另建应用内通知队列。
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

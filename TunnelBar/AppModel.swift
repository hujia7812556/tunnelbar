import AppKit
import Combine

final class AppModel: ObservableObject {
    @Published var profiles: [TunnelProfile] = []
    @Published var states: [UUID: HostRuntimeState] = [:]
    @Published var errorMessage: String?
    @Published var configurationIssue: String?
    @Published var notificationPermissionDenied = false
    @Published var logs: [UUID: [ConnectionLogEntry]] = [:]
    @Published var logStorageIssue: String?

    private let store = ConfigStore()
    private let logStore = ConnectionLogStore()
    private var logsWritable = true
    private let manager = TunnelManager()
    private let notifications = NotificationService()

    /// 加载配置后按每个主机的偏好连接；所有可观察状态都在主线程更新。
    init() {
        do {
            logs = try logStore.load()
        } catch {
            logsWritable = false
            logStorageIssue = "历史日志读取失败，原文件已保留。当前仅记录本次运行日志。"
        }
        manager.onLog = { [weak self] id, entry in
            DispatchQueue.main.async {
                guard let self = self, self.profiles.contains(where: { $0.id == id }) else { return }
                var entries = self.logs[id] ?? []
                entries.append(entry)
                self.logs[id] = Array(entries.suffix(ConnectionLogStore.entriesPerHost))
                self.saveLogs()
            }
        }
        manager.onStateChange = { [weak self] id, state in
            DispatchQueue.main.async {
                guard let self = self, self.profiles.contains(where: { $0.id == id }) else { return }
                self.states[id] = state
            }
        }
        manager.onEvent = { [weak self] id, event in
            DispatchQueue.main.async {
                guard let self = self, let profile = self.profiles.first(where: { $0.id == id }), profile.notifyOnChange else { return }
                self.notifications.post(name: profile.name, event: event)
            }
        }
        notifications.onPermissionChange = { [weak self] denied in self?.notificationPermissionDenied = denied }
        notifications.refreshPermission()
        do {
            profiles = try store.load()
            manager.configure(profiles)
            for profile in profiles where profile.autoConnect { manager.connect(profile.id) }
        } catch {
            configurationIssue = "配置读取失败，原文件已保留。请在 Finder 中检查 hosts.json，修复后重新启动。"
        }
    }

    /// 保存成功后才更新内存和实际连接，失败时保留表单及原配置。
    func saveProfile(_ profile: TunnelProfile) {
        guard configurationIssue == nil else {
            errorMessage = "请先处理配置读取错误，避免覆盖原文件。"
            return
        }
        do {
            try profile.validate()
            let previous = profiles.first(where: { $0.id == profile.id })
            var updated = profiles
            if let index = updated.firstIndex(where: { $0.id == profile.id }) {
                updated[index] = profile
            } else {
                updated.append(profile)
            }
            try store.save(updated)
            profiles = updated
            manager.configure(updated)
            if profile.notifyOnChange && previous?.notifyOnChange != true { notifications.requestPermission() }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 删除主机后让连接管理器停止该主机，不影响其他配置。
    func deleteProfile(_ id: UUID) {
        guard configurationIssue == nil else { return }
        do {
            let updated = profiles.filter { $0.id != id }
            try store.save(updated)
            profiles = updated
            states.removeValue(forKey: id)
            logs.removeValue(forKey: id)
            saveLogs()
            manager.configure(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 返回主机当前状态，未启动过的主机保持未连接。
    func state(for id: UUID) -> HostRuntimeState {
        states[id] ?? HostRuntimeState()
    }

    /// 未启用规则不等待连接；实际错误和监听状态优先使用后台快照。
    func ruleState(profileID: UUID, rule: ForwardRule) -> ForwardRuntimeState {
        states[profileID]?.forwards[rule.id] ?? ForwardRuntimeState(phase: rule.isEnabled ? .waiting : .disabled)
    }

    /// 请求连接，由后台串行处理重复点击与正在进行的连接。
    func connect(_ id: UUID) { manager.connect(id) }

    /// 主动断开并停止该主机本次运行中的重试。
    func disconnect(_ id: UUID) { manager.disconnect(id) }

    /// 明确重建主连接，使变更的认证及主机参数生效。
    func reconnect(_ id: UUID) { manager.reconnect(id) }

    /// 只重试转发配置，保留已有 SSH 主连接。
    func retryForwards(_ id: UUID) { manager.retryForwards(id) }

    /// 打开系统通知设置，不反复请求已拒绝的权限。
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 配置读取失败时定位原文件，避免提供可能覆盖数据的一键重置。
    func revealConfiguration() {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    /// 返回应用前刷新通知权限，使系统设置中的变更反映到界面。
    func becameActive() { notifications.refreshPermission() }

    /// 日志故障只显示在详情窗口，不中断正常连接或覆盖损坏的历史文件。
    private func saveLogs() {
        guard logsWritable else { return }
        logStore.save(logs) { [weak self] error in
            DispatchQueue.main.async {
                self?.logStorageIssue = error == nil ? nil : "日志暂未保存到磁盘，本次记录仍可查看和复制。"
            }
        }
    }

    /// 应用退出等待连接停止，避免仅关闭窗口就遗留主进程。
    func shutdown(completion: @escaping () -> Void) {
        manager.shutdown {
            // onLog 已先排入主队列；随后 flush 能覆盖退出时产生的最后一批记录。
            DispatchQueue.main.async { self.logStore.flush(completion: completion) }
        }
    }
}

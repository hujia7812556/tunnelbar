import Foundation

enum ConnectionEvent {
    case connected, disconnected, lost, restored, failed(String)

    var text: String {
        switch self {
        case .connected: return "SSH 已连接。"
        case .disconnected: return "SSH 已断开。"
        case .lost: return "连接意外中断，正在尝试恢复。"
        case .restored: return "SSH 连接已恢复。业务客户端可能需要重新连接。"
        case .failed(let reason): return reason
        }
    }
}

private final class ManagedConnection {
    let ssh: SSHSession
    var ready = false
    var activeRules: [UUID: ForwardRule] = [:]
    var ruleErrors: [UUID: String] = [:]
    var warning: String?

    /// 实际生效规则与用户保存配置分开记录，失败时不冒充已应用。
    init(ssh: SSHSession) {
        self.ssh = ssh
    }
}

final class TunnelManager {
    // 所有生命周期及控制命令在同一队列串行执行，UI 只接收快照。
    private let queue = DispatchQueue(label: "com.local.TunnelBar.connections", qos: .utility)
    private let transport: SSHTransport
    private var profiles: [UUID: TunnelProfile] = [:]
    private var connections: [UUID: ManagedConnection] = [:]
    private var desired = Set<UUID>()
    private var recovering = Set<UUID>()
    private var failureAnnounced = Set<UUID>()
    private var retryTokens: [UUID: UUID] = [:]
    private var retryCounts: [UUID: Int] = [:]
    private var shuttingDown = false

    var onStateChange: ((UUID, HostRuntimeState) -> Void)?
    var onEvent: ((UUID, ConnectionEvent) -> Void)?
    var onLog: ((UUID, ConnectionLogEntry) -> Void)?

    /// 默认管理系统 OpenSSH，验证时仅替换 SSH 配置文件。
    init(transport: SSHTransport = SSHTransport()) {
        self.transport = transport
    }

    /// 更新保存配置；偏好更改不重连，端口更改只调整当前主连接内的规则。
    func configure(_ updated: [TunnelProfile]) {
        queue.async {
            guard !self.shuttingDown else { return }
            let previous = self.profiles
            let incoming = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
            for removed in previous.keys where incoming[removed] == nil {
                self.stop(removed, announce: false)
            }
            self.profiles = incoming
            for profile in updated {
                if let old = previous[profile.id] {
                    self.recordConfigurationChanges(from: old, to: profile)
                }
                guard let connection = self.connections[profile.id] else { continue }
                if connection.ready {
                    let oldRules = previous[profile.id]?.forwards ?? []
                    // 只改备注时保留监听和失败结果，不顺带重试其他端口。
                    let rulesChanged = oldRules.count != profile.forwards.count ||
                        zip(oldRules, profile.forwards).contains { old, new in
                            old.id != new.id || old.isEnabled != new.isEnabled || !old.hasSameEndpoint(as: new)
                        }
                    if connection.ssh.connection == profile.connection && rulesChanged {
                        self.applyRules(profile, connection: connection)
                    }
                    self.publish(profile.id, phase: .connected)
                }
            }
        }
    }

    /// 用户连接后记录期望状态，使瞬时网络中断能够自动恢复。
    func connect(_ id: UUID) {
        queue.async {
            guard !self.shuttingDown, self.profiles[id] != nil, self.connections[id] == nil else { return }
            self.desired.insert(id)
            self.retryTokens.removeValue(forKey: id)
            self.retryCounts.removeValue(forKey: id)
            self.failureAnnounced.remove(id)
            self.recovering.remove(id)
            self.start(id)
        }
    }

    /// 主动断开撤销本次运行中的重连意图，不改变持久化的启动偏好。
    func disconnect(_ id: UUID) {
        queue.async { self.stop(id, announce: true) }
    }

    /// 用户明确重连时才重新应用主机地址、用户或认证等连接参数。
    func reconnect(_ id: UUID) {
        queue.async {
            guard !self.shuttingDown, self.profiles[id] != nil else { return }
            self.record(id, "用户请求重新连接。")
            self.stop(id, announce: false)
            self.desired.insert(id)
            self.start(id)
        }
    }

    /// 重试当前主连接内失败的规则，不重启 SSH。
    func retryForwards(_ id: UUID) {
        queue.async {
            guard let profile = self.profiles[id], let connection = self.connections[id],
                  connection.ready, connection.ssh.connection == profile.connection else { return }
            self.record(id, "用户请求重新应用端口规则。")
            self.applyRules(profile, connection: connection)
            self.publish(id, phase: .connected)
        }
    }

    /// 退出时等待自有连接清理完成；回调由调用者切回主线程。
    func shutdown(completion: @escaping () -> Void) {
        queue.async {
            self.shuttingDown = true
            let activeIDs = self.desired
            self.desired.removeAll()
            self.retryTokens.removeAll()
            let owned = Array(self.connections.values)
            self.connections.removeAll()
            for connection in owned { self.transport.stop(connection.ssh) }
            for id in activeIDs { self.record(id, "应用退出，已关闭连接并停止自动重试。") }
            self.transport.cleanup()
            completion()
        }
    }

    /// 启动一代独立的主连接，旧会话退出回调不能操作新会话。
    private func start(_ id: UUID) {
        guard desired.contains(id), !shuttingDown, connections[id] == nil, let profile = profiles[id] else { return }
        record(id, "正在连接 \(profile.connection.hostname)。")
        publish(id, phase: retryCounts[id] == nil ? .connecting : .reconnecting)
        do {
            let session = try transport.start(profile.connection) { [weak self] session, status, diagnostic in
                self?.queue.async { self?.didExit(id, session: session, status: status, diagnostic: diagnostic) }
            }
            connections[id] = ManagedConnection(ssh: session)
            probe(id, session: session, deadline: Date().addingTimeInterval(30))
        } catch {
            desired.remove(id)
            let message = error.localizedDescription
            record(id, message, level: .error)
            publish(id, phase: .failed, message: message)
            announceFailure(id, message: message)
        }
    }

    /// 私有控制通道响应后才认为认证完成；进程启动不代表已连接。
    private func probe(_ id: UUID, session: SSHSession, deadline: Date) {
        queue.asyncAfter(deadline: .now() + 0.25) {
            guard self.desired.contains(id), let connection = self.connections[id],
                  connection.ssh.id == session.id, !self.shuttingDown else { return }
            guard session.process.isRunning else { return } // 由对应退出回调记录原因。
            if self.transport.control("check", session: session).succeeded {
                connection.ready = true
                self.retryCounts.removeValue(forKey: id)
                self.failureAnnounced.remove(id)
                let wasRecovering = self.recovering.remove(id) != nil
                self.record(id, wasRecovering ? "SSH 连接已恢复。" : "SSH 连接已建立。", level: .success)
                if let profile = self.profiles[id], profile.connection == session.connection {
                    self.applyRules(profile, connection: connection)
                }
                self.publish(id, phase: .connected)
                self.onEvent?(id, wasRecovering ? .restored : .connected)
            } else if Date() >= deadline {
                self.connections.removeValue(forKey: id)
                self.transport.stop(session)
                self.failed(id, failure: SSHFailure(message: "SSH 连接未在预期时间内就绪。", shouldRetry: true))
            } else {
                self.probe(id, session: session, deadline: deadline)
            }
        }
    }

    /// 分别撤销和添加变更的规则；修改失败时尝试恢复该条原规则。
    private func applyRules(_ profile: TunnelProfile, connection: ManagedConnection) {
        let wanted = Dictionary(uniqueKeysWithValues: profile.forwards.filter { $0.isEnabled }.map { ($0.id, $0) })
        var previousRules: [UUID: ForwardRule] = [:]
        connection.ruleErrors.removeAll()
        connection.warning = nil
        for (id, active) in Array(connection.activeRules) {
            if let rule = wanted[id], active.hasSameEndpoint(as: rule) { continue }
            let cancelled = transport.control("cancel", session: connection.ssh, rule: active)
            if cancelled.succeeded {
                connection.activeRules.removeValue(forKey: id)
                record(profile.id, "已停止监听：\(describe(active))。")
                if wanted[id] != nil { previousRules[id] = active }
            } else {
                connection.ruleErrors[id] = "原转发未能停止，可能仍在接收连接；请重试应用规则。"
                connection.warning = "部分原转发未能撤销。可重试应用规则，或主动断开该主机。"
                record(profile.id, "停止监听失败：\(describe(active))；原监听可能仍然存在。", level: .error)
            }
        }
        for rule in profile.forwards where rule.isEnabled {
            if let active = connection.activeRules[rule.id] {
                if !active.hasSameEndpoint(as: rule) {
                    connection.ruleErrors[rule.id] = "修改未应用，原转发仍在监听。"
                }
                continue
            }
            let added = transport.control("forward", session: connection.ssh, rule: rule)
            if added.succeeded {
                connection.activeRules[rule.id] = rule
                record(profile.id, "转发已监听：\(describe(rule))。", level: .success)
                continue
            }
            var message = "无法建立本地监听，请检查地址、端口占用和 SSH 连接状态。"
            if let previous = previousRules[rule.id] {
                let restored = transport.control("forward", session: connection.ssh, rule: previous)
                if restored.succeeded {
                    connection.activeRules[rule.id] = previous
                    message = "修改失败，已恢复原转发；当前保存的新配置尚未生效。"
                } else {
                    message = "修改失败且未能恢复原转发，请检查端口后重试。"
                }
            }
            connection.ruleErrors[rule.id] = message
            record(profile.id, "\(describe(rule))：\(message)", level: .error)
        }
    }

    /// 仅处理当前会话的退出，旧会话退出不会移除新连接记录。
    private func didExit(_ id: UUID, session: SSHSession, status: Int32, diagnostic: String) {
        transport.removeSocket(session)
        guard let connection = connections[id], connection.ssh.id == session.id else { return }
        connections.removeValue(forKey: id)
        guard desired.contains(id), !shuttingDown else {
            publish(id, phase: .disconnected)
            return
        }
        if connection.ready {
            recovering.insert(id)
            onEvent?(id, .lost)
            // 已认证连接的旧诊断可能包含某把候选密钥的警告，不能据此停止断线重连。
            failed(id, failure: SSHFailure(message: "SSH 连接意外结束（退出码 \(status)），将重新建立连接。", shouldRetry: true))
        } else {
            failed(id, failure: SSHFailure.describe(diagnostic, status: status))
        }
    }

    /// 只对可恢复错误重试，采用有上限的等待间隔，并合并重复失败通知。
    private func failed(_ id: UUID, failure: SSHFailure) {
        if !recovering.contains(id) { announceFailure(id, message: failure.message) }
        guard failure.shouldRetry, desired.contains(id), !shuttingDown else {
            desired.remove(id)
            if recovering.contains(id) { announceFailure(id, message: failure.message) }
            record(id, failure.message, level: .error)
            publish(id, phase: .failed, message: failure.message)
            return
        }
        let attempt = (retryCounts[id] ?? 0) + 1
        retryCounts[id] = attempt
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
        let token = UUID()
        retryTokens[id] = token
        record(id, "\(failure.message) \(Int(delay)) 秒后进行第 \(attempt) 次重试。", level: .warning)
        publish(id, phase: .reconnecting, message: "\(failure.message) \(Int(delay)) 秒后重试。")
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.retryTokens[id] == token, self.desired.contains(id), !self.shuttingDown else { return }
            self.retryTokens.removeValue(forKey: id)
            self.start(id)
        }
    }

    /// 每次用户连接或正常恢复后，最多通知一次连续失败。
    private func announceFailure(_ id: UUID, message: String) {
        if failureAnnounced.insert(id).inserted { onEvent?(id, .failed(message)) }
    }

    /// 清理当前主机的连接意图和自有会话，退出应用时不逐条弹通知。
    private func stop(_ id: UUID, announce: Bool) {
        let wasActive = desired.contains(id) || connections[id] != nil
        desired.remove(id)
        recovering.remove(id)
        retryTokens.removeValue(forKey: id)
        retryCounts.removeValue(forKey: id)
        failureAnnounced.remove(id)
        let connection = connections.removeValue(forKey: id)
        if let connection = connection { transport.stop(connection.ssh) }
        if wasActive { record(id, "已断开连接，并停止自动重试。") }
        publish(id, phase: .disconnected)
        if announce && connection?.ready == true { onEvent?(id, .disconnected) }
    }

    /// 同时记录未连接时的勾选与配置修改；“配置已启用”不代表监听已经成功。
    private func recordConfigurationChanges(from old: TunnelProfile, to new: TunnelProfile) {
        if old.connection != new.connection {
            record(new.id, "SSH 连接配置已更新；已建立的连接需重连后生效。")
        }
        for rule in old.forwards where !new.forwards.contains(where: { $0.id == rule.id }) {
            record(new.id, "已删除转发配置：\(describe(rule))。")
        }
        for rule in new.forwards {
            if let previous = old.forwards.first(where: { $0.id == rule.id }) {
                guard previous.isEnabled != rule.isEnabled || !previous.hasSameEndpoint(as: rule) else { continue }
                record(new.id, "转发配置已更新（\(rule.isEnabled ? "启用" : "停用")）：\(describe(rule))。")
            } else {
                record(new.id, "已添加转发配置（\(rule.isEnabled ? "启用" : "停用")）：\(describe(rule))。")
            }
        }
    }

    /// 用地址和端口识别规则，不把备注、密钥路径或 SSH 原始输出写入日志。
    private func describe(_ rule: ForwardRule) -> String {
        "[\(rule.bindAddress)]:\(rule.localPort) → [\(rule.remoteHost)]:\(rule.remotePort)"
    }

    /// 日志独立于系统通知开关，由界面层统一限制条数并持久化。
    private func record(_ id: UUID, _ message: String, level: ConnectionLogLevel = .info) {
        onLog?(id, ConnectionLogEntry(level: level, message: message))
    }

    /// 从实际已应用规则构建快照，目标服务是否可达不由监听成功推断。
    private func publish(_ id: UUID, phase: ConnectionPhase, message: String? = nil) {
        guard let profile = profiles[id] else { return }
        let connection = connections[id]
        var state = HostRuntimeState()
        state.phase = phase
        state.message = message ?? connection?.warning
        state.connectedConfiguration = connection?.ready == true ? connection?.ssh.connection : nil
        for rule in profile.forwards {
            if let error = connection?.ruleErrors[rule.id] {
                state.forwards[rule.id] = ForwardRuntimeState(phase: .failed, message: error)
            } else if let active = connection?.activeRules[rule.id], active.hasSameEndpoint(as: rule), rule.isEnabled {
                state.forwards[rule.id] = ForwardRuntimeState(phase: .listening)
            } else {
                state.forwards[rule.id] = ForwardRuntimeState(phase: rule.isEnabled ? .waiting : .disabled)
            }
        }
        onStateChange?(id, state)
    }
}

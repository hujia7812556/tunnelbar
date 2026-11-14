import Foundation

struct SSHConnection: Codable, Equatable {
    var hostname = ""
    var username = ""
    var port: Int?
    var identityFile = ""

    /// 检查输入边界；空用户名和端口交给现有 SSH 配置解析。
    func validate() throws {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace }) else {
            throw TunnelError.message("请输入有效的 SSH 主机地址或配置别名。")
        }
        if let port = port, !(1...65535).contains(port) {
            throw TunnelError.message("SSH 端口必须在 1～65535 之间。")
        }
    }
}

struct ForwardRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var bindAddress = "127.0.0.1"
    var localPort = 8080
    var remoteHost = "127.0.0.1"
    var remotePort = 8080
    var isEnabled = true

    /// 生成独立参数，不经 Shell 拼接；方括号兼容 IPv6 地址。
    var specification: String {
        "[\(bindAddress)]:\(localPort):[\(remoteHost)]:\(remotePort)"
    }

    /// 名称和启用状态不改变转发目标，便于识别真正需要调整的规则。
    func hasSameEndpoint(as other: ForwardRule) -> Bool {
        bindAddress == other.bindAddress && localPort == other.localPort &&
        remoteHost == other.remoteHost && remotePort == other.remotePort
    }

    /// 检查 TCP 端口和转发地址，避免将无效配置交给 SSH。
    func validate() throws {
        guard (1...65535).contains(localPort), (1...65535).contains(remotePort) else {
            throw TunnelError.message("转发端口必须在 1～65535 之间。")
        }
        for address in [bindAddress, remoteHost] {
            guard !address.isEmpty, !address.contains(where: { $0.isWhitespace }),
                  !address.contains("["), !address.contains("]") else {
                throw TunnelError.message("请输入有效的监听地址和目标地址；IPv6 地址无需填写方括号。")
            }
        }
    }
}

struct TunnelProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "新主机"
    var connection = SSHConnection()
    var forwards: [ForwardRule] = []
    var notifyOnChange = false
    var autoConnect = false

    /// 保存前集中检查主机与转发配置。
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelError.message("请填写主机显示名称。")
        }
        try connection.validate()
        var endpoints = Set<String>()
        var ids = Set<UUID>()
        for rule in forwards {
            guard ids.insert(rule.id).inserted else {
                throw TunnelError.message("配置包含重复的转发标识，请检查配置文件。")
            }
            try rule.validate()
            if rule.isEnabled {
                let key = "\(rule.bindAddress):\(rule.localPort)"
                guard endpoints.insert(key).inserted else {
                    throw TunnelError.message("同一主机不能重复启用监听地址和端口：\(key)。")
                }
            }
        }
    }
}

enum ConnectionPhase: String {
    case disconnected, connecting, connected, reconnecting, failed

    var title: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reconnecting: return "重连中"
        case .failed: return "连接失败"
        }
    }

    var isActive: Bool { self == .connecting || self == .connected || self == .reconnecting }
}

enum ForwardPhase {
    case disabled, waiting, listening, failed

    var title: String {
        switch self {
        case .disabled: return "未启用"
        case .waiting: return "等待连接"
        case .listening: return "已监听"
        case .failed: return "失败"
        }
    }
}

struct ForwardRuntimeState {
    var phase: ForwardPhase
    var message: String?
}

struct HostRuntimeState {
    var phase: ConnectionPhase = .disconnected
    var message: String?
    var forwards: [UUID: ForwardRuntimeState] = [:]
    var connectedConfiguration: SSHConnection?
}

enum ConnectionLogLevel: String, Codable {
    case info, success, warning, error

    var title: String {
        switch self {
        case .info: return "信息"
        case .success: return "成功"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

struct ConnectionLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: ConnectionLogLevel
    let message: String

    /// 只记录应用生成的事件说明，不保存 SSH 原始输出或凭据。
    init(level: ConnectionLogLevel, message: String, timestamp: Date = Date()) {
        id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }

    /// 复制日志时保留日期、时间和级别，便于区分不同运行时段。
    var plainText: String {
        "\(timestamp.formatted(date: .numeric, time: .standard)) [\(level.title)] \(message)"
    }
}

enum TunnelError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

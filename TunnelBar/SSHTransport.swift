import Foundation
import Darwin

/// 持续排空 stderr，只保留末尾少量诊断，避免管道阻塞及无限日志增长。
private final class DiagnosticTail {
    let pipe = Pipe()
    private let lock = NSLock()
    private var bytes = Data()
    private let finished = DispatchSemaphore(value: 0)

    /// 从独立后台队列读取；主线程与连接状态队列均不等待日志到达。
    func start() {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = self.pipe.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                self.lock.lock()
                self.bytes.append(chunk)
                if self.bytes.count > 8192 { self.bytes.removeFirst(self.bytes.count - 8192) }
                self.lock.unlock()
            }
            self.finished.signal()
        }
    }

    /// 子进程结束后给管道短暂排空时间，读取有上限的诊断快照。
    func finalText() -> String {
        _ = finished.wait(timeout: .now() + 0.5)
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

final class SSHSession {
    let id = UUID()
    let process = Process()
    let socketURL: URL
    let connection: SSHConnection
    fileprivate let diagnostics = DiagnosticTail()
    fileprivate let ended = DispatchSemaphore(value: 0)

    /// 记录本次连接身份，旧进程回调必须与当前会话匹配。
    init(socketURL: URL, connection: SSHConnection) {
        self.socketURL = socketURL
        self.connection = connection
    }
}

struct SSHCommandResult {
    let status: Int32
    let diagnostic: String

    var succeeded: Bool { status == 0 }
}

struct SSHFailure {
    let message: String
    let shouldRetry: Bool

    /// 只返回已知、简短的错误描述，避免把用户 ProxyCommand 的原始输出暴露到通知。
    static func describe(_ diagnostic: String, status: Int32) -> SSHFailure {
        let text = diagnostic.lowercased()
        if text.contains("host key verification failed") || text.contains("host identification has changed") {
            return SSHFailure(message: "主机指纹未知或已变化，请先在终端核实并建立受信任的 SSH 连接。", shouldRetry: false)
        }
        if text.contains("permission denied") || text.contains("authentication failed") ||
            text.contains("bad permissions") || text.contains("load key") || text.contains("no such identity") {
            return SSHFailure(message: "SSH 认证失败，请检查密钥、文件权限和 SSH Agent；首版不支持密码弹窗。", shouldRetry: false)
        }
        if text.contains("bad configuration") || text.contains("bad owner or permissions") ||
            text.contains("bad command-line") || text.contains("unknown option") || text.contains("unsupported option") ||
            text.contains("invalid") && text.contains("configuration") {
            return SSHFailure(message: "SSH 配置或参数无效，请检查该主机的系统 SSH 配置。", shouldRetry: false)
        }
        if text.contains("address already in use") || text.contains("cannot listen to port") {
            return SSHFailure(message: "本地监听地址或端口不可用，可能已被其他程序占用。", shouldRetry: false)
        }
        if text.contains("could not resolve hostname") {
            return SSHFailure(message: "暂时无法解析 SSH 主机地址。", shouldRetry: true)
        }
        if text.contains("connection refused") {
            return SSHFailure(message: "SSH 服务拒绝连接，请检查地址、端口及服务状态。", shouldRetry: true)
        }
        if text.contains("timed out") || text.contains("timeout") {
            return SSHFailure(message: "SSH 连接超时，等待网络恢复后重试。", shouldRetry: true)
        }
        return SSHFailure(message: "SSH 连接已结束（退出码 \(status)），请检查网络和主机配置。", shouldRetry: true)
    }
}

final class SSHTransport {
    private let directory: URL
    private let configurationFile: URL?

    /// 默认使用系统 SSH 配置；集成验证可注入独立配置，不修改用户环境。
    init(configurationFile: URL? = nil) {
        self.configurationFile = configurationFile
        // macOS 控制套接字有路径长度限制，采用随机短路径并限制目录权限。
        directory = URL(fileURLWithPath: "/tmp/tb-\(UUID().uuidString.prefix(12))", isDirectory: true)
    }

    /// 启动前台主连接。现有认证与跳板配置保留，应用独立管理全部转发。
    func start(_ connection: SSHConnection, onExit: @escaping (SSHSession, Int32, String) -> Void) throws -> SSHSession {
        try connection.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent(String(UUID().uuidString.prefix(8)))
        let session = SSHSession(socketURL: socket, connection: connection)
        var arguments = ["-M", "-N", "-T", "-S", socket.path,
                         "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no",
                         "-o", "ClearAllForwardings=yes", "-o", "BatchMode=yes",
                         "-o", "RequestTTY=no", "-o", "RemoteCommand=none",
                         "-o", "PermitLocalCommand=no", "-o", "StrictHostKeyChecking=yes",
                         "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=1",
                         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if let configurationFile = configurationFile { arguments += ["-F", configurationFile.path] }
        if !connection.username.isEmpty { arguments += ["-l", connection.username] }
        if let port = connection.port { arguments += ["-p", String(port)] }
        if !connection.identityFile.isEmpty {
            arguments += ["-i", (connection.identityFile as NSString).expandingTildeInPath]
        }
        arguments.append(connection.hostname.trimmingCharacters(in: .whitespacesAndNewlines))
        prepare(session.process, arguments: arguments, diagnostics: session.diagnostics)
        session.process.terminationHandler = { [weak session] process in
            guard let session = session else { return }
            let text = session.diagnostics.finalText()
            session.ended.signal()
            onExit(session, process.terminationStatus, text)
        }
        try session.process.run()
        session.diagnostics.start()
        return session
    }

    /// 向已存在的私有主连接发送控制请求；回退路径明确禁止另建网络连接。
    func control(_ operation: String, session: SSHSession, rule: ForwardRule? = nil) -> SSHCommandResult {
        var arguments = ["-F", "/dev/null", "-S", session.socketURL.path,
                         "-o", "ControlMaster=no", "-o", "BatchMode=yes",
                         "-o", "ProxyCommand=/usr/bin/false", "-O", operation]
        if let rule = rule { arguments += ["-L", rule.specification] }
        arguments.append("tunnelbar-control.invalid")
        let process = Process()
        let diagnostics = DiagnosticTail()
        let ended = DispatchSemaphore(value: 0)
        prepare(process, arguments: arguments, diagnostics: diagnostics)
        process.terminationHandler = { _ in ended.signal() }
        do {
            try process.run()
            diagnostics.start()
        } catch {
            return SSHCommandResult(status: -1, diagnostic: "无法启动 SSH 控制命令。")
        }
        if ended.wait(timeout: .now() + 5) == .timedOut {
            terminateOwnedProcess(process, ended: ended)
            return SSHCommandResult(status: -1, diagnostic: "SSH control timeout")
        }
        let text = diagnostics.finalText()
        // OpenSSH 的取消失败可能仍返回 0，必须结合取消响应判断实际结果。
        if operation == "cancel" && (text.contains("cancel forward request failed") ||
            text.contains("forwarding request failed") || text.contains("port not forwarded")) {
            return SSHCommandResult(status: -1, diagnostic: text)
        }
        return SSHCommandResult(status: process.terminationStatus, diagnostic: text)
    }

    /// 正常关闭自己的主连接；未建立控制通道时只终止所持有的 Process。
    func stop(_ session: SSHSession) {
        if session.process.isRunning && FileManager.default.fileExists(atPath: session.socketURL.path) {
            _ = control("exit", session: session)
        }
        if session.process.isRunning && session.ended.wait(timeout: .now() + 1) == .timedOut {
            terminateOwnedProcess(session.process, ended: session.ended)
        }
        removeSocket(session)
    }

    /// 清理已结束会话的套接字，不扫描其他进程或用户控制目录。
    func removeSocket(_ session: SSHSession) {
        try? FileManager.default.removeItem(at: session.socketURL)
    }

    /// 所有自有会话结束后移除本次运行的临时目录。
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 统一标准流和语言环境，继承 SSH Agent 但不请求交互输入。
    private func prepare(_ process: Process, arguments: [String], diagnostics: DiagnosticTail) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics.pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment
    }

    /// 仅处理当前持有且仍存活的子进程，避免按端口或旧 PID 清理。
    private func terminateOwnedProcess(_ process: Process, ended: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if ended.wait(timeout: .now() + 1) == .timedOut && process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = ended.wait(timeout: .now() + 1)
        }
    }
}

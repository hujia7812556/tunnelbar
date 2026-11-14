import Foundation
import Darwin

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// 记录真实后台快照，测试不访问管理器内部进程表。
final class StateRecorder {
    private let lock = NSLock()
    private var states: [UUID: HostRuntimeState] = [:]
    private var revisions: [UUID: Int] = [:]
    private var entries: [UUID: [ConnectionLogEntry]] = [:]

    /// 后台更新状态。
    func record(_ id: UUID, _ state: HostRuntimeState) {
        lock.lock()
        states[id] = state
        revisions[id] = (revisions[id] ?? 0) + 1
        lock.unlock()
    }

    /// 获取线程安全的状态副本。
    func get(_ id: UUID) -> HostRuntimeState {
        snapshot(id).0
    }

    /// 同时读取版本与状态，避免异步操作尚未开始时误用上一轮成功结果。
    func snapshot(_ id: UUID) -> (HostRuntimeState, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (states[id] ?? HostRuntimeState(), revisions[id] ?? 0)
    }

    /// 收集连接管理器产生的真实日志，不从状态反推日志结果。
    func recordLog(_ id: UUID, _ entry: ConnectionLogEntry) {
        lock.lock()
        entries[id, default: []].append(entry)
        lock.unlock()
    }

    /// 获取已记录事件，用于检查错误、恢复及持久化。
    func logs(_ id: UUID) -> [ConnectionLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries[id] ?? []
    }
}

/// 临时持有回环监听端口，既用于选取空闲端口，也用于制造真实冲突。
final class ReservedPort {
    private var descriptor: Int32
    let port: Int

    /// 由系统分配测试端口，避免占用固定业务端口。
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        descriptor = fd
        guard fd >= 0 else { throw CheckFailure(description: "无法创建测试 socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw CheckFailure(description: "无法监听测试端口")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// 释放本测试持有的端口。
    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    /// 离开作用域时保证关闭测试监听。
    deinit { close() }
}

/// 持有同一条真实 TCP 连接，验证规则变化不会中断已有数据通道。
final class EchoClient {
    private let descriptor: Int32

    /// 连接到本地转发入口，并限制读超时，避免失败时无限等待。
    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CheckFailure(description: "无法创建客户端 socket") }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            Darwin.close(descriptor)
            throw CheckFailure(description: "无法连接转发端口 \(port)")
        }
    }

    /// 在原 socket 上完成一次往返，不通过重新连接掩盖断线。
    func echo(_ text: String) throws {
        let payload = Array(text.utf8)
        var sent = 0
        while sent < payload.count {
            let count = payload.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: sent), payload.count - sent, 0)
            }
            guard count > 0 else { throw CheckFailure(description: "已有 TCP 连接发送失败：\(text)") }
            sent += count
        }
        var received = [UInt8](repeating: 0, count: payload.count)
        var offset = 0
        while offset < payload.count {
            let count = received.withUnsafeMutableBytes { buffer in
                Darwin.recv(descriptor, buffer.baseAddress!.advanced(by: offset), payload.count - offset, 0)
            }
            guard count > 0 else { throw CheckFailure(description: "已有 TCP 连接中断或超时：\(text)") }
            offset += count
        }
        guard received == payload else { throw CheckFailure(description: "回显数据不一致") }
    }

    /// 只关闭当前测试创建的客户端连接。
    deinit { Darwin.close(descriptor) }
}

@main
struct IntegrationCheck {
    /// 运行一组核心行为检查，任何失败均返回非零退出码。
    static func main() {
        do {
            try run()
            print("通过：动态转发、备注不触发重试、真实断线恢复、快速重连、主动断开、取消失败判定，以及事件日志和有上限的持久化。")
        } catch {
            fputs("集成验证失败：\(error)\n", stderr)
            exit(1)
        }
    }

    /// 等待异步状态结果，超时只报告当前关键快照。
    private static func wait(_ label: String, recorder: StateRecorder, id: UUID,
                             afterRevision: Int = -1,
                             until condition: (HostRuntimeState) -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let (state, revision) = recorder.snapshot(id)
            if revision > afterRevision && condition(state) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let state = recorder.get(id)
        throw CheckFailure(description: "\(label)超时：\(state.phase.title)，\(state.message ?? "无主机错误")")
    }

    /// 获取一个由操作系统分配且已释放的候选端口。
    private static func unusedPort() throws -> Int {
        let reservation = try ReservedPort()
        let port = reservation.port
        reservation.close()
        return port
    }

    /// 验证已取消的监听不再接受新客户端。
    private static func expectClosed(_ port: Int) throws {
        if (try? EchoClient(port: port)) != nil { throw CheckFailure(description: "已取消的端口 \(port) 仍可建立新连接") }
    }

    /// 使用临时 SSH 配置运行端到端场景，完成后关闭所有测试资源。
    private static func run() throws {
        guard CommandLine.arguments.count == 3, let echoPort = Int(CommandLine.arguments[2]) else {
            throw CheckFailure(description: "需要临时 ssh_config 路径和 echo 端口")
        }
        let transport = SSHTransport(configurationFile: URL(fileURLWithPath: CommandLine.arguments[1]))
        let manager = TunnelManager(transport: transport)
        let recorder = StateRecorder()
        manager.onStateChange = { recorder.record($0, $1) }
        manager.onLog = { recorder.recordLog($0, $1) }
        defer {
            let finished = DispatchSemaphore(value: 0)
            manager.shutdown { finished.signal() }
            _ = finished.wait(timeout: .now() + 15)
        }
        var profile = TunnelProfile()
        profile.name = "本地集成验证"
        profile.connection.hostname = "fixture"
        var first = ForwardRule()
        first.localPort = try unusedPort()
        first.remotePort = echoPort
        profile.forwards = [first]
        manager.configure([profile])
        manager.connect(profile.id)
        try wait("初始连接", recorder: recorder, id: profile.id) {
            $0.phase == .connected && $0.forwards[first.id]?.phase == .listening
        }
        let original = try EchoClient(port: first.localPort)
        try original.echo("initial")

        var second = ForwardRule()
        second.localPort = try unusedPort()
        second.remotePort = echoPort
        profile.forwards.append(second)
        manager.configure([profile])
        try wait("新增第二条规则", recorder: recorder, id: profile.id) { $0.forwards[second.id]?.phase == .listening }
        let secondClient = try EchoClient(port: second.localPort)
        try secondClient.echo("second")
        try original.echo("after-add")

        let occupied = try ReservedPort()
        var conflict = ForwardRule()
        conflict.localPort = occupied.port
        conflict.remotePort = echoPort
        profile.forwards.append(conflict)
        manager.configure([profile])
        try wait("端口冲突", recorder: recorder, id: profile.id) { $0.forwards[conflict.id]?.phase == .failed }
        try original.echo("after-conflict")

        profile.forwards[1].isEnabled = false
        manager.configure([profile])
        try wait("取消规则", recorder: recorder, id: profile.id) { $0.forwards[second.id]?.phase == .disabled }
        try expectClosed(second.localPort)
        try secondClient.echo("existing-channel-survives-cancel")
        try original.echo("after-cancel")

        profile.forwards.removeAll { $0.id == conflict.id }
        profile.forwards[0].localPort = occupied.port
        manager.configure([profile])
        try wait("修改失败回滚", recorder: recorder, id: profile.id) {
            $0.forwards[first.id]?.phase == .failed && ($0.forwards[first.id]?.message?.contains("恢复原转发") ?? false)
        }
        try EchoClient(port: first.localPort).echo("rollback-listener")
        try original.echo("after-rollback")
        occupied.close()

        // 冲突已经解除，纯备注修改仍不得顺带重试失败规则或影响原连接。
        let beforeRemark = recorder.snapshot(profile.id).1
        profile.forwards[0].name = "仅修改备注"
        manager.configure([profile])
        try wait("仅改备注不重试", recorder: recorder, id: profile.id, afterRevision: beforeRemark) {
            $0.forwards[first.id]?.phase == .failed
        }
        try expectClosed(occupied.port)
        try original.echo("remark-does-not-retry-or-disconnect")

        manager.retryForwards(profile.id)
        try wait("重试修改", recorder: recorder, id: profile.id) { $0.forwards[first.id]?.phase == .listening }
        try EchoClient(port: occupied.port).echo("new-listener")
        try original.echo("after-edit")
        try expectClosed(first.localPort)

        profile.name = "已改名"
        profile.notifyOnChange = true
        profile.autoConnect = true
        manager.configure([profile])
        Thread.sleep(forTimeInterval: 0.2)
        try original.echo("preferences-dont-reconnect")

        // 请求夹具重启本次测试的 SSH 服务，验证真实断线后能够恢复监听。
        let requestURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
            .appendingPathComponent("restart.request")
        let beforeOutage = recorder.snapshot(profile.id).1
        try Data().write(to: requestURL)
        try wait("检测断线", recorder: recorder, id: profile.id, afterRevision: beforeOutage) { $0.phase == .reconnecting }
        try wait("自动恢复转发", recorder: recorder, id: profile.id, afterRevision: beforeOutage) {
            $0.phase == .connected && $0.forwards[first.id]?.phase == .listening
        }
        try EchoClient(port: occupied.port).echo("recovered-after-actual-outage")

        let beforeRestart = recorder.snapshot(profile.id).1
        manager.reconnect(profile.id)
        manager.disconnect(profile.id)
        manager.connect(profile.id)
        try wait("快速重连", recorder: recorder, id: profile.id, afterRevision: beforeRestart) {
            $0.phase == .connected && $0.forwards[first.id]?.phase == .listening
        }
        let afterRestart = try EchoClient(port: occupied.port)
        try afterRestart.echo("new-generation")
        Thread.sleep(forTimeInterval: 0.5)
        try afterRestart.echo("late-exit-did-not-clobber-new-generation")
        manager.disconnect(profile.id)
        try wait("主动断开", recorder: recorder, id: profile.id) { $0.phase == .disconnected }
        Thread.sleep(forTimeInterval: 2.5)
        guard recorder.get(profile.id).phase == .disconnected else {
            throw CheckFailure(description: "主动断开后不应自动重连")
        }
        try expectClosed(occupied.port)

        // 从实际连接场景验证日志，再核对退出写入等待和磁盘条数上限。
        let entries = recorder.logs(profile.id)
        guard entries.contains(where: { $0.level == .success && $0.message == "SSH 连接已建立。" }),
              entries.contains(where: { $0.level == .error && $0.message.contains("无法建立本地监听") }),
              entries.contains(where: { $0.level == .warning && $0.message.contains("重试") }),
              entries.contains(where: { $0.message == "SSH 连接已恢复。" }),
              entries.contains(where: { $0.message.contains("已停止监听") }),
              entries.last?.message == "已断开连接，并停止自动重试。" else {
            throw CheckFailure(description: "连接、错误、恢复或断开的关键日志缺失")
        }
        let logURL = requestURL.deletingLastPathComponent().appendingPathComponent("connection-logs.json")
        let logStore = ConnectionLogStore(fileURL: logURL)
        let older = (0..<ConnectionLogStore.entriesPerHost).map {
            ConnectionLogEntry(level: .info, message: "较早的记录 \($0)")
        }
        let saved = DispatchSemaphore(value: 0)
        logStore.save([profile.id: older + entries]) { error in
            if let error = error { fputs("日志保存失败：\(error)\n", stderr) }
        }
        logStore.flush { saved.signal() }
        guard saved.wait(timeout: .now() + 5) == .success else { throw CheckFailure(description: "日志写入未完成") }
        let loaded = try logStore.load()[profile.id] ?? []
        let disk = try JSONDecoder().decode([String: [ConnectionLogEntry]].self, from: Data(contentsOf: logURL))
        guard loaded.count == ConnectionLogStore.entriesPerHost,
              loaded.last?.id == entries.last?.id,
              disk[profile.id.uuidString]?.count == ConnectionLogStore.entriesPerHost else {
            throw CheckFailure(description: "日志未正确持久化，或磁盘记录超过条数上限")
        }

        // 真实 OpenSSH 的 cancel 失败可能退出 0，专门验证这一必要分支。
        let direct = try transport.start(profile.connection) { _, _, _ in }
        defer { transport.stop(direct) }
        let readyDeadline = Date().addingTimeInterval(15)
        while !transport.control("check", session: direct).succeeded && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let cancellation = transport.control("cancel", session: direct, rule: first)
        guard !cancellation.succeeded else { throw CheckFailure(description: "取消不存在的转发不能误判成功") }
    }
}

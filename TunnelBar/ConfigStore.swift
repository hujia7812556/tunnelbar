import Foundation

final class ConfigStore {
    let fileURL: URL

    /// 配置放在用户应用支持目录；测试可以提供独立文件路径。
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TunnelBar/hosts.json")
    }

    /// 读取失败直接抛出，禁止把损坏配置当成空配置覆盖。
    func load() throws -> [TunnelProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let profiles = try JSONDecoder().decode([TunnelProfile].self, from: Data(contentsOf: fileURL))
        guard Set(profiles.map { $0.id }).count == profiles.count else {
            throw TunnelError.message("配置包含重复的主机标识。")
        }
        for profile in profiles { try profile.validate() }
        return profiles
    }

    /// 原子保存元数据；配置不包含密码或私钥内容。
    func save(_ profiles: [TunnelProfile]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}

final class ConnectionLogStore {
    static let entriesPerHost = 300
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.local.TunnelBar.logs", qos: .utility)

    /// 日志与主机配置分开保存，日志写入失败不影响连接。
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TunnelBar/connection-logs.json")
    }

    /// 加载各主机最近的有限条日志，读取错误交给界面说明。
    func load() throws -> [UUID: [ConnectionLogEntry]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let saved = try JSONDecoder().decode([String: [ConnectionLogEntry]].self, from: Data(contentsOf: fileURL))
        var logs: [UUID: [ConnectionLogEntry]] = [:]
        for (key, entries) in saved {
            guard let id = UUID(uuidString: key) else { throw TunnelError.message("日志中的主机标识无效。") }
            logs[id] = Array(entries.suffix(Self.entriesPerHost))
        }
        return logs
    }

    /// 在独立串行队列原子保存快照，避免阻塞界面和 SSH 状态处理。
    func save(_ logs: [UUID: [ConnectionLogEntry]], completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                let snapshot = Dictionary(uniqueKeysWithValues: logs.map {
                    ($0.key.uuidString, Array($0.value.suffix(Self.entriesPerHost)))
                })
                try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: self.fileURL, options: .atomic)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// 退出前等待已排队的日志写入完成，不丢失最后的断开事件。
    func flush(completion: @escaping () -> Void) {
        queue.async(execute: completion)
    }
}

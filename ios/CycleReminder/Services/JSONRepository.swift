import Foundation

struct JSONRepository {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func load() -> [ReminderTask] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? BackupCodec.decode(data)) ?? []
    }

    func loadGracePercentage() -> Double {
        guard let data = try? Data(contentsOf: fileURL) else { return 10 }
        return BackupCodec.gracePercentage(from: data)
    }

    func save(_ tasks: [ReminderTask], gracePercentage: Double = 10, syncBaseline: SyncBaseline? = nil) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = try BackupCodec.encode(tasks, gracePercentage: gracePercentage)
        var object = try JSONSerialization.jsonObject(with: backup) as! [String: Any]
        if let syncBaseline {
            object["syncBaseline"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(syncBaseline))
        } else if FileManager.default.fileExists(atPath: fileURL.path),
                  let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any] {
            // Preserve even unreadable metadata; ordinary edits must not reset deletion history.
            object["syncBaseline"] = previous["syncBaseline"]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }

    func loadSyncBaseline() throws -> SyncBaseline? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseline = object["syncBaseline"] else { return nil }
        let baselineData = try JSONSerialization.data(withJSONObject: baseline)
        let decoded = try JSONDecoder().decode(SyncBaseline.self, from: baselineData)
        guard let rawBaseline = baseline as? [String: Any],
              var rawSnapshot = rawBaseline["snapshot"] as? [String: Any] else {
            throw WebDAVError.message("本机同步基线无效。")
        }
        rawSnapshot["schemaVersion"] = 4
        _ = try SyncSnapshot.decode(JSONSerialization.data(withJSONObject: rawSnapshot))
        return decoded
    }

    func recoveryFiles() throws -> [URL] {
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("SyncRecovery", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func saveRecovery(local: SyncSnapshot, remote: SyncSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("SyncRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString
        try local.encoded().write(to: directory.appendingPathComponent(prefix + "-local.json"), options: .atomic)
        try remote.encoded().write(to: directory.appendingPathComponent(prefix + "-remote.json"), options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("CycleReminder", isDirectory: true)
            .appendingPathComponent("tasks.json", isDirectory: false)
    }
}

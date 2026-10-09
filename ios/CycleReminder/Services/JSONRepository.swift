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

    func save(_ tasks: [ReminderTask], gracePercentage: Double = 10) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try BackupCodec.encode(tasks, gracePercentage: gracePercentage)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("CycleReminder", isDirectory: true)
            .appendingPathComponent("tasks.json", isDirectory: false)
    }
}

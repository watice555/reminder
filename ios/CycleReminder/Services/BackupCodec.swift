import Foundation

enum BackupCodecError: LocalizedError {
    case invalidBackup

    var errorDescription: String? {
        "备份必须是旧版任务数组或包含 tasks 数组的备份对象。"
    }
}

enum BackupCodec {
    static func decode(_ data: Data, fallbackDate: Date = Date()) throws -> [ReminderTask] {
        let decoder = JSONDecoder()
        let decodedTasks: [ReminderTask]

        if let envelope = try? decoder.decode(BackupEnvelope.self, from: data) {
            decodedTasks = envelope.tasks
        } else if let legacyTasks = try? decoder.decode(LossyArray<ReminderTask>.self, from: data) {
            decodedTasks = legacyTasks.elements
        } else {
            throw BackupCodecError.invalidBackup
        }

        var seenTaskIDs = Set<String>()
        return decodedTasks
            .compactMap { $0.normalized(fallbackDate: fallbackDate) }
            .filter { seenTaskIDs.insert($0.id).inserted }
    }

    static func encode(_ tasks: [ReminderTask], exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(BackupEnvelope(tasks: tasks, exportedAt: exportedAt))
    }
}

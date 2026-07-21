import Foundation

struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            if let value = try container.decode(FailableDecodable<Element>.self).value {
                values.append(value)
            }
        }
        elements = values
    }
}

private struct FailableDecodable<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

enum ISODate {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct CompletionRecord: Codable, Identifiable, Equatable {
    var id: String
    var completedAt: String
    var scheduledDueAt: String
    var intervalHours: Double

    var completedDate: Date? { ISODate.parse(completedAt) }
    var scheduledDueDate: Date? { ISODate.parse(scheduledDueAt) }

    func normalized() -> CompletionRecord? {
        guard
            intervalHours.isFinite,
            intervalHours > 0,
            let completedDate,
            let scheduledDueDate
        else {
            return nil
        }

        return CompletionRecord(
            id: id.isEmpty ? UUID().uuidString : id,
            completedAt: ISODate.string(from: completedDate),
            scheduledDueAt: ISODate.string(from: scheduledDueDate),
            intervalHours: intervalHours
        )
    }
}

struct ReminderTask: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var intervalHours: Double
    var lastCompletedAt: String
    var nextDueAt: String
    var createdAt: String
    var completions: [CompletionRecord]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case intervalHours
        case lastCompletedAt
        case nextDueAt
        case createdAt
        case completions
    }

    init(
        id: String,
        name: String,
        intervalHours: Double,
        lastCompletedAt: String,
        nextDueAt: String,
        createdAt: String,
        completions: [CompletionRecord] = []
    ) {
        self.id = id
        self.name = name
        self.intervalHours = intervalHours
        self.lastCompletedAt = lastCompletedAt
        self.nextDueAt = nextDueAt
        self.createdAt = createdAt
        self.completions = completions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        intervalHours = try container.decode(Double.self, forKey: .intervalHours)
        lastCompletedAt = try container.decode(String.self, forKey: .lastCompletedAt)
        nextDueAt = try container.decode(String.self, forKey: .nextDueAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? lastCompletedAt
        completions = try container.decodeIfPresent(
            LossyArray<CompletionRecord>.self,
            forKey: .completions
        )?.elements ?? []
    }

    var lastCompletedDate: Date? { ISODate.parse(lastCompletedAt) }
    var nextDueDate: Date? { ISODate.parse(nextDueAt) }
    var createdDate: Date? { ISODate.parse(createdAt) }

    static func create(name: String, intervalHours: Double, now: Date = Date()) -> ReminderTask {
        let timestamp = ISODate.string(from: now)
        return ReminderTask(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            intervalHours: intervalHours,
            lastCompletedAt: timestamp,
            nextDueAt: ISODate.string(from: now.addingTimeInterval(intervalHours * 3_600)),
            createdAt: timestamp
        )
    }

    mutating func update(name: String, intervalHours: Double) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.intervalHours = intervalHours
        let anchor = lastCompletedDate ?? Date()
        nextDueAt = ISODate.string(from: anchor.addingTimeInterval(intervalHours * 3_600))
    }

    mutating func complete(at date: Date = Date()) {
        let record = CompletionRecord(
            id: UUID().uuidString,
            completedAt: ISODate.string(from: date),
            scheduledDueAt: nextDueAt,
            intervalHours: intervalHours
        )
        completions.append(record)
        lastCompletedAt = record.completedAt
        nextDueAt = ISODate.string(from: date.addingTimeInterval(intervalHours * 3_600))
    }

    func normalized(fallbackDate: Date = Date()) -> ReminderTask? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, intervalHours.isFinite, intervalHours > 0 else {
            return nil
        }

        let lastDate = lastCompletedDate ?? fallbackDate
        let dueDate = nextDueDate ?? lastDate.addingTimeInterval(intervalHours * 3_600)
        let creationDate = createdDate ?? fallbackDate
        var seenCompletionIDs = Set<String>()
        let safeCompletions = completions
            .compactMap { $0.normalized() }
            .filter { seenCompletionIDs.insert($0.id).inserted }
            .sorted { ($0.completedDate ?? .distantPast) < ($1.completedDate ?? .distantPast) }

        return ReminderTask(
            id: id.isEmpty ? UUID().uuidString : id,
            name: trimmedName,
            intervalHours: intervalHours,
            lastCompletedAt: ISODate.string(from: lastDate),
            nextDueAt: ISODate.string(from: dueDate),
            createdAt: ISODate.string(from: creationDate),
            completions: safeCompletions
        )
    }
}

struct BackupEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let exportedAt: String
    let tasks: [ReminderTask]

    init(tasks: [ReminderTask], exportedAt: Date = Date()) {
        schemaVersion = 2
        self.exportedAt = ISODate.string(from: exportedAt)
        self.tasks = tasks
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportedAt
        case tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt) ?? ISODate.string(from: Date())
        tasks = try container.decode(LossyArray<ReminderTask>.self, forKey: .tasks).elements
    }
}

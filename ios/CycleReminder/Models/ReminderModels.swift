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

enum ReminderDate {
    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
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

enum ReminderMode: String, Codable, CaseIterable, Identifiable {
    case due
    case remainingPercentage
    case remainingTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .due:
            return "到期时"
        case .remainingPercentage:
            return "按剩余百分比"
        case .remainingTime:
            return "按剩余时间"
        }
    }
}

struct ReminderRule: Codable, Identifiable, Equatable {
    var id: String
    var mode: ReminderMode
    var amount: Double

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case amount
    }

    init(id: String = UUID().uuidString, mode: ReminderMode, amount: Double = 0) {
        self.id = id
        self.mode = mode
        self.amount = amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        mode = try container.decode(ReminderMode.self, forKey: .mode)
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0
    }

    func normalized(intervalHours: Double) -> ReminderRule? {
        guard amount.isFinite else { return nil }

        switch mode {
        case .due:
            return ReminderRule(id: id.isEmpty ? UUID().uuidString : id, mode: .due)
        case .remainingPercentage:
            guard amount > 0, amount < 100 else { return nil }
        case .remainingTime:
            guard amount > 0, amount < intervalHours else { return nil }
        }

        return ReminderRule(
            id: id.isEmpty ? UUID().uuidString : id,
            mode: mode,
            amount: amount
        )
    }

    func fireDate(dueDate: Date, intervalHours: Double) -> Date? {
        guard let normalized = normalized(intervalHours: intervalHours) else { return nil }

        switch normalized.mode {
        case .due:
            return dueDate
        case .remainingPercentage:
            return dueDate.addingTimeInterval(-intervalHours * 3_600 * normalized.amount / 100)
        case .remainingTime:
            return dueDate.addingTimeInterval(-normalized.amount * 3_600)
        }
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
    var reminders: [ReminderRule]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case intervalHours
        case lastCompletedAt
        case nextDueAt
        case createdAt
        case completions
        case reminders
    }

    init(
        id: String,
        name: String,
        intervalHours: Double,
        lastCompletedAt: String,
        nextDueAt: String,
        createdAt: String,
        completions: [CompletionRecord] = [],
        reminders: [ReminderRule] = []
    ) {
        self.id = id
        self.name = name
        self.intervalHours = intervalHours
        self.lastCompletedAt = lastCompletedAt
        self.nextDueAt = nextDueAt
        self.createdAt = createdAt
        self.completions = completions
        self.reminders = reminders
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
        reminders = try container.decodeIfPresent(
            LossyArray<ReminderRule>.self,
            forKey: .reminders
        )?.elements ?? []
    }

    var lastCompletedDate: Date? { ISODate.parse(lastCompletedAt) }
    var nextDueDate: Date? { ISODate.parse(nextDueAt) }
    var createdDate: Date? { ISODate.parse(createdAt) }

    static func create(
        name: String,
        intervalHours: Double,
        reminders: [ReminderRule] = [],
        lastCompletedAt: Date? = nil,
        now: Date = Date()
    ) -> ReminderTask {
        let completedDate = lastCompletedAt ?? now
        return ReminderTask(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            intervalHours: intervalHours,
            lastCompletedAt: ISODate.string(from: completedDate),
            nextDueAt: ISODate.string(
                from: completedDate.addingTimeInterval(intervalHours * 3_600)
            ),
            createdAt: ISODate.string(from: now),
            reminders: reminders.compactMap { $0.normalized(intervalHours: intervalHours) }
        )
    }

    mutating func update(name: String, intervalHours: Double, reminders: [ReminderRule]) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.intervalHours = intervalHours
        self.reminders = reminders.compactMap { $0.normalized(intervalHours: intervalHours) }
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

    @discardableResult
    mutating func backfill(at date: Date, now: Date = Date()) -> Bool {
        guard
            let lastCompletedDate,
            date > lastCompletedDate,
            date <= now
        else {
            return false
        }

        complete(at: date)
        return true
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
        var seenReminderIDs = Set<String>()
        let safeReminders = reminders
            .compactMap { $0.normalized(intervalHours: intervalHours) }
            .filter { seenReminderIDs.insert($0.id).inserted }

        return ReminderTask(
            id: id.isEmpty ? UUID().uuidString : id,
            name: trimmedName,
            intervalHours: intervalHours,
            lastCompletedAt: ISODate.string(from: lastDate),
            nextDueAt: ISODate.string(from: dueDate),
            createdAt: ISODate.string(from: creationDate),
            completions: safeCompletions,
            reminders: safeReminders
        )
    }
}

struct BackupEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let exportedAt: String
    let tasks: [ReminderTask]

    init(tasks: [ReminderTask], exportedAt: Date = Date()) {
        schemaVersion = 3
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

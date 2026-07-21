import Foundation

struct DailyCompletion: Identifiable, Equatable {
    let date: Date
    let count: Int

    var id: Date { date }
}

struct TaskCompletionRanking: Identifiable, Equatable {
    let taskID: String
    let name: String
    let total: Int
    let onTimeRate: Double?
    let latestCompletedAt: Date?

    var id: String { taskID }
}

struct CompletionStatistics: Equatable {
    let today: Int
    let lastSevenDays: Int
    let total: Int
    let onTimeCount: Int
    let onTimeRate: Double?
    let daily: [DailyCompletion]
    let taskRanking: [TaskCompletionRanking]
}

enum StatisticsCalculator {
    static func calculate(
        tasks: [ReminderTask],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CompletionStatistics {
        let todayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let completions = tasks
            .flatMap(\.completions)
            .compactMap { record -> (record: CompletionRecord, completedAt: Date, dueAt: Date)? in
                guard
                    let completedAt = record.completedDate,
                    let dueAt = record.scheduledDueDate,
                    completedAt <= now
                else {
                    return nil
                }
                return (record, completedAt, dueAt)
            }

        let today = completions.filter { calendar.isDate($0.completedAt, inSameDayAs: now) }.count
        let recent = completions.filter { $0.completedAt >= sevenDayStart }
        let onTimeCount = completions.filter { $0.completedAt <= $0.dueAt }.count
        let daily = (0..<7).map { offset -> DailyCompletion in
            let date = calendar.date(byAdding: .day, value: offset, to: sevenDayStart) ?? sevenDayStart
            let count = recent.filter { calendar.isDate($0.completedAt, inSameDayAs: date) }.count
            return DailyCompletion(date: date, count: count)
        }

        let taskRanking = tasks.compactMap { task -> TaskCompletionRanking? in
            let valid = task.completions.compactMap { record -> (CompletionRecord, Date, Date)? in
                guard let completedAt = record.completedDate, let dueAt = record.scheduledDueDate else {
                    return nil
                }
                return (record, completedAt, dueAt)
            }
            guard !valid.isEmpty else { return nil }
            let taskOnTime = valid.filter { $0.1 <= $0.2 }.count
            return TaskCompletionRanking(
                taskID: task.id,
                name: task.name,
                total: valid.count,
                onTimeRate: Double(taskOnTime) / Double(valid.count),
                latestCompletedAt: valid.map(\.1).max()
            )
        }
        .sorted {
            if $0.total == $1.total {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.total > $1.total
        }

        return CompletionStatistics(
            today: today,
            lastSevenDays: recent.count,
            total: completions.count,
            onTimeCount: onTimeCount,
            onTimeRate: completions.isEmpty ? nil : Double(onTimeCount) / Double(completions.count),
            daily: daily,
            taskRanking: taskRanking
        )
    }
}

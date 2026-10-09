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
    let cycleCount: Int
    let overdueCount: Int
    let onTimeCount: Int
    let onTimeWeight: Double
    let totalWeight: Double
    let medianIntervalHours: Double?
    let medianIntervalRatio: Double?
    let intervalCount: Int
    let gracePercentage: Double

    var id: String { taskID }
}

struct CompletionStatistics: Equatable {
    let cycleCount: Int
    let overdueCount: Int
    let today: Int
    let lastSevenDays: Int
    let total: Int
    let onTimeCount: Int
    let onTimeRate: Double?
    let daily: [DailyCompletion]
    let taskRanking: [TaskCompletionRanking]
}

enum StatisticsCalculator {
    static func validGrace(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func calculate(
        tasks: [ReminderTask],
        now: Date = Date(),
        calendar: Calendar = .current,
        globalGrace: Double = 10
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
        let daily = (0..<7).map { offset -> DailyCompletion in
            let date = calendar.date(byAdding: .day, value: offset, to: sevenDayStart) ?? sevenDayStart
            let count = recent.filter { calendar.isDate($0.completedAt, inSameDayAs: date) }.count
            return DailyCompletion(date: date, count: count)
        }

        let taskRanking = tasks.map { task -> TaskCompletionRanking in
            let grace = validGrace(task.gracePercentage) ?? validGrace(globalGrace) ?? 10
            let valid = task.completions.compactMap { $0.normalized() }.filter {
                ($0.completedDate ?? .distantFuture) <= now
            }.sorted { $0.completedDate! < $1.completedDate! }
            let onTime = valid.filter {
                $0.completedDate! <= $0.scheduledDueDate!.addingTimeInterval($0.intervalHours * 3600 * grace / 100)
            }
            let overdue = task.nextDueDate.map {
                now > $0.addingTimeInterval(task.intervalHours * 3600 * grace / 100)
            } ?? false
            let cycleCount = valid.count + (overdue ? 1 : 0)
            let intervals = zip(valid, valid.dropFirst()).map {
                $1.completedDate!.timeIntervalSince($0.completedDate!) / 3600
            }
            let ratios = zip(intervals, valid.dropFirst()).map { $0 / $1.intervalHours }
            return TaskCompletionRanking(
                taskID: task.id, name: task.name, total: valid.count,
                onTimeRate: cycleCount == 0 ? nil : Double(onTime.count) / Double(cycleCount),
                latestCompletedAt: valid.last?.completedDate,
                cycleCount: cycleCount, overdueCount: overdue ? 1 : 0,
                onTimeCount: onTime.count,
                onTimeWeight: onTime.reduce(0) { $0 + $1.intervalHours },
                totalWeight: valid.reduce(0) { $0 + $1.intervalHours } + (overdue ? task.intervalHours : 0),
                medianIntervalHours: median(intervals), medianIntervalRatio: median(ratios),
                intervalCount: intervals.count, gracePercentage: grace
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let weight = taskRanking.reduce(0) { $0 + $1.totalWeight }
        let onTimeWeight = taskRanking.reduce(0) { $0 + $1.onTimeWeight }

        return CompletionStatistics(
            cycleCount: taskRanking.reduce(0) { $0 + $1.cycleCount },
            overdueCount: taskRanking.reduce(0) { $0 + $1.overdueCount },
            today: today,
            lastSevenDays: recent.count,
            total: completions.count,
            onTimeCount: taskRanking.reduce(0) { $0 + $1.onTimeCount },
            onTimeRate: weight == 0 ? nil : onTimeWeight / weight,
            daily: daily,
            taskRanking: taskRanking
        )
    }
}

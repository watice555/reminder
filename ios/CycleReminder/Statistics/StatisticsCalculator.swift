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
    let averageIntervalHours: Double?
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

enum StatisticsPeriod: Int, CaseIterable, Identifiable {
    case all = 0, week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
    var title: String { self == .all ? "创建以来" : "近 \(rawValue) 天" }
    var duration: TimeInterval { Double(rawValue) * 24 * 3600 }
    func window(endingAt end: Date) -> DateInterval? {
        self == .all ? nil : DateInterval(start: end.addingTimeInterval(-duration), end: end)
    }
}

enum StatisticsCalculator {
    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

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
        globalGrace: Double = 10,
        window: DateInterval? = nil,
        includeCurrentOverdue: Bool = true,
        minimumCompletions: Int = 0
    ) -> CompletionStatistics {
        func inWindow(_ date: Date) -> Bool {
            guard let window else { return date <= now }
            return date >= window.start && date < window.end && date <= now
        }
        let todayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let completions = tasks
            .flatMap(\.completions)
            .compactMap { record -> (record: CompletionRecord, completedAt: Date, dueAt: Date)? in
                guard
                    let completedAt = record.completedDate,
                    let dueAt = record.scheduledDueDate,
                    inWindow(completedAt)
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
            let history = task.completions.compactMap { $0.normalized() }.filter {
                ($0.completedDate ?? .distantFuture) <= now
            }.sorted { $0.completedDate! < $1.completedDate! }
            let valid = history.filter { inWindow($0.completedDate!) }
            let onTime = valid.filter {
                $0.completedDate! <= $0.scheduledDueDate!.addingTimeInterval($0.intervalHours * 3600 * grace / 100)
            }
            let overdue = includeCurrentOverdue && (task.nextDueDate.map {
                now > $0.addingTimeInterval(task.intervalHours * 3600 * grace / 100)
            } ?? false)
            let cycleCount = valid.count + (overdue ? 1 : 0)
            let pairs = zip(history, history.dropFirst()).filter { inWindow($0.1.completedDate!) }
            let intervals = pairs.map {
                $1.completedDate!.timeIntervalSince($0.completedDate!) / 3600
            }
            let ratios = zip(intervals, pairs).map { $0 / $1.1.intervalHours }
            return TaskCompletionRanking(
                taskID: task.id, name: task.name, total: valid.count,
                onTimeRate: cycleCount == 0 ? nil : Double(onTime.count) / Double(cycleCount),
                latestCompletedAt: valid.last?.completedDate,
                cycleCount: cycleCount, overdueCount: overdue ? 1 : 0,
                onTimeCount: onTime.count,
                onTimeWeight: onTime.reduce(0) { $0 + $1.intervalHours },
                totalWeight: valid.reduce(0) { $0 + $1.intervalHours } + (overdue ? task.intervalHours : 0),
                averageIntervalHours: average(intervals), medianIntervalRatio: median(ratios),
                intervalCount: intervals.count, gracePercentage: grace
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let eligible = taskRanking.filter { $0.total >= minimumCompletions }
        let weight = eligible.reduce(0) { $0 + $1.totalWeight }
        let onTimeWeight = eligible.reduce(0) { $0 + $1.onTimeWeight }

        return CompletionStatistics(
            cycleCount: eligible.reduce(0) { $0 + $1.cycleCount },
            overdueCount: eligible.reduce(0) { $0 + $1.overdueCount },
            today: today,
            lastSevenDays: recent.count,
            total: completions.count,
            onTimeCount: eligible.reduce(0) { $0 + $1.onTimeCount },
            onTimeRate: weight == 0 ? nil : onTimeWeight / weight,
            daily: daily,
            taskRanking: taskRanking
        )
    }
}

import XCTest
@testable import CycleReminder

final class CycleReminderTests: XCTestCase {
    private func legacyTask(completions: [CompletionRecord] = []) -> ReminderTask {
        ReminderTask(
            id: "task-1",
            name: "换滤芯",
            intervalHours: 48,
            lastCompletedAt: "2026-07-20T04:00:00.000Z",
            nextDueAt: "2026-07-22T04:00:00.000Z",
            createdAt: "2026-07-20T04:00:00.000Z",
            completions: completions
        )
    }

    func testLegacyBackupDoesNotInventCompletionHistory() throws {
        let json = #"[{"id":"task-1","name":"换滤芯","intervalHours":48,"lastCompletedAt":"2026-07-20T04:00:00.000Z","nextDueAt":"2026-07-22T04:00:00.000Z","createdAt":"2026-07-20T04:00:00.000Z"}]"#
        let tasks = try BackupCodec.decode(Data(json.utf8))

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].completions, [])
        XCTAssertEqual(tasks[0].reminders, [])
    }

    func testCompletingTaskSnapshotsOldDueDateAndInterval() throws {
        var task = legacyTask()
        let completedAt = try XCTUnwrap(ISODate.parse("2026-07-22T03:30:00.000Z"))

        task.complete(at: completedAt)

        XCTAssertEqual(task.completions.count, 1)
        XCTAssertEqual(task.completions[0].scheduledDueAt, "2026-07-22T04:00:00.000Z")
        XCTAssertEqual(task.completions[0].intervalHours, 48)
        XCTAssertEqual(task.lastCompletedAt, "2026-07-22T03:30:00.000Z")
        XCTAssertEqual(task.nextDueAt, "2026-07-24T03:30:00.000Z")
    }

    func testCreatingTaskCanUsePastCompletionAsUncountedCycleAnchor() throws {
        let now = try XCTUnwrap(ISODate.parse("2026-08-30T10:00:00.000Z"))
        let completedAt = try XCTUnwrap(ISODate.parse("2026-08-10T10:00:00.000Z"))

        let task = ReminderTask.create(
            name: "30 天循环",
            intervalHours: 30 * 24,
            lastCompletedAt: completedAt,
            now: now
        )

        XCTAssertEqual(task.createdAt, "2026-08-30T10:00:00.000Z")
        XCTAssertEqual(task.lastCompletedAt, "2026-08-10T10:00:00.000Z")
        XCTAssertEqual(task.nextDueAt, "2026-09-09T10:00:00.000Z")
        XCTAssertEqual(task.completions, [])
        XCTAssertEqual(StatisticsCalculator.calculate(tasks: [task], now: now).total, 0)
    }

    func testDefaultCreationStillUsesCreationTimeAsCycleAnchor() throws {
        let now = try XCTUnwrap(ISODate.parse("2026-08-30T10:00:00.000Z"))
        let task = ReminderTask.create(name: "默认任务", intervalHours: 48, now: now)

        XCTAssertEqual(task.lastCompletedAt, "2026-08-30T10:00:00.000Z")
        XCTAssertEqual(task.nextDueAt, "2026-09-01T10:00:00.000Z")
        XCTAssertEqual(task.completions, [])
    }

    func testBackfillUsesSelectedTimeAndSnapshotsPreviousDueDate() throws {
        var task = legacyTask()
        let now = try XCTUnwrap(ISODate.parse("2026-07-22T10:00:00.000Z"))
        let completedAt = try XCTUnwrap(ISODate.parse("2026-07-22T07:00:00.000Z"))

        XCTAssertTrue(task.backfill(at: completedAt, now: now))
        XCTAssertEqual(task.completions.count, 1)
        XCTAssertEqual(task.completions[0].completedAt, "2026-07-22T07:00:00.000Z")
        XCTAssertEqual(task.completions[0].scheduledDueAt, "2026-07-22T04:00:00.000Z")
        XCTAssertEqual(task.nextDueAt, "2026-07-24T07:00:00.000Z")
    }

    func testBackfillRejectsOutOfRangeDatesWithoutMutation() throws {
        let original = legacyTask()
        let now = try XCTUnwrap(ISODate.parse("2026-07-22T10:00:00.000Z"))
        let invalidDates = [
            "2026-07-20T04:00:00.000Z",
            "2026-07-20T03:59:00.000Z",
            "2026-07-22T10:01:00.000Z",
        ]

        for value in invalidDates {
            var task = original
            let date = try XCTUnwrap(ISODate.parse(value))
            XCTAssertFalse(task.backfill(at: date, now: now))
            XCTAssertEqual(task, original)
        }
    }

    func testCustomAnchorAndBackfillSurviveBackupAndRescheduleDueReminder() throws {
        let now = try XCTUnwrap(ISODate.parse("2026-08-30T10:00:00.000Z"))
        let initialCompletion = try XCTUnwrap(ISODate.parse("2026-08-10T10:00:00.000Z"))
        let backfillDate = try XCTUnwrap(ISODate.parse("2026-08-20T10:00:00.000Z"))
        var task = ReminderTask.create(
            name: "换滤芯",
            intervalHours: 30 * 24,
            reminders: [ReminderRule(id: "due", mode: .due)],
            lastCompletedAt: initialCompletion,
            now: now
        )
        XCTAssertTrue(task.backfill(at: backfillDate, now: now))

        let restored = try BackupCodec.decode(BackupCodec.encode([task], exportedAt: now))
        let plan = try XCTUnwrap(NotificationScheduler.plans(for: restored, now: now).first)

        XCTAssertEqual(restored, [task])
        XCTAssertEqual(plan.fireDate, task.nextDueDate)
        XCTAssertEqual(plan.fireDate, try XCTUnwrap(ISODate.parse("2026-09-19T10:00:00.000Z")))
    }

    func testBackupRoundTripPreservesCompletions() throws {
        let completion = CompletionRecord(
            id: "completion-1",
            completedAt: "2026-07-21T04:00:00.000Z",
            scheduledDueAt: "2026-07-21T05:00:00.000Z",
            intervalHours: 48
        )
        var task = legacyTask(completions: [completion])
        task.reminders = [
            ReminderRule(id: "due-rule", mode: .due),
            ReminderRule(id: "percent-rule", mode: .remainingPercentage, amount: 25),
        ]
        let data = try BackupCodec.encode(
            [task],
            exportedAt: try XCTUnwrap(ISODate.parse("2026-07-22T05:00:00.000Z"))
        )
        let tasks = try BackupCodec.decode(data)

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].completions, [completion])
        XCTAssertEqual(tasks[0].reminders, task.reminders)
    }

    func testImportFiltersMalformedTasksAndCompletionRecords() throws {
        let json = #"{"schemaVersion":2,"exportedAt":"2026-07-22T05:00:00.000Z","tasks":[{"id":"task-1","name":"换滤芯","intervalHours":48,"lastCompletedAt":"2026-07-20T04:00:00.000Z","nextDueAt":"2026-07-22T04:00:00.000Z","createdAt":"2026-07-20T04:00:00.000Z","completions":[{"id":"valid","completedAt":"2026-07-21T04:00:00.000Z","scheduledDueAt":"2026-07-21T05:00:00.000Z","intervalHours":48},{"id":"broken","completedAt":"not-a-date"}]},{"id":"bad-task","name":"","intervalHours":0,"lastCompletedAt":"bad","nextDueAt":"bad"}]}"#

        let tasks = try BackupCodec.decode(Data(json.utf8))

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].completions.map(\.id), ["valid"])
    }

    func testReminderRulesCalculateFireDatesFromCurrentCycle() throws {
        let dueDate = try XCTUnwrap(ISODate.parse("2026-07-22T12:00:00.000Z"))
        let dueRule = ReminderRule(id: "due", mode: .due)
        let percentageRule = ReminderRule(id: "percentage", mode: .remainingPercentage, amount: 25)
        let timeRule = ReminderRule(id: "time", mode: .remainingTime, amount: 5.5)

        XCTAssertEqual(
            dueRule.fireDate(dueDate: dueDate, intervalHours: 48),
            dueDate
        )
        XCTAssertEqual(
            percentageRule.fireDate(dueDate: dueDate, intervalHours: 48),
            dueDate.addingTimeInterval(-12 * 3_600)
        )
        XCTAssertEqual(
            timeRule.fireDate(dueDate: dueDate, intervalHours: 48),
            dueDate.addingTimeInterval(-5.5 * 3_600)
        )
    }

    func testInvalidReminderThresholdsAreFilteredDuringImport() throws {
        let json = #"{"schemaVersion":3,"exportedAt":"2026-07-22T05:00:00.000Z","tasks":[{"id":"task-1","name":"换滤芯","intervalHours":48,"lastCompletedAt":"2026-07-20T04:00:00.000Z","nextDueAt":"2026-07-22T04:00:00.000Z","createdAt":"2026-07-20T04:00:00.000Z","reminders":[{"id":"due","mode":"due"},{"id":"percentage","mode":"remainingPercentage","amount":20},{"id":"bad-percentage","mode":"remainingPercentage","amount":100},{"id":"bad-time","mode":"remainingTime","amount":48},{"id":"bad-mode","mode":"somethingElse","amount":1}]}]}"#

        let tasks = try BackupCodec.decode(Data(json.utf8))

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].reminders.map(\.id), ["due", "percentage"])
    }

    func testNotificationPlansSkipPastRulesAndKeepNearestSystemLimit() throws {
        let now = try XCTUnwrap(ISODate.parse("2026-07-22T12:00:00.000Z"))
        let tasks = (0..<70).map { index in
            let dueDate = now.addingTimeInterval(Double(index + 1) * 3_600)
            return ReminderTask(
                id: "task-\(index)",
                name: "任务 \(index)",
                intervalHours: 48,
                lastCompletedAt: ISODate.string(from: now.addingTimeInterval(-47 * 3_600)),
                nextDueAt: ISODate.string(from: dueDate),
                createdAt: ISODate.string(from: now),
                reminders: [ReminderRule(id: "due", mode: .due)]
            )
        } + [
            ReminderTask(
                id: "past-task",
                name: "已过提醒点",
                intervalHours: 48,
                lastCompletedAt: ISODate.string(from: now.addingTimeInterval(-24 * 3_600)),
                nextDueAt: ISODate.string(from: now.addingTimeInterval(24 * 3_600)),
                createdAt: ISODate.string(from: now),
                reminders: [
                    ReminderRule(id: "past-rule", mode: .remainingTime, amount: 30),
                ]
            ),
        ]

        let plans = NotificationScheduler.plans(for: tasks, now: now)

        XCTAssertEqual(plans.count, NotificationScheduler.maximumPendingNotifications)
        XCTAssertEqual(plans.first?.taskID, "task-0")
        XCTAssertEqual(plans.last?.taskID, "task-63")
        XCTAssertFalse(plans.contains { $0.taskID == "past-task" })
    }

    func testStatisticsUseLocalCalendarDaysAndOnTimeRate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let records = [
            CompletionRecord(
                id: "today",
                completedAt: "2026-07-22T09:00:00.000Z",
                scheduledDueAt: "2026-07-22T10:00:00.000Z",
                intervalHours: 48
            ),
            CompletionRecord(
                id: "six-days",
                completedAt: "2026-07-16T08:00:00.000Z",
                scheduledDueAt: "2026-07-16T07:00:00.000Z",
                intervalHours: 48
            ),
            CompletionRecord(
                id: "seven-days",
                completedAt: "2026-07-15T08:00:00.000Z",
                scheduledDueAt: "2026-07-15T09:00:00.000Z",
                intervalHours: 48
            ),
        ]
        let now = try XCTUnwrap(ISODate.parse("2026-07-22T12:00:00.000Z"))

        var task = legacyTask(completions: records)
        task.nextDueAt = ISODate.string(from: now.addingTimeInterval(48 * 3600))
        let result = StatisticsCalculator.calculate(
            tasks: [task],
            now: now,
            calendar: calendar,
            globalGrace: 0
        )

        XCTAssertEqual(result.today, 1)
        XCTAssertEqual(result.lastSevenDays, 2)
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.onTimeCount, 2)
        XCTAssertEqual(result.onTimeRate, 2.0 / 3.0)
        XCTAssertEqual(result.daily.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(result.taskRanking.first?.total, 3)
    }

    private func hourDate(_ hours: Double) -> Date {
        Date(timeIntervalSince1970: 1_767_225_600 + hours * 3600)
    }

    private func timedTask(_ interval: Double, _ records: [(Double, Double, Double)] = [], due: Double = 1000) -> ReminderTask {
        var task = legacyTask(completions: records.enumerated().map { index, values in
            CompletionRecord(id: String(index), completedAt: ISODate.string(from: hourDate(values.0)),
                             scheduledDueAt: ISODate.string(from: hourDate(values.1)), intervalHours: values.2)
        })
        task.intervalHours = interval
        task.nextDueAt = ISODate.string(from: hourDate(due))
        return task
    }

    func testGraceBoundaryRecalculationAndZeroOverride() throws {
        var task = timedTask(100, [(110, 100, 100)], due: 210)
        func stats(_ hour: Double, _ grace: Double = 10) -> CompletionStatistics {
            StatisticsCalculator.calculate(tasks: [task], now: hourDate(hour), globalGrace: grace)
        }
        XCTAssertEqual(stats(220).onTimeRate, 1)
        XCTAssertEqual(stats(220.001).onTimeRate, 0.5)
        XCTAssertEqual(stats(900).cycleCount, 2)
        XCTAssertEqual(stats(220, 0).onTimeRate, 0)
        XCTAssertEqual(stats(220.001, 15).onTimeRate, 1)
        task.gracePercentage = 0
        XCTAssertEqual(stats(220, 100).onTimeRate, 0)
    }

    func testWeightedRateDoesNotDoubleCountOverdueCompletion() throws {
        let records: [(Double, Double, Double)] = (1...7).map { i in
            let completed = Double(i) * 24
            let due = completed - (i == 7 ? 3.0 : 0.0)
            return (completed, due, 24.0)
        }
        var daily = timedTask(24, records)
        daily.id = "daily"
        var weekly = timedTask(168, due: 168)
        let now = hourDate(216)
        let before = StatisticsCalculator.calculate(tasks: [daily, weekly], now: now)
        XCTAssertEqual(try XCTUnwrap(before.onTimeRate), 3.0 / 7.0, accuracy: 0.000001)
        XCTAssertEqual(before.cycleCount, 8)
        weekly.complete(at: now)
        let after = StatisticsCalculator.calculate(tasks: [daily, weekly], now: now)
        XCTAssertEqual(after.onTimeRate, before.onTimeRate)
        XCTAssertEqual(after.cycleCount, before.cycleCount)
        XCTAssertEqual(after.overdueCount, 0)
    }

    func testRealIntervalsUseHistoricalPlansAndExcludeFutureRecords() throws {
        let task = timedTask(300, [(24, 24, 24), (60, 60, 24), (108, 108, 48), (999, 999, 48)])
        let stats = StatisticsCalculator.calculate(tasks: [task], now: hourDate(200))
        let item = try XCTUnwrap(stats.taskRanking.first)
        XCTAssertEqual(item.total, 3)
        XCTAssertEqual(item.intervalCount, 2)
        XCTAssertEqual(item.medianIntervalHours, 42)
        XCTAssertEqual(item.medianIntervalRatio, 1.25)
        XCTAssertEqual(item.totalWeight, 96)
        let single = StatisticsCalculator.calculate(tasks: [timedTask(24, [(24, 24, 24)])], now: hourDate(30))
        XCTAssertNil(single.taskRanking.first?.medianIntervalHours)
        XCTAssertNil(StatisticsCalculator.calculate(tasks: [timedTask(24)], now: hourDate(30)).onTimeRate)
    }

    func testGraceBackupAndRepositoryRoundTrip() throws {
        var task = timedTask(24)
        task.gracePercentage = 0
        let data = try BackupCodec.encode([task], gracePercentage: 15)
        XCTAssertEqual(BackupCodec.gracePercentage(from: data), 15)
        XCTAssertEqual(try BackupCodec.decode(data).first?.gracePercentage, 0)
        XCTAssertEqual(BackupCodec.gracePercentage(from: Data("[]".utf8)), 10)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONRepository(fileURL: directory.appendingPathComponent("tasks.json"))
        try repository.save([task], gracePercentage: 15)
        XCTAssertEqual(repository.loadGracePercentage(), 15)
        XCTAssertEqual(repository.load().first?.gracePercentage, 0)
        XCTAssertNil(StatisticsCalculator.validGrace(-1))
        XCTAssertNil(StatisticsCalculator.validGrace(.infinity))
    }
}

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
        XCTAssertEqual(item.averageIntervalHours, 42)
        XCTAssertEqual(item.medianIntervalRatio, 1.25)
        XCTAssertEqual(item.totalWeight, 96)
        let single = StatisticsCalculator.calculate(tasks: [timedTask(24, [(24, 24, 24)])], now: hourDate(30))
        XCTAssertNil(single.taskRanking.first?.averageIntervalHours)
        XCTAssertNil(StatisticsCalculator.calculate(tasks: [timedTask(24)], now: hourDate(30)).onTimeRate)
    }

    func testAverageIntervalsAndWindowBoundaryAttribution() throws {
        let task = timedTask(24, [(0, 0, 24), (6, 6, 24), (13, 13, 24), (33, 33, 24), (40, 40, 24)])
        let all = StatisticsCalculator.calculate(tasks: [task], now: hourDate(34))
        XCTAssertEqual(try XCTUnwrap(all.taskRanking.first?.averageIntervalHours), 11, accuracy: 0.000001)
        let window = DateInterval(start: hourDate(13), end: hourDate(40))
        let result = StatisticsCalculator.calculate(tasks: [task], now: hourDate(50), window: window,
                                                   includeCurrentOverdue: false)
        let item = try XCTUnwrap(result.taskRanking.first)
        XCTAssertEqual(item.total, 2)
        XCTAssertEqual(item.intervalCount, 2)
        XCTAssertEqual(item.averageIntervalHours, 13.5) // (7 + 20) / 2; first anchor is outside window.
        let previous = StatisticsCalculator.calculate(tasks: [task], now: hourDate(50),
            window: DateInterval(start: hourDate(-14), end: hourDate(13)), includeCurrentOverdue: false)
        XCTAssertEqual(previous.total, 2) // Completion at 13 belongs only to current window.
    }

    func testWindowMinimumSamplesAndCurrentOverdue() throws {
        var enough = timedTask(10, [(10, 10, 10), (20, 20, 10), (30, 30, 10)], due: 40)
        enough.id = "enough"
        var sparse = timedTask(100, [(15, 15, 100), (25, 25, 100)], due: 35)
        sparse.id = "sparse"
        let window = DateInterval(start: hourDate(0), end: hourDate(100))
        let current = StatisticsCalculator.calculate(tasks: [enough, sparse], now: hourDate(100),
            window: window, minimumCompletions: 3)
        XCTAssertEqual(current.onTimeRate, 0.75)
        XCTAssertEqual(current.cycleCount, 4)
        XCTAssertEqual(current.overdueCount, 1)
        XCTAssertEqual(current.taskRanking.count, 2) // Sparse task remains available for its placeholder.
        let previous = StatisticsCalculator.calculate(tasks: [enough, sparse], now: hourDate(100),
            window: window, includeCurrentOverdue: false, minimumCompletions: 3)
        XCTAssertEqual(previous.onTimeRate, 1)
        XCTAssertEqual(previous.overdueCount, 0)
        XCTAssertNil(StatisticsCalculator.calculate(tasks: [sparse], now: hourDate(100),
            window: window, minimumCompletions: 3).onTimeRate)
    }

    func testRollingPeriodsUseExactHoursAcrossDaylightSaving() throws {
        let end = try XCTUnwrap(ISODate.parse("2026-03-10T12:34:56Z"))
        for period in [StatisticsPeriod.week, .month, .quarter] {
            let current = try XCTUnwrap(period.window(endingAt: end))
            let previous = try XCTUnwrap(period.window(endingAt: current.start))
            XCTAssertEqual(current.duration, Double(period.rawValue) * 24 * 3600)
            XCTAssertEqual(previous.end, current.start)
            XCTAssertEqual(previous.duration, current.duration)
        }
        XCTAssertNil(StatisticsPeriod.all.window(endingAt: end))
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

final class WebDAVSyncTests: XCTestCase {
    private func task(_ id: String = "a", name: String = "任务") -> ReminderTask {
        var value = ReminderTask.create(name: name, intervalHours: 24, now: Date(timeIntervalSince1970: 1_700_000_000))
        value.id = id
        return value
    }
    private func snapshot(_ tasks: [ReminderTask], grace: Double = 10) -> SyncSnapshot {
        SyncSnapshot(tasks: tasks, gracePercentage: grace)
    }

    func testThreeWayMergePreservesIndependentEditsAndDeletion() throws {
        let a = task(), b = task("b"), c = task("c")
        var editedB = b
        editedB.name = "云端修改"
        let base = snapshot([a, b])
        let local = snapshot([b, c])
        let remote = snapshot([a, editedB])
        let merged = try SyncSnapshot.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.tasks, [editedB, c])
        XCTAssertEqual(try SyncSnapshot.merge(base: merged, local: merged, remote: merged), merged)
    }
    func testConflictingEditsAndDeleteVersusEditStopInsteadOfOverwrite() throws {
        let original = task()
        var left = original, right = original
        left.name = "左"
        right.name = "右"
        XCTAssertThrowsError(try SyncSnapshot.merge(base: snapshot([original]), local: snapshot([left]), remote: snapshot([right])))
        XCTAssertThrowsError(try SyncSnapshot.merge(base: snapshot([original]), local: snapshot([]), remote: snapshot([right])))
        XCTAssertThrowsError(try SyncSnapshot.merge(base: nil, local: snapshot([left]), remote: snapshot([right])))
    }
    func testFirstSyncUnionsTasksAndRequiresChoiceForDifferentSettings() throws {
        XCTAssertEqual(try SyncSnapshot.merge(base: nil, local: snapshot([task()]), remote: snapshot([task("b")])).tasks.count, 2)
        XCTAssertThrowsError(try SyncSnapshot.merge(base: nil, local: snapshot([]), remote: snapshot([], grace: 20)))
        XCTAssertEqual(try SyncSnapshot.merge(base: snapshot([]), local: snapshot([], grace: 30), remote: snapshot([])).gracePercentage, 30)
    }
    func testStrictRemoteDecodeRejectsDamageDuplicatesAndFutureSchema() throws {
        let valid = try snapshot([task()]).encoded()
        XCTAssertEqual(try SyncSnapshot.decode(valid), snapshot([task()]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["schemaVersion"] = 99
        XCTAssertThrowsError(try SyncSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 4
        var rows = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        object["tasks"] = [rows[0], rows[0]]
        XCTAssertThrowsError(try SyncSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        rows[0]["nextDueAt"] = "broken-date"
        object["tasks"] = rows
        XCTAssertThrowsError(try SyncSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        object["tasks"] = [["name": "broken"]]
        XCTAssertThrowsError(try SyncSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testBaselineAndTasksAreSavedTogetherAndBackupOmitsMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONRepository(fileURL: directory.appendingPathComponent("tasks.json"))
        let value = snapshot([task()])
        let baseline = SyncBaseline(identity: "test", snapshot: value, syncedAt: Date())
        try repository.save(value.tasks, gracePercentage: 10, syncBaseline: baseline)
        XCTAssertEqual(repository.load(), value.tasks)
        XCTAssertEqual(try repository.loadSyncBaseline()?.snapshot, value)
        let backup = try XCTUnwrap(String(data: value.encoded(), encoding: .utf8))
        XCTAssertFalse(backup.contains("syncBaseline"))
        try repository.saveRecovery(local: value, remote: snapshot([]))
        let files = try repository.recoveryFiles()
        XCTAssertEqual(files.count, 2)
        for file in files { XCTAssertNoThrow(try SyncSnapshot.decode(Data(contentsOf: file))) }
    }
    func testSettingsRequireHTTPSAndIdentityExcludesPassword() throws {
        var settings = WebDAVSettings(server: "https://dav.example/dav/", username: "user", password: "secret")
        XCTAssertEqual(try settings.baseURL().absoluteString, "https://dav.example/dav/CycleReminder/")
        let identity = settings.identity
        settings.password = "new-secret"
        XCTAssertEqual(settings.identity, identity)
        settings.username = "different"
        XCTAssertNotEqual(settings.identity, identity)
        for address in ["http://dav.example/dav/", "https://user:password@dav.example/", "https://dav.example/?secret=x"] {
            settings.server = address
            XCTAssertThrowsError(try settings.baseURL())
        }
    }

    private func client() -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebDAVStubProtocol.self]
        return WebDAVClient(settings: WebDAVSettings(server: "https://dav.example/dav/", username: "user", password: "secret"), session: URLSession(configuration: config))
    }
    override func tearDown() {
        WebDAVStubProtocol.handler = nil
        super.tearDown()
    }
    func testReadAuthenticatesAndRejectsErrorsRatherThanTreatingAsEmpty() async throws {
        let data = try snapshot([task()]).encoded()
        WebDAVStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpzZWNyZXQ=")
            return (200, ["ETag": "\"v1\""], data)
        }
        let value = try await client().read()
        XCTAssertEqual(value.etag, "\"v1\"")
        XCTAssertEqual(value.snapshot?.tasks.count, 1)
        WebDAVStubProtocol.handler = { _ in (401, [:], Data()) }
        do { _ = try await client().read(); XCTFail("must fail") } catch {}
        WebDAVStubProtocol.handler = { _ in (404, [:], Data()) }
        let missing = try await client().read()
        XCTAssertNil(missing.snapshot)
    }
    func testWriteUsesConditionalHeadersAndRejectsStaleETag() async throws {
        let value = snapshot([task()])
        WebDAVStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            return (201, [:], Data())
        }
        try await client().write(value, replacing: WebDAVRemote(snapshot: nil, etag: nil))
        WebDAVStubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"v1\"")
            return (412, [:], Data())
        }
        do {
            try await client().write(value, replacing: WebDAVRemote(snapshot: value, etag: "\"v1\""))
            XCTFail("stale version must fail")
        } catch {}
        WebDAVStubProtocol.handler = { _ in XCTFail("missing/weak ETag must not send PUT"); return (200, [:], Data()) }
        for tag in [nil, "W/\"weak\""] as [String?] {
            do { try await client().write(value, replacing: WebDAVRemote(snapshot: value, etag: tag)); XCTFail("must fail") } catch {}
        }
    }
    func testSafetyProbeRejectsServersThatIgnoreConditionsAndCleansUp() async throws {
        var deleted = false
        WebDAVStubProtocol.handler = { request in
            XCTAssertFalse(request.url!.lastPathComponent == "sync-v1.json")
            if request.httpMethod == "MKCOL" { return (405, [:], Data()) }
            if request.httpMethod == "DELETE" { deleted = true; return (204, [:], Data()) }
            return (201, [:], Data())
        }
        do { try await client().testWriteSafety(); XCTFail("unsafe server must fail") } catch {}
        XCTAssertTrue(deleted)
    }
    @MainActor
    func testStorePreservesEditsMadeWhileUploadIsInFlight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONRepository(fileURL: directory.appendingPathComponent("tasks.json"))
        let initial = task()
        try repository.save([initial])
        let settings = WebDAVSettings(server: "https://dav.example/dav/", username: "user", password: "secret")
        let store = ReminderStore(repository: repository, loadWebDAVSettings: { settings }, makeWebDAVClient: { _ in self.client() })
        var probePuts = 0
        WebDAVStubProtocol.handler = { request in
            if request.httpMethod == "GET" { return (404, [:], Data()) }
            if request.httpMethod == "MKCOL" { return (201, [:], Data()) }
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            if request.url!.lastPathComponent == "sync-v1.json" {
                await MainActor.run {
                    store.update(id: initial.id, name: "上传期间修改", intervalHours: 24, reminders: [])
                }
                return (201, [:], Data())
            }
            probePuts += 1
            return (probePuts == 1 ? 201 : 412, [:], Data())
        }
        await store.synchronizeWebDAV()
        XCTAssertEqual(store.tasks.first?.name, "上传期间修改")
        XCTAssertEqual(repository.load().first?.name, "上传期间修改")
        XCTAssertEqual(try repository.loadSyncBaseline()?.snapshot.tasks.first?.name, initial.name)
        XCTAssertEqual(store.syncStatus, "已同步，新的本机修改待上传")
    }

    @MainActor
    func testStoreConflictConfirmationRejectsChangedRemote() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONRepository(fileURL: directory.appendingPathComponent("tasks.json"))
        try repository.save([task(name: "本机")])
        let settings = WebDAVSettings(server: "https://dav.example/dav/", username: "user", password: "secret")
        let store = ReminderStore(repository: repository, loadWebDAVSettings: { settings }, makeWebDAVClient: { _ in self.client() })
        let remote = try snapshot([task(name: "云端")]).encoded()
        WebDAVStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["ETag": "\"v1\""], remote)
        }
        await store.synchronizeWebDAV()
        XCTAssertNotNil(store.syncConflict)
        XCTAssertEqual(store.tasks.first?.name, "本机")
        let changed = try snapshot([task(name: "云端再次修改")]).encoded()
        WebDAVStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["ETag": "\"v2\""], changed)
        }
        await store.synchronizeWebDAV(resolution: .local)
        XCTAssertTrue(store.syncStatus.contains("冲突内容已变化"))
        XCTAssertEqual(repository.load().first?.name, "本机")
    }

    @MainActor
    func testAutomaticSyncDoesNotCancelItsOwnNetworkRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONRepository(fileURL: directory.appendingPathComponent("tasks.json"))
        let value = snapshot([task()])
        try repository.save(value.tasks)
        let settings = WebDAVSettings(server: "https://dav.example/dav/", username: "user", password: "secret", automatic: true)
        let store = ReminderStore(repository: repository, loadWebDAVSettings: { settings }, makeWebDAVClient: { _ in self.client() })
        let remote = try value.encoded()
        WebDAVStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["ETag": "\"v1\""], remote)
        }
        store.scheduleAutomaticSync()
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if store.lastSyncedAt != nil { break }
        }
        XCTAssertEqual(store.syncStatus, "同步成功")
        XCTAssertNotNil(store.lastSyncedAt)
        store.pauseAutomaticSync()
    }

    @MainActor
    func testStoreDownloadsRemoteDeletionAndPersistsBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONRepository(fileURL: directory.appendingPathComponent("tasks.json"))
        let value = snapshot([task()])
        let settings = WebDAVSettings(server: "https://dav.example/dav/", username: "user", password: "secret")
        try repository.save(value.tasks, syncBaseline: SyncBaseline(identity: settings.identity, snapshot: value, syncedAt: Date()))
        let store = ReminderStore(repository: repository, loadWebDAVSettings: { settings }, makeWebDAVClient: { _ in self.client() })
        let remote = try snapshot([]).encoded()
        WebDAVStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["ETag": "\"v2\""], remote)
        }
        await store.synchronizeWebDAV()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(repository.load().isEmpty)
        XCTAssertEqual(try repository.loadSyncBaseline()?.snapshot.tasks.count, 0)
        XCTAssertEqual(try repository.recoveryFiles().count, 2)
        XCTAssertEqual(store.syncStatus, "同步成功")
    }

    func testProbeDistinguishesRateLimitPermissionAndServerErrors() async throws {
        for (status, expected) in [(429, "限流"), (403, "权限"), (503, "暂时异常")] {
            var puts = 0
            var deleted = false
            WebDAVStubProtocol.handler = { request in
                if request.httpMethod == "MKCOL" { return (405, [:], Data()) }
                if request.httpMethod == "DELETE" { deleted = true; return (204, [:], Data()) }
                puts += 1
                return (puts == 1 ? 201 : status, ["Retry-After": "60", "X-Private": "do-not-display"], Data("private response".utf8))
            }
            do { try await client().testWriteSafety(); XCTFail("must fail") }
            catch {
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(expected))
                XCTAssertTrue(message.contains("HTTP \(status)"))
                XCTAssertTrue(message.contains("60 秒"))
                XCTAssertFalse(message.contains("接受了应被拒绝"))
                XCTAssertFalse(message.contains("private response"))
                XCTAssertFalse(message.contains("do-not-display"))
            }
            XCTAssertEqual(puts, 2, "stop further probes after a transient/auth error")
            XCTAssertTrue(deleted)
        }
    }

    func testProbePreservesFailureAndCleanupDiagnostics() async throws {
        var puts = 0, deletes = 0
        WebDAVStubProtocol.handler = { request in
            if request.httpMethod == "MKCOL" { return (405, [:], Data()) }
            if request.httpMethod == "DELETE" { deletes += 1; return (503, [:], Data()) }
            puts += 1
            return (201, [:], Data())
        }
        do { try await client().testWriteSafety(); XCTFail("must fail") }
        catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("If-None-Match 返回 HTTP 201"))
            XCTAssertTrue(message.contains("If-Match）：HTTP 201"))
            XCTAssertTrue(message.contains("清理测试文件：HTTP 503"))
            XCTAssertTrue(message.contains("临时文件清理未完成"))
            XCTAssertTrue(message.contains("正式任务文件未写入"))
        }
        XCTAssertEqual(deletes, 1, "do not immediately retry failed cleanup")
    }

    func testProbeTimeoutReportsStageWithoutLeakingURL() async throws {
        var puts = 0
        WebDAVStubProtocol.handler = { request in
            if request.httpMethod == "MKCOL" { return (405, [:], Data()) }
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            puts += 1
            if puts > 1 { throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "private-url-and-password"]) }
            return (201, [:], Data())
        }
        do { try await client().testWriteSafety(); XCTFail("must fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("网络超时"))
            XCTAssertTrue(error.localizedDescription.contains("If-None-Match"))
            XCTAssertFalse(error.localizedDescription.contains("private-url-and-password"))
            XCTAssertFalse(error.localizedDescription.contains("接受了应被拒绝"))
        }
    }

    func testNutstoreStyleCreationUsesVerifiedMoveAndPreservesRaceWinner() async throws {
        for race in [false, true] {
            var probePuts = 0, probeMoves = 0
            var destinations: [String] = []
            WebDAVStubProtocol.handler = { request in
                let name = request.url!.lastPathComponent
                if request.httpMethod == "MKCOL" { return (405, [:], Data()) }
                if request.httpMethod == "DELETE" {
                    XCTAssertNotEqual(name, "sync-v1.json")
                    return (204, [:], Data())
                }
                if request.httpMethod == "MOVE" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F")
                    let target = request.value(forHTTPHeaderField: "Destination")!
                    destinations.append(target)
                    if target.hasSuffix("sync-v1.json") { return (race ? 412 : 201, [:], Data()) }
                    probeMoves += 1
                    return (probeMoves == 1 ? 412 : 201, [:], Data())
                }
                XCTAssertNotEqual(name, "sync-v1.json", "never PUT the shared file on fallback creation")
                if name.hasPrefix("upload-") || name.hasPrefix("probe-move-") { return (201, [:], Data()) }
                probePuts += 1
                return (probePuts == 1 ? 201 : (probePuts == 2 ? 204 : 412), [:], Data())
            }
            let service = client()
            let report = try await service.testWriteSafety()
            XCTAssertTrue(report.contains("MOVE + Overwrite: F"))
            do {
                try await service.write(snapshot([task()]), replacing: WebDAVRemote(snapshot: nil, etag: nil))
                XCTAssertFalse(race)
            } catch { XCTAssertTrue(race) }
            XCTAssertEqual(destinations.count, 3)
        }
    }

    func testUnsafeMoveFallbackIsRejected() async throws {
        var puts = 0
        WebDAVStubProtocol.handler = { request in
            if request.httpMethod == "MKCOL" { return (405, [:], Data()) }
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            if request.httpMethod == "MOVE" { return (204, [:], Data()) }
            puts += 1
            return (puts == 3 ? 412 : 201, [:], Data())
        }
        do { try await client().testWriteSafety(); XCTFail("must reject unsafe MOVE") }
        catch { XCTAssertTrue(error.localizedDescription.contains("忽略 MOVE")) }
    }

    func testSafetyProbeAcceptsConditionalServer() async throws {
        var puts = 0
        WebDAVStubProtocol.handler = { request in
            switch request.httpMethod {
            case "MKCOL": return (201, [:], Data())
            case "PUT":
                puts += 1
                return (puts == 1 ? 201 : 412, [:], Data())
            case "DELETE": return (204, [:], Data())
            default: XCTFail("unexpected request"); return (500, [:], Data())
            }
        }
        try await client().testWriteSafety()
        XCTAssertEqual(puts, 3)
    }
}

private final class WebDAVStubProtocol: URLProtocol {
    static var handler: ((URLRequest) async throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
        do {
            let (status, headers, data) = try await Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

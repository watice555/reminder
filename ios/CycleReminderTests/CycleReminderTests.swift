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

    func testBackupRoundTripPreservesCompletions() throws {
        let completion = CompletionRecord(
            id: "completion-1",
            completedAt: "2026-07-21T04:00:00.000Z",
            scheduledDueAt: "2026-07-21T05:00:00.000Z",
            intervalHours: 48
        )
        let data = try BackupCodec.encode(
            [legacyTask(completions: [completion])],
            exportedAt: try XCTUnwrap(ISODate.parse("2026-07-22T05:00:00.000Z"))
        )
        let tasks = try BackupCodec.decode(data)

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].completions, [completion])
    }

    func testImportFiltersMalformedTasksAndCompletionRecords() throws {
        let json = #"{"schemaVersion":2,"exportedAt":"2026-07-22T05:00:00.000Z","tasks":[{"id":"task-1","name":"换滤芯","intervalHours":48,"lastCompletedAt":"2026-07-20T04:00:00.000Z","nextDueAt":"2026-07-22T04:00:00.000Z","createdAt":"2026-07-20T04:00:00.000Z","completions":[{"id":"valid","completedAt":"2026-07-21T04:00:00.000Z","scheduledDueAt":"2026-07-21T05:00:00.000Z","intervalHours":48},{"id":"broken","completedAt":"not-a-date"}]},{"id":"bad-task","name":"","intervalHours":0,"lastCompletedAt":"bad","nextDueAt":"bad"}]}"#

        let tasks = try BackupCodec.decode(Data(json.utf8))

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].completions.map(\.id), ["valid"])
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

        let result = StatisticsCalculator.calculate(
            tasks: [legacyTask(completions: records)],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.today, 1)
        XCTAssertEqual(result.lastSevenDays, 2)
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.onTimeCount, 2)
        XCTAssertEqual(result.onTimeRate, 2.0 / 3.0)
        XCTAssertEqual(result.daily.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(result.taskRanking.first?.total, 3)
    }
}

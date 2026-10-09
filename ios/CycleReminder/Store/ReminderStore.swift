import Foundation

@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var tasks: [ReminderTask]
    @Published private(set) var gracePercentage: Double
    @Published var errorMessage: String?

    private let repository: JSONRepository
    private let notificationScheduler: NotificationScheduler
    private var notificationSyncTask: Task<Void, Never>?

    init(
        repository: JSONRepository = JSONRepository(),
        notificationScheduler: NotificationScheduler = NotificationScheduler()
    ) {
        self.repository = repository
        self.notificationScheduler = notificationScheduler
        let loadedTasks = repository.load()
        tasks = loadedTasks
        gracePercentage = repository.loadGracePercentage()
        synchronizeNotifications(requestAuthorization: false)
    }

    var sortedTasks: [ReminderTask] {
        tasks.sorted {
            ($0.nextDueDate ?? .distantFuture) < ($1.nextDueDate ?? .distantFuture)
        }
    }

    func create(
        name: String,
        intervalHours: Double,
        reminders: [ReminderRule],
        lastCompletedAt: Date? = nil,
        gracePercentage: Double? = nil,
        now: Date = Date()
    ) {
        if let lastCompletedAt, lastCompletedAt > now {
            errorMessage = "自定义上次完成时间不能晚于当前时间。"
            return
        }

        tasks.insert(
            ReminderTask.create(
                name: name,
                intervalHours: intervalHours,
                reminders: reminders,
                lastCompletedAt: lastCompletedAt,
                now: now
            ),
            at: 0
        )
        tasks[0].gracePercentage = StatisticsCalculator.validGrace(gracePercentage)
        persist()
        synchronizeNotifications(requestAuthorization: !reminders.isEmpty)
    }

    func update(id: String, name: String, intervalHours: Double, reminders: [ReminderRule], gracePercentage: Double? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].gracePercentage = StatisticsCalculator.validGrace(gracePercentage)
        tasks[index].update(name: name, intervalHours: intervalHours, reminders: reminders)
        persist()
        synchronizeNotifications(requestAuthorization: !reminders.isEmpty)
    }

    func complete(id: String, at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].complete(at: date)
        persist()
        synchronizeNotifications(requestAuthorization: false)
    }

    @discardableResult
    func backfill(id: String, at date: Date, now: Date = Date()) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard tasks[index].backfill(at: date, now: now) else {
            errorMessage = "补记时间必须晚于上次完成时间，且不能晚于当前时间。"
            return false
        }
        persist()
        synchronizeNotifications(requestAuthorization: false)
        return true
    }

    func delete(id: String) {
        tasks.removeAll { $0.id == id }
        persist()
        synchronizeNotifications(requestAuthorization: false)
    }

    func replace(with importedTasks: [ReminderTask], gracePercentage: Double = 10) {
        self.gracePercentage = StatisticsCalculator.validGrace(gracePercentage) ?? 10
        var seenIDs = Set<String>()
        tasks = importedTasks
            .compactMap { $0.normalized() }
            .filter { seenIDs.insert($0.id).inserted }
        persist()
        synchronizeNotifications(requestAuthorization: tasks.contains { !$0.reminders.isEmpty })
    }

    func setGracePercentage(_ value: Double) {
        guard let value = StatisticsCalculator.validGrace(value) else { return }
        gracePercentage = value
        persist()
    }

    func refreshNotifications() {
        synchronizeNotifications(requestAuthorization: false)
    }

    private func persist() {
        do {
            try repository.save(tasks, gracePercentage: gracePercentage)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func synchronizeNotifications(requestAuthorization: Bool) {
        let previousTask = notificationSyncTask
        let snapshot = tasks
        let scheduler = notificationScheduler

        notificationSyncTask = Task { [weak self] in
            await previousTask?.value
            do {
                try await scheduler.synchronize(
                    tasks: snapshot,
                    requestAuthorization: requestAuthorization
                )
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}

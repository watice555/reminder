import Foundation

@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var tasks: [ReminderTask]
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
        synchronizeNotifications(requestAuthorization: false)
    }

    var sortedTasks: [ReminderTask] {
        tasks.sorted {
            ($0.nextDueDate ?? .distantFuture) < ($1.nextDueDate ?? .distantFuture)
        }
    }

    func create(name: String, intervalHours: Double, reminders: [ReminderRule]) {
        tasks.insert(
            ReminderTask.create(name: name, intervalHours: intervalHours, reminders: reminders),
            at: 0
        )
        persist()
        synchronizeNotifications(requestAuthorization: !reminders.isEmpty)
    }

    func update(id: String, name: String, intervalHours: Double, reminders: [ReminderRule]) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
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

    func delete(id: String) {
        tasks.removeAll { $0.id == id }
        persist()
        synchronizeNotifications(requestAuthorization: false)
    }

    func replace(with importedTasks: [ReminderTask]) {
        var seenIDs = Set<String>()
        tasks = importedTasks
            .compactMap { $0.normalized() }
            .filter { seenIDs.insert($0.id).inserted }
        persist()
        synchronizeNotifications(requestAuthorization: tasks.contains { !$0.reminders.isEmpty })
    }

    func refreshNotifications() {
        synchronizeNotifications(requestAuthorization: false)
    }

    private func persist() {
        do {
            try repository.save(tasks)
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

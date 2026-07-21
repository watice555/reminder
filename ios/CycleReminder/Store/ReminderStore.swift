import Foundation

@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var tasks: [ReminderTask]
    @Published var errorMessage: String?

    private let repository: JSONRepository

    init(repository: JSONRepository = JSONRepository()) {
        self.repository = repository
        tasks = repository.load()
    }

    var sortedTasks: [ReminderTask] {
        tasks.sorted {
            ($0.nextDueDate ?? .distantFuture) < ($1.nextDueDate ?? .distantFuture)
        }
    }

    func create(name: String, intervalHours: Double) {
        tasks.insert(ReminderTask.create(name: name, intervalHours: intervalHours), at: 0)
        persist()
    }

    func update(id: String, name: String, intervalHours: Double) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].update(name: name, intervalHours: intervalHours)
        persist()
    }

    func complete(id: String, at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].complete(at: date)
        persist()
    }

    func delete(id: String) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    func replace(with importedTasks: [ReminderTask]) {
        var seenIDs = Set<String>()
        tasks = importedTasks
            .compactMap { $0.normalized() }
            .filter { seenIDs.insert($0.id).inserted }
        persist()
    }

    private func persist() {
        do {
            try repository.save(tasks)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

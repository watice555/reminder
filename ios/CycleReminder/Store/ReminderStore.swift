import Foundation

@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var tasks: [ReminderTask]
    @Published private(set) var gracePercentage: Double
    @Published var errorMessage: String?

    @Published private(set) var webDAVSettings: WebDAVSettings?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncStatus = "尚未配置 WebDAV"
    @Published private(set) var syncConflict: String?
    @Published private(set) var lastSyncedAt: Date?
    private var syncBaseline: SyncBaseline?
    private var baselineLoadFailed = false
    private var conflictRemote: SyncSnapshot?
    private var conflictLocal: SyncSnapshot?
    private var editRevision = 0
    private var automaticSyncTask: Task<Void, Never>?
    private var lastAutomaticAttempt = Date.distantPast

    private let repository: JSONRepository
    private let makeWebDAVClient: (WebDAVSettings) -> WebDAVClient
    private let notificationScheduler: NotificationScheduler
    private var notificationSyncTask: Task<Void, Never>?

    init(
        repository: JSONRepository = JSONRepository(),
        notificationScheduler: NotificationScheduler = NotificationScheduler(),
        loadWebDAVSettings: () throws -> WebDAVSettings? = WebDAVKeychain.load,
        makeWebDAVClient: @escaping (WebDAVSettings) -> WebDAVClient = { WebDAVClient(settings: $0) }
    ) {
        self.makeWebDAVClient = makeWebDAVClient
        self.repository = repository
        self.notificationScheduler = notificationScheduler
        let loadedTasks = repository.load()
        tasks = loadedTasks
        gracePercentage = repository.loadGracePercentage()
        do {
            syncBaseline = try repository.loadSyncBaseline()
            lastSyncedAt = syncBaseline?.syncedAt
        } catch {
            baselineLoadFailed = true
            syncStatus = "读取同步状态失败：\(error.localizedDescription)"
        }
        do {
            webDAVSettings = try loadWebDAVSettings()
            if webDAVSettings != nil, !baselineLoadFailed { syncStatus = "已配置，等待同步" }
        } catch { syncStatus = "读取 WebDAV 配置失败：\(error.localizedDescription)" }
        if webDAVSettings?.identity != syncBaseline?.identity { lastSyncedAt = nil }
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
        editRevision += 1
        clearSyncConflict()
        do {
            try repository.save(tasks, gracePercentage: gracePercentage, syncBaseline: syncBaseline)
            scheduleAutomaticSync()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }


    func syncRecoveryFiles() throws -> [URL] { try repository.recoveryFiles() }

    private var snapshot: SyncSnapshot { SyncSnapshot(tasks: tasks, gracePercentage: gracePercentage) }

    func saveWebDAVSettings(_ settings: WebDAVSettings) throws {
        guard !isSyncing else { throw WebDAVError.message("请等待当前同步完成。") }
        _ = try settings.baseURL()
        try WebDAVKeychain.save(settings)
        automaticSyncTask?.cancel()
        webDAVSettings = settings
        clearSyncConflict()
        lastSyncedAt = syncBaseline?.identity == settings.identity ? syncBaseline?.syncedAt : nil
        syncStatus = "配置已保存，请测试连接或立即同步"
        // Saving credentials does not upload data; the first sync is explicit.
    }

    func disconnectWebDAV() throws {
        guard !isSyncing else { throw WebDAVError.message("请等待当前同步完成。") }
        try WebDAVKeychain.remove()
        automaticSyncTask?.cancel()
        webDAVSettings = nil
        lastSyncedAt = nil
        clearSyncConflict()
        syncStatus = "已断开，本机和云端数据均保留"
    }

    private func clearSyncConflict() {
        syncConflict = nil
        conflictLocal = nil
        conflictRemote = nil
    }

    func scheduleAutomaticSync() {
        automaticSyncTask?.cancel()
        guard webDAVSettings?.automatic == true, syncConflict == nil else { return }
        let delay = max(5, 60 - Date().timeIntervalSince(lastAutomaticAttempt))
        automaticSyncTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.lastAutomaticAttempt = Date()
            // Detach the scheduled handle before sync cancels other pending schedules.
            self.automaticSyncTask = nil
            await self.synchronizeWebDAV()
        }
    }

    func pauseAutomaticSync() { automaticSyncTask?.cancel() }

    func testWebDAV() async {
        guard !isSyncing, let settings = webDAVSettings else { return }
        isSyncing = true
        syncStatus = "正在检查连接和读写权限…"
        defer { isSyncing = false }
        do {
            let client = makeWebDAVClient(settings)
            try await client.testWriteSafety()
            syncStatus = "连接、读写和防覆盖检查通过"
        } catch { syncStatus = "连接测试失败：\(error.localizedDescription)" }
    }

    enum SyncResolution { case local, remote }

    func synchronizeWebDAV(resolution: SyncResolution? = nil) async {
        guard !isSyncing, let settings = webDAVSettings else { return }
        guard !baselineLoadFailed else {
            syncStatus = "本机同步状态读取失败，请先重启应用；仍失败时请导出备份后排查。"
            return
        }
        automaticSyncTask?.cancel()
        lastAutomaticAttempt = Date()
        let local = snapshot
        let revision = editRevision
        let expectedRemote = conflictRemote
        let expectedLocal = conflictLocal
        isSyncing = true
        syncStatus = "正在同步…"
        defer { isSyncing = false }
        do {
            let client = makeWebDAVClient(settings)
            let remote = try await client.read()
            let base = syncBaseline?.identity == settings.identity ? syncBaseline?.snapshot : nil
            let merged: SyncSnapshot
            if let resolution {
                guard local == expectedLocal, remote.snapshot == expectedRemote else {
                    clearSyncConflict()
                    throw WebDAVError.message("冲突内容已变化，请重新同步并确认。")
                }
                merged = resolution == .local ? local : (remote.snapshot ?? local)
            } else if let remoteSnapshot = remote.snapshot {
                do { merged = try SyncSnapshot.merge(base: base, local: local, remote: remoteSnapshot) }
                catch {
                    syncConflict = error.localizedDescription
                    conflictLocal = local
                    conflictRemote = remoteSnapshot
                    syncStatus = "存在冲突，请到 WebDAV 同步设置中处理"
                    return
                }
            } else {
                guard base == nil else {
                    throw WebDAVError.message("原有云端同步文件已丢失，已停止上传。请恢复云端 CycleReminder/sync-v1.json 后重试。")
                }
                merged = local
            }
            // Preserve both versions before applying any remote changes or explicit overwrite.
            if let remoteSnapshot = remote.snapshot, remoteSnapshot != local {
                try repository.saveRecovery(local: local, remote: remoteSnapshot)
            }
            if remote.snapshot != merged {
                try await client.testWriteSafety()
                guard editRevision == revision else { throw WebDAVError.message("同步期间本机有新修改，请再次同步。") }
                try await client.write(merged, replacing: remote)
            }
            // Edits can occur while PUT is in flight. Three-way merge preserves those edits too.
            let applied: SyncSnapshot
            if editRevision == revision { applied = merged }
            else {
                applied = try SyncSnapshot.merge(base: local, local: snapshot, remote: merged)
            }
            let baseline = SyncBaseline(identity: settings.identity, snapshot: merged, syncedAt: Date())
            try repository.save(applied.tasks, gracePercentage: applied.gracePercentage, syncBaseline: baseline)
            tasks = applied.tasks
            gracePercentage = applied.gracePercentage
            syncBaseline = baseline
            lastSyncedAt = baseline.syncedAt
            clearSyncConflict()
            syncStatus = applied == merged ? "同步成功" : "已同步，新的本机修改待上传"
            synchronizeNotifications(requestAuthorization: false)
            if applied != merged { scheduleAutomaticSync() }
        } catch {
            syncStatus = "同步未完成：\(error.localizedDescription)"
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

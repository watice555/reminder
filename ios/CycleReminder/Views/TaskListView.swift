import SwiftUI
import UniformTypeIdentifiers

private struct EditorContext: Identifiable {
    let id = UUID()
    let task: ReminderTask?
}

private struct BackfillContext: Identifiable {
    let id = UUID()
    let task: ReminderTask
}

private struct BackfillCompletionView: View {
    let task: ReminderTask
    let onConfirm: (Date) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var completedAt: Date
    @State private var showConfirmation = false

    private let earliestDate: Date?
    private let latestDate: Date

    init(task: ReminderTask, onConfirm: @escaping (Date) -> Bool) {
        self.task = task
        self.onConfirm = onConfirm
        let latest = ReminderDate.floorToMinute(Date())
        earliestDate = task.lastCompletedDate.map { ReminderDate.floorToMinute($0).addingTimeInterval(60) }
        latestDate = latest
        _completedAt = State(initialValue: latest)
    }

    private var hasAvailableMinute: Bool {
        earliestDate.map { $0 <= latestDate } ?? true
    }

    private var nextDueDate: Date {
        completedAt.addingTimeInterval(task.intervalHours * 3_600)
    }

    private var isReverse: Bool { task.kind == .reverse }
    private var dateLabel: String { isReverse ? "实际发生时间" : "实际完成时间" }
    private var title: String { isReverse ? "补记发生" : "补记完成" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.name)
                        .font(.headline)

                    if let earliestDate, hasAvailableMinute {
                        DatePicker(
                            dateLabel,
                            selection: $completedAt,
                            in: earliestDate...latestDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        Text(
                            "可选择 \(DisplayFormat.dateTime(earliestDate)) 至 " +
                            "\(DisplayFormat.dateTime(latestDate))。"
                        )
                        .font(.caption)
                        .foregroundStyle(AppPalette.muted)
                    } else if earliestDate == nil {
                        DatePicker(dateLabel, selection: $completedAt, in: ...latestDate,
                                   displayedComponents: [.date, .hourAndMinute])
                    } else {
                        Text("当前周期还没有可补记的分钟。")
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续") {
                        showConfirmation = true
                    }
                    .disabled(!hasAvailableMinute)
                }
            }
            .alert("确认\(title)", isPresented: $showConfirmation) {
                Button("确认补记") {
                    let preciseDate = ReminderDate.floorToMinute(completedAt)
                    if onConfirm(preciseDate) {
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                let boundary = isReverse ? "最短间隔结束" : "下次到期"
                let note = task.isTooEarly(at: ReminderDate.floorToMinute(completedAt))
                    ? "这次发生时尚未满最短间隔，将计为提前。"
                    : "确认后将新增 1 条记录，并按这个时间重排提醒。"
                Text("\(dateLabel)：\(DisplayFormat.dateTime(completedAt))\n" +
                     "\(boundary)：\(DisplayFormat.dateTime(nextDueDate))\n\n\(note)")
            }
        }
    }
}

struct TaskListView: View {
    @EnvironmentObject private var store: ReminderStore

    @State private var editor: EditorContext?
    @State private var backfillContext: BackfillContext?
    @State private var taskToDelete: ReminderTask?
    @State private var showWebDAV = false
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: BackupDocument?
    @State private var exportFilename = "循环提醒-备份"
    @State private var pendingGracePercentage: Double = 10
    @State private var pendingImportedTasks: [ReminderTask] = []
    @State private var pendingSourceName: String?
    @State private var showImportConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                if store.sortedTasks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 42))
                            .foregroundStyle(AppPalette.muted)
                        Text("还没有任务")
                            .font(.headline)
                        Text("点击右上角 +，新增循环提醒或反向任务。")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(28)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.sortedTasks) { task in
                                TaskCardView(
                                    task: task,
                                    gracePercentage: task.gracePercentage ?? store.gracePercentage,
                                    onComplete: { store.complete(id: task.id, at: $0) },
                                    onBackfill: {
                                        backfillContext = BackfillContext(task: task)
                                    },
                                    onEdit: { editor = EditorContext(task: task) },
                                    onDelete: { taskToDelete = task }
                                )
                            }
                        }
                        .padding(16)
                    }
                    .id(store.activeProfile.id)
                }
            }
            .navigationTitle("循环提醒")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if store.activeProfile.isStandard {
                            Button { showWebDAV = true } label: {
                                Label("WebDAV 同步", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Divider()
                        }
                        Button {
                            prepareExport()
                        } label: {
                            Label("导出 JSON", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            isImporting = true
                        } label: {
                            Label("导入 JSON", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("备份", systemImage: "ellipsis.circle")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    ProfileMenu()
                    Button {
                        editor = EditorContext(task: nil)
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showWebDAV) { WebDAVSettingsView() }
        .sheet(item: $editor) { context in
            TaskEditorView(task: context.task) {
                name, intervalHours, reminders, lastCompletedAt, gracePercentage, kind in
                if let task = context.task {
                    store.update(
                        id: task.id,
                        name: name,
                        intervalHours: intervalHours,
                        reminders: reminders,
                        gracePercentage: gracePercentage
                    )
                } else {
                    store.create(
                        name: name,
                        intervalHours: intervalHours,
                        reminders: reminders,
                        lastCompletedAt: lastCompletedAt,
                        gracePercentage: gracePercentage,
                        kind: kind
                    )
                }
            }
        }
        .sheet(item: $backfillContext) { context in
            BackfillCompletionView(task: context.task) { completedAt in
                store.backfill(id: context.task.id, at: completedAt)
            }
        }
        .confirmationDialog(
            "删除“\(taskToDelete?.name ?? "这个任务")”？",
            isPresented: Binding(
                get: { taskToDelete != nil },
                set: { if !$0 { taskToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除任务和 \(taskToDelete?.completions.count ?? 0) 条记录", role: .destructive) {
                guard let task = taskToDelete else { return }
                store.delete(id: task.id)
                taskToDelete = nil
            }
            Button("取消", role: .cancel) { taskToDelete = nil }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                store.errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .alert("导入备份", isPresented: $showImportConfirmation) {
            Button("替换当前 Profile", role: .destructive) {
                store.replace(with: pendingImportedTasks, gracePercentage: pendingGracePercentage)
                pendingImportedTasks = []
            }
            Button("取消", role: .cancel) { pendingImportedTasks = [] }
        } message: {
            let completions = pendingImportedTasks.reduce(0) { $0 + $1.completions.count }
            let source = pendingSourceName.map { "备份来源「\($0)」。\n" } ?? ""
            Text("\(source)将用 \(pendingImportedTasks.count) 个任务和 \(completions) 条记录替换「\(store.activeProfile.name)」的数据，并将该 Profile 的统计宽限设为 \(DisplayFormat.number(pendingGracePercentage))%。")
        }
    }

    private func prepareExport() {
        do {
            let name = store.activeProfile.name
            exportDocument = try BackupDocument(tasks: store.tasks, gracePercentage: store.gracePercentage, profileName: name)
            let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
            let safeName = String(name.components(separatedBy: invalid).joined(separator: "-").unicodeScalars.prefix(40))
            let stamp = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current))
                .replacingOccurrences(of: ":", with: "-")
            exportFilename = "循环提醒-\(safeName)-\(stamp)"
            isExporting = true
        } catch {
            store.errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            pendingImportedTasks = try BackupCodec.decode(data)
            pendingGracePercentage = BackupCodec.gracePercentage(from: data)
            pendingSourceName = BackupCodec.profileName(from: data)
            showImportConfirmation = true
        } catch {
            store.errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

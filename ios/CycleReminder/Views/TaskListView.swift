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

    private let earliestDate: Date
    private let latestDate: Date

    init(task: ReminderTask, onConfirm: @escaping (Date) -> Bool) {
        self.task = task
        self.onConfirm = onConfirm
        let latest = ReminderDate.floorToMinute(Date())
        let lastCompletedAt = task.lastCompletedDate ?? latest
        let earliest = ReminderDate.floorToMinute(lastCompletedAt).addingTimeInterval(60)
        earliestDate = earliest
        latestDate = latest
        _completedAt = State(initialValue: latest)
    }

    private var hasAvailableMinute: Bool {
        earliestDate <= latestDate
    }

    private var nextDueDate: Date {
        completedAt.addingTimeInterval(task.intervalHours * 3_600)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.name)
                        .font(.headline)

                    if hasAvailableMinute {
                        DatePicker(
                            "实际完成时间",
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
                    } else {
                        Text("当前周期还没有可补记的分钟。")
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
            .navigationTitle("补记完成")
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
            .alert("确认补记完成", isPresented: $showConfirmation) {
                Button("确认补记") {
                    let preciseDate = ReminderDate.floorToMinute(completedAt)
                    if onConfirm(preciseDate) {
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    "完成时间：\(DisplayFormat.dateTime(completedAt))\n" +
                    "下次到期：\(DisplayFormat.dateTime(nextDueDate))\n\n" +
                    "确认后将新增 1 条完成记录，并按这个时间重排后续提醒。"
                )
            }
        }
    }
}

struct TaskListView: View {
    @EnvironmentObject private var store: ReminderStore

    @State private var editor: EditorContext?
    @State private var backfillContext: BackfillContext?
    @State private var taskToDelete: ReminderTask?
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: BackupDocument?
    @State private var pendingImportedTasks: [ReminderTask] = []
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
                        Text("新增一个任务，例如“换滤芯”，设置 2 天循环。")
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
                                    onComplete: { store.complete(id: task.id) },
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
                }
            }
            .navigationTitle("循环提醒")
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("\(store.tasks.count) 个任务保存在本机")
                        .font(.caption)
                        .foregroundStyle(AppPalette.muted)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(AppPalette.background)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
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

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = EditorContext(task: nil)
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $editor) { context in
            TaskEditorView(task: context.task) {
                name, intervalHours, reminders, lastCompletedAt in
                if let task = context.task {
                    store.update(
                        id: task.id,
                        name: name,
                        intervalHours: intervalHours,
                        reminders: reminders
                    )
                } else {
                    store.create(
                        name: name,
                        intervalHours: intervalHours,
                        reminders: reminders,
                        lastCompletedAt: lastCompletedAt
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
            Button("删除任务和 \(taskToDelete?.completions.count ?? 0) 条完成记录", role: .destructive) {
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
            defaultFilename: "循环提醒-备份"
        ) { result in
            if case .failure(let error) = result {
                store.errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .alert("导入备份", isPresented: $showImportConfirmation) {
            Button("替换当前数据", role: .destructive) {
                store.replace(with: pendingImportedTasks)
                pendingImportedTasks = []
            }
            Button("取消", role: .cancel) { pendingImportedTasks = [] }
        } message: {
            let completions = pendingImportedTasks.reduce(0) { $0 + $1.completions.count }
            Text("将用 \(pendingImportedTasks.count) 个任务和 \(completions) 条完成记录替换当前数据。")
        }
    }

    private func prepareExport() {
        do {
            exportDocument = try BackupDocument(tasks: store.tasks)
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
            showImportConfirmation = true
        } catch {
            store.errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

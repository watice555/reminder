import SwiftUI
import UniformTypeIdentifiers

private struct EditorContext: Identifiable {
    let id = UUID()
    let task: ReminderTask?
}

struct TaskListView: View {
    @EnvironmentObject private var store: ReminderStore

    @State private var editor: EditorContext?
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
            TaskEditorView(task: context.task) { name, intervalHours, reminders in
                if let task = context.task {
                    store.update(
                        id: task.id,
                        name: name,
                        intervalHours: intervalHours,
                        reminders: reminders
                    )
                } else {
                    store.create(name: name, intervalHours: intervalHours, reminders: reminders)
                }
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

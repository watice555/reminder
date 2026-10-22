import SwiftUI

struct WebDAVSettingsView: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings = WebDAVSettings()
    @State private var message: String?
    @State private var resolution: ReminderStore.SyncResolution?
    @State private var confirmResolution = false
    @State private var showRecoveryExporter = false
    @State private var recoveryFiles: [URL] = []

    private var hasUnsavedChanges: Bool { settings != store.webDAVSettings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("WebDAV 服务器地址", text: $settings.server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("账号（邮箱）", text: $settings.username)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("应用密码", text: $settings.password)
                    Toggle("自动同步", isOn: $settings.automatic)
                    Button("保存配置") {
                        do {
                            settings.server = settings.server.trimmingCharacters(in: .whitespacesAndNewlines)
                            settings.username = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
                            try store.saveWebDAVSettings(settings)
                        } catch { message = error.localizedDescription }
                    }
                } header: { Text("WebDAV") } footer: {
                    Text("坚果云请使用第三方应用密码。配置保存在本机钥匙串，不随 JSON 备份导出。同步目录：CycleReminder/sync-v1.json。自动同步在回到前台和修改后执行，至少间隔约一分钟。")
                }
                Section {
                    Button("测试连接与读写") { Task { await store.testWebDAV() } }
                    Button("立即同步") { Task { await store.synchronizeWebDAV() } }
                } footer: {
                    Text(hasUnsavedChanges ? "请先保存配置。" : "连接测试会创建并删除临时测试文件。首次同步合并两端任务；有冲突时会暂停，请确认后再继续。")
                }
                .disabled(hasUnsavedChanges || store.webDAVSettings == nil)
                Section("同步状态") {
                    if store.isSyncing { ProgressView() }
                    Text(store.syncStatus).textSelection(.enabled)
                    if let date = store.lastSyncedAt {
                        Text("上次成功：\(DisplayFormat.dateTime(date))").foregroundStyle(.secondary)
                    }
                }
                if let conflict = store.syncConflict {
                    Section {
                        Text(conflict)
                        Button("使用本机全部数据", role: .destructive) {
                            resolution = .local; confirmResolution = true
                        }
                        Button("使用云端全部数据", role: .destructive) {
                            resolution = .remote; confirmResolution = true
                        }
                    } header: { Text("处理冲突") } footer: {
                        Text("选择会整体替换另一端，包括任务、完成记录和全局宽限。操作前会在本机保存两端恢复副本。也可以取消，先导出备份并手动调整任务后再同步。")
                    }
                }
                Section {
                    Button("导出最近恢复副本") {
                        do {
                            recoveryFiles = try store.syncRecoveryFiles()
                            if recoveryFiles.isEmpty { message = "暂无恢复副本。" }
                            else { showRecoveryExporter = true }
                        } catch { message = error.localizedDescription }
                    }
                    Button("断开 WebDAV", role: .destructive) {
                        do { try store.disconnectWebDAV(); settings = WebDAVSettings() }
                        catch { message = error.localizedDescription }
                    }.disabled(store.webDAVSettings == nil)
                } footer: { Text("断开仅移除连接配置，保留本机和云端任务。") }
            }
            .disabled(store.isSyncing)
            .navigationTitle("WebDAV 同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showRecoveryExporter) {
                NavigationStack {
                    List(recoveryFiles, id: \.self) { url in
                        ShareLink(item: url) {
                            Text(url.lastPathComponent).font(.caption)
                        }
                    }
                    .navigationTitle("同步恢复副本")
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showRecoveryExporter = false }
                    } }
                }
            }
            .onAppear { settings = store.webDAVSettings ?? WebDAVSettings() }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .alert("确认整体替换", isPresented: $confirmResolution) {
                Button("确认替换", role: .destructive) {
                    if let resolution { Task { await store.synchronizeWebDAV(resolution: resolution) } }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(resolution == .local ? "将以本机全部数据替换云端数据。" : "将以云端全部数据替换本机数据。")
            }
        }
    }
}

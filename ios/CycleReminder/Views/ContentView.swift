import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ReminderStore

    var body: some View {
        TabView {
            TaskListView()
                .tabItem {
                    Label("任务", systemImage: "checklist")
                }

            StatisticsView()
                .tabItem {
                    Label("统计", systemImage: "chart.bar.xaxis")
                }
        }
        .tint(AppPalette.green)
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "未知错误")
        }
    }
}

struct ProfileMenu: View {
    @EnvironmentObject private var store: ReminderStore
    @State private var profileToRename: ReminderProfile?
    @State private var profileToDelete: ReminderProfile?
    @State private var name = ""
    @State private var editingName = false

    var body: some View {
        Menu {
            Picker("切换 Profile", selection: Binding(
                get: { store.activeProfile.id },
                set: { id in
                    if let profile = store.profileSelection.profiles.first(where: { $0.id == id }) {
                        store.selectProfile(profile)
                    }
                }
            )) {
                ForEach(store.profileSelection.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            Divider()
            Button {
                profileToRename = nil
                name = ""
                editingName = true
            } label: {
                Label("新增 Profile", systemImage: "plus")
            }
            Button {
                profileToRename = store.activeProfile
                name = store.activeProfile.name
                editingName = true
            } label: {
                Label("重命名当前 Profile", systemImage: "pencil")
            }
            if !store.activeProfile.isStandard {
                Button(role: .destructive) { profileToDelete = store.activeProfile } label: {
                    Label("删除当前 Profile", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.activeProfile.name).lineLimit(1).frame(maxWidth: 110)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .accessibilityLabel("当前 Profile，\(store.activeProfile.name)")
        .alert(profileToRename == nil ? "新增 Profile" : "重命名 Profile", isPresented: $editingName) {
            TextField("名称", text: $name)
            Button("保存") { _ = store.saveProfile(name: name, id: profileToRename?.id) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
        .alert(
            "删除“\(profileToDelete?.name ?? "")”？",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            presenting: profileToDelete
        ) { profile in
            Button("删除 Profile", role: .destructive) { store.deleteProfile(profile) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("此 Profile 的所有任务、历史记录和提醒都会被删除。")
        }
    }
}

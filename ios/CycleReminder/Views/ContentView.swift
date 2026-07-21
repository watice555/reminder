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

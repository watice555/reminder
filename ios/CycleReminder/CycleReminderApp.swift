import SwiftUI
import UserNotifications

@main
struct CycleReminderApp: App {
    @StateObject private var store = ReminderStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresentationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                store.refreshNotifications()
            }
        }
    }
}

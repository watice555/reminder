import Foundation
import UserNotifications

struct ScheduledNotificationPlan: Equatable {
    let identifier: String
    let taskID: String
    let title: String
    let body: String
    let fireDate: Date
}

enum NotificationSchedulerError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "系统通知权限未开启。请在“设置 → 通知 → 循环提醒”中允许通知。"
        }
    }
}

actor NotificationScheduler {
    static let identifierPrefix = "cycle-reminder."
    static let maximumPendingNotifications = 64

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func synchronize(tasks: [ReminderTask], requestAuthorization: Bool) async throws {
        let pending = await center.pendingNotificationRequests()
        let managedIdentifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: managedIdentifiers)

        let settings = await center.notificationSettings()
        var status = settings.authorizationStatus
        if status == .notDetermined, requestAuthorization {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            status = granted ? .authorized : .denied
        }

        switch status {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            if requestAuthorization {
                throw NotificationSchedulerError.authorizationDenied
            }
            return
        case .notDetermined:
            return
        @unknown default:
            return
        }

        for plan in Self.plans(for: tasks) {
            let timeInterval = plan.fireDate.timeIntervalSinceNow
            guard timeInterval > 0 else { continue }

            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.userInfo = ["taskID": plan.taskID]

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, timeInterval),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: plan.identifier,
                content: content,
                trigger: trigger
            )
            try await center.add(request)
        }
    }

    static func plans(for tasks: [ReminderTask], now: Date = Date()) -> [ScheduledNotificationPlan] {
        tasks
            .flatMap { task -> [ScheduledNotificationPlan] in
                guard let dueDate = task.nextDueDate else { return [] }

                return task.reminders.compactMap { rule in
                    guard
                        let fireDate = rule.fireDate(dueDate: dueDate, intervalHours: task.intervalHours),
                        fireDate > now
                    else {
                        return nil
                    }

                    return ScheduledNotificationPlan(
                        identifier: identifier(taskID: task.id, ruleID: rule.id),
                        taskID: task.id,
                        title: task.name,
                        body: notificationBody(for: rule, dueDate: dueDate),
                        fireDate: fireDate
                    )
                }
            }
            .sorted {
                if $0.fireDate == $1.fireDate {
                    return $0.identifier < $1.identifier
                }
                return $0.fireDate < $1.fireDate
            }
            .prefix(maximumPendingNotifications)
            .map { $0 }
    }

    private static func identifier(taskID: String, ruleID: String) -> String {
        "\(identifierPrefix)\(taskID).\(ruleID)"
    }

    private static func notificationBody(for rule: ReminderRule, dueDate: Date) -> String {
        let dueText = DisplayFormat.dateTime(dueDate)
        switch rule.mode {
        case .due:
            return "任务已到期，请完成后重置。"
        case .remainingPercentage:
            return "距离到期还剩 \(DisplayFormat.number(rule.amount))%，到期时间 \(dueText)。"
        case .remainingTime:
            return "距离到期还剩 \(DisplayFormat.interval(rule.amount))，到期时间 \(dueText)。"
        }
    }
}

final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresentationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

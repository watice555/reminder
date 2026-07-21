import SwiftUI

struct TaskCardView: View {
    let task: ReminderTask
    let onComplete: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(at: context.date)
        }
    }

    @ViewBuilder
    private func card(at now: Date) -> some View {
        let dueDate = task.nextDueDate ?? now
        let remaining = dueDate.timeIntervalSince(now)
        let overdue = remaining <= 0
        let intervalSeconds = task.intervalHours * 3_600
        let elapsed = now.timeIntervalSince(task.lastCompletedDate ?? now)
        let progress = min(1, max(0, elapsed / intervalSeconds))

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name)
                        .font(.headline)
                        .foregroundStyle(AppPalette.ink)
                    Text("\(DisplayFormat.interval(task.intervalHours))循环")
                        .font(.caption)
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                Text(overdue ? "已到期" : "进行中")
                    .font(.caption.bold())
                    .foregroundStyle(overdue ? AppPalette.red : AppPalette.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((overdue ? AppPalette.red : AppPalette.green).opacity(0.12))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(overdue ? "超时 \(DisplayFormat.duration(abs(remaining)))" : "剩余 \(DisplayFormat.duration(remaining))")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(overdue ? AppPalette.red : AppPalette.green)
                Text("下次到期：\(DisplayFormat.dateTime(task.nextDueDate))")
                Text("上次完成：\(DisplayFormat.dateTime(task.lastCompletedDate))")
                Text("累计完成 \(task.completions.count) 次")
                    .fontWeight(.bold)
                    .foregroundStyle(AppPalette.green)
            }
            .font(.caption)
            .foregroundStyle(AppPalette.muted)

            VStack(spacing: 7) {
                HStack {
                    Text("本轮进度")
                    Spacer()
                    Text("已过去 \(Int((progress * 100).rounded()))%")
                        .foregroundStyle(overdue ? AppPalette.red : AppPalette.green)
                }
                .font(.caption.bold())
                ProgressView(value: progress)
                    .tint(overdue ? AppPalette.red : AppPalette.green)
            }

            HStack(spacing: 8) {
                Button(action: onComplete) {
                    Text("完成并重置")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.green)

                Button("编辑", action: onEdit)
                    .buttonStyle(.bordered)
                    .tint(AppPalette.ink)

                Button("删除", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
            }
            .font(.subheadline.bold())
        }
        .padding(16)
        .background(Color.white)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(overdue ? AppPalette.red.opacity(0.65) : AppPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

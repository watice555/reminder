import SwiftUI

struct TaskCardView: View {
    let task: ReminderTask
    let gracePercentage: Double
    let onComplete: () -> Void
    let onBackfill: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showingDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(at: context.date)
        }
    }

    private func appearance(remaining: Double, interval: Double) -> (label: String, color: Color) {
        if remaining < -interval * gracePercentage / 100 { return ("已超宽限", AppPalette.red) }
        if remaining <= 0 { return ("已到期", AppPalette.orange) }
        if remaining <= interval * 0.2 { return ("即将到期", AppPalette.yellow) }
        if remaining <= interval * 0.5 { return ("进行中", AppPalette.teal) }
        return ("时间充裕", AppPalette.green)
    }

    private func card(at now: Date) -> some View {
        let remaining = (task.nextDueDate ?? now).timeIntervalSince(now)
        let interval = task.intervalHours * 3_600
        let progress = min(1, max(0, 1 - remaining / interval))
        let state = appearance(remaining: remaining, interval: interval)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.name)
                    .font(.headline)
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Menu {
                    Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
                    Button(action: onBackfill) { Label("补记完成", systemImage: "clock.arrow.circlepath") }
                    Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 44, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .tint(AppPalette.muted)
                .accessibilityLabel("\(task.name)的更多操作")
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(remaining <= 0
                         ? "超时 \(DisplayFormat.duration(abs(remaining)))"
                         : "剩余 \(DisplayFormat.duration(remaining))")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(state.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(state.label) · 每 \(DisplayFormat.interval(task.intervalHours))")
                        .font(.caption)
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onComplete) {
                    Label("完成", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(AppPalette.green)
                .fixedSize()
                .contextMenu {
                    Button(action: onBackfill) {
                        Label("补记完成", systemImage: "clock.arrow.circlepath")
                    }
                }
                .accessibilityHint("记录当前完成时间，并开始下一个周期。长按可补记完成")
                .accessibilityAction(named: Text("补记完成"), onBackfill)
            }

            ProgressView(value: progress)
                .tint(state.color)
                .accessibilityLabel("本轮进度")

            DisclosureGroup(isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("上次完成  \(DisplayFormat.dateTime(task.lastCompletedDate))")
                    Text("累计 \(task.completions.count) 次完成 · \(task.reminders.count) 条提醒")
                    Text("统计宽限 \(DisplayFormat.number(gracePercentage))%")
                    Text("绿：剩余 >50% · 青：20%–50% · 黄：≤20%\n橙：已到期且在宽限内 · 红：超出宽限")
                }
                .font(.caption)
                .foregroundStyle(AppPalette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                Text("\(DisplayFormat.dateTime(task.nextDueDate)) 到期")
                    .font(.caption)
                    .foregroundStyle(AppPalette.muted)
            }
            .tint(AppPalette.muted)
        }
        .padding(16)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}

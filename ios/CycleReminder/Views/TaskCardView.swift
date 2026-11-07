import SwiftUI

struct TaskCardView: View {
    let task: ReminderTask
    let gracePercentage: Double
    let onComplete: (Date) -> Void
    let onBackfill: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showingDetails = false
    @State private var earlyRecordAt: Date?

    private var isReverse: Bool { task.kind == .reverse }
    private var backfillTitle: String { isReverse ? "补记发生" : "补记完成" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(at: context.date)
        }
        .alert(
            "尚未满最短间隔",
            isPresented: Binding(
                get: { earlyRecordAt != nil },
                set: { if !$0 { earlyRecordAt = nil } }
            ),
            presenting: earlyRecordAt
        ) { date in
            Button("仍然记录") { onComplete(date) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这次会计为提前发生，并从这次发生的时间重新计算最短间隔。")
        }
    }

    private func appearance(remaining: Double, interval: Double) -> (label: String, color: Color) {
        if isReverse {
            if task.nextDueDate == nil { return ("尚未记录", AppPalette.muted) }
            if remaining <= 0 { return ("间隔已满", AppPalette.green) }
            if remaining <= interval * 0.2 { return ("即将满间隔", AppPalette.yellow) }
            if remaining <= interval * 0.5 { return ("等待中", AppPalette.orange) }
            return ("等待中", AppPalette.red)
        }
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
        let countdown = remaining > 0 ? "剩余 \(DisplayFormat.duration(remaining))"
            : "超时 \(DisplayFormat.duration(abs(remaining)))"
        let status = isReverse
            ? (task.nextDueDate == nil ? "可记录首次发生" : (remaining > 0 ? countdown : "可以再做"))
            : countdown
        let intervalText = DisplayFormat.interval(task.intervalHours)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.name)
                    .font(.headline)
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Menu {
                    Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
                    Button(action: onBackfill) { Label(backfillTitle, systemImage: "clock.arrow.circlepath") }
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
                    Text(status)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(state.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isReverse
                         ? "反向 · \(state.label) · 最短 \(intervalText)"
                         : "\(state.label) · 每 \(intervalText)")
                        .font(.caption)
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    let date = Date()
                    if task.isTooEarly(at: date) { earlyRecordAt = date }
                    else { onComplete(date) }
                } label: {
                    Label(isReverse ? "记录" : "完成", systemImage: isReverse ? "pencil" : "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(isReverse && remaining > 0 ? state.color : AppPalette.green)
                .fixedSize()
                .contextMenu {
                    Button(action: onBackfill) {
                        Label(backfillTitle, systemImage: "clock.arrow.circlepath")
                    }
                }
                .accessibilityHint(isReverse
                    ? "记录当前发生时间，并重新计算最短间隔。长按可补记发生"
                    : "记录当前完成时间，并开始下一个周期。长按可补记完成")
                .accessibilityAction(named: Text(backfillTitle), onBackfill)
            }

            if !isReverse || task.nextDueDate != nil {
                ProgressView(value: progress)
                    .tint(state.color)
                    .accessibilityLabel(isReverse ? "最短间隔进度" : "本轮进度")
            }

            DisclosureGroup(isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    if isReverse {
                        Text(task.lastCompletedDate.map { "上次发生  \(DisplayFormat.dateTime($0))" } ?? "尚无上次发生时间")
                        Text("累计记录 \(task.completions.count) 次 · \(task.reminders.isEmpty ? "间隔结束时不提醒" : "间隔结束时提醒")")
                        Text("红、橙、黄表示还需等待，绿色表示已满最短间隔。")
                    } else {
                        Text("上次完成  \(DisplayFormat.dateTime(task.lastCompletedDate))")
                        Text("累计 \(task.completions.count) 次完成 · \(task.reminders.count) 条提醒")
                        Text("统计宽限 \(DisplayFormat.number(gracePercentage))%")
                        Text("绿：剩余 >50% · 青：20%–50% · 黄：≤20%\n橙：已到期且在宽限内 · 红：超出宽限")
                    }
                }
                .font(.caption)
                .foregroundStyle(AppPalette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                Text(isReverse
                     ? (task.nextDueDate.map { "\(DisplayFormat.dateTime($0)) 满间隔" } ?? "记录后开始计时")
                     : "\(DisplayFormat.dateTime(task.nextDueDate)) 到期")
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

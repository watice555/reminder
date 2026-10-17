import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("statisticsPeriod") private var periodValue = 30
    private var period: StatisticsPeriod { StatisticsPeriod(rawValue: periodValue) ?? .month }
    @State private var showingSettings = false
    @State private var showingInfo = false
    @State private var expandedTasks: Set<String> = []

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let statistics = StatisticsCalculator.calculate(
                    tasks: store.tasks, now: context.date, globalGrace: store.gracePercentage,
                    window: period.window(endingAt: context.date), minimumCompletions: 3
                )
                let previous = period.window(endingAt: context.date.addingTimeInterval(-period.duration)).map {
                    StatisticsCalculator.calculate(tasks: store.tasks, now: context.date,
                        globalGrace: store.gracePercentage, window: $0,
                        includeCurrentOverdue: false, minimumCompletions: 3)
                }
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("总体准时率").font(.headline)
                                Button { showingInfo = true } label: {
                                    Image(systemName: "info.circle")
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                    .accessibilityLabel("统计说明")
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(rate(statistics.onTimeRate))
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .foregroundStyle(rateColor(statistics.onTimeRate))
                                if let previous, let change = rateChange(statistics.onTimeRate, previous.onTimeRate) {
                                    Text(change).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("\(period.title) · \(statistics.cycleCount) 个周期 · \(statistics.taskRanking.filter { $0.total >= 3 }.count) 个任务")
                                .font(.caption).foregroundStyle(.secondary)
                            if statistics.overdueCount > 0 {
                                overdueLabel(statistics.overdueCount)
                            }
                        }.padding(.vertical, 8)
                    }
                    Section {
                        if statistics.taskRanking.isEmpty {
                            Text("添加任务后，这里会显示统计。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(statistics.taskRanking) { item in
                            let old = previous?.taskRanking.first { $0.id == item.id && $0.total >= 3 }
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    if expandedTasks.contains(item.id) { expandedTasks.remove(item.id) }
                                    else { expandedTasks.insert(item.id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(item.name).font(.headline).foregroundStyle(.primary)
                                            Spacer()
                                            Text(item.total >= 3 ? rate(item.onTimeRate) : "样本不足").font(.body.weight(.semibold))
                                                .foregroundStyle(item.total >= 3 ? rateColor(item.onTimeRate) : .secondary)
                                            if item.total >= 3 {
                                                if let old, let change = rateChange(item.onTimeRate, old.onTimeRate) {
                                                    Text(change).font(.caption).foregroundStyle(.secondary)
                                                }
                                                Image(systemName: expandedTasks.contains(item.id) ? "chevron.up" : "chevron.down")
                                                    .font(.caption2).foregroundStyle(.tertiary)
                                            }
                                        }
                                        if item.total >= 3 {
                                            HStack {
                                                Text("平均间隔 \(interval(item.averageIntervalHours))")
                                                if let old, let change = intervalChange(item.averageIntervalHours, old.averageIntervalHours) {
                                                    Text(change).font(.caption)
                                                }
                                                Spacer(minLength: 4)
                                                Text(item.medianIntervalRatio.map { "计划比 \(rate($0))" } ?? "计划比 —")
                                            }.font(.subheadline).foregroundStyle(.secondary)
                                        } else {
                                            Text("完成 \(item.total)/3 次，可选择更长周期")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .disabled(item.total < 3)
                                    .accessibilityLabel(item.total >= 3 ? "\(item.name)，准时率 \(rate(item.onTimeRate))" : "\(item.name)，样本不足，完成 \(item.total) 次")
                                    .accessibilityHint(expandedTasks.contains(item.id) ? "收起详情" : "展开详情")
                                if expandedTasks.contains(item.id) && item.total >= 3 {
                                    if item.overdueCount > 0 { overdueLabel(item.overdueCount) }
                                    if previous != nil && old == nil { Text("前期样本不足，暂无对比") }
                                    if let old = previous?.taskRanking.first(where: { $0.id == item.id }), old.total >= 3 {
                                        Text("前期准时率 \(rate(old.onTimeRate)) · 平均间隔 \(interval(old.averageIntervalHours)) · 完成 \(old.total) 次")
                                    }
                                    Text("本期完成 \(item.total) 次")
                                    Text("\(item.cycleCount) 个周期 · 宽限 \(DisplayFormat.number(item.gracePercentage))%")
                                    Text(item.intervalCount == 0
                                         ? "至少两条完成记录才能计算间隔"
                                         : "间隔取算术平均数 · \(item.intervalCount) 组相邻完成记录")
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                    } header: {
                        HStack { Text("任务概览"); Spacer(); Text("准时率") }
                    }
                }
            }
            .navigationTitle("统计")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("统计周期", selection: $periodValue) {
                            ForEach(StatisticsPeriod.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(period.title)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }
                    .accessibilityLabel("统计周期，\(period.title)")
                    Button("设置") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) { StatisticsSettingsView() }
            .sheet(isPresented: $showingInfo) {
                NavigationStack {
                    List {
                        Section("准时率") {
                            Text("在计划到期时间加宽限内完成，算作准时。总体准时率按每个周期当时的计划间隔加权。")
                            Text("当前超出宽限的未完成周期计入一次不准时，完成后不重复计数。全部历史按当前宽限重算。")
                        }
                        Section("统计周期") {
                            Text("↑ / ↓ 表示相较前期的数值增减，→ 表示持平；准时率变化单位为百分点，间隔变化单位为天或小时。无可比数据时不显示箭头。")
                            Text("近 X 天为精确的 24 × X 小时，前期为紧邻的等长窗口。窗口含起点、不含终点，已完成周期按完成时间归属。")
                            Text("每个窗口中任务完成至少 3 次才显示指标并纳入总体；前后期都达标才显示任务变化。总体纳入的任务可能不同。")
                            Text("当前逾期未完成只计入本期，前期不补算历史未完成状态。创建以来仅使用已保存的真实记录。")
                        }
                        Section("间隔") {
                            Text("间隔取相邻真实完成记录的算术平均数，按后一次完成时间归入窗口，可使用窗口之前的完成记录作为起点；计划比取每组实际间隔与当时计划间隔之比的中位数。")
                        }
                        Section("颜色分档") {
                            Text("≥ 90% 绿色 · 80%–<90% 青绿色\n60%–<80% 橙黄色 · 40%–<60% 橙色\n< 40% 红色 · 无数据灰色")
                        }
                    }.navigationTitle("统计说明").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("完成") { showingInfo = false } }
                }
            }
        }.tint(rateColor(0.9))
    }

    private func rateChange(_ current: Double?, _ previous: Double?) -> String? {
        guard let current, let previous else { return nil }
        let delta = (current - previous) * 100
        if abs(delta) < 0.05 { return "→ 0 个百分点" }
        return "\(delta > 0 ? "↑" : "↓") \(DisplayFormat.number(abs(delta))) 个百分点"
    }

    private func intervalChange(_ current: Double?, _ previous: Double?) -> String? {
        guard let current, let previous else { return nil }
        let delta = current - previous
        if abs(delta) < 1.0 / 60 { return "→ 0 小时" }
        return "\(delta > 0 ? "↑" : "↓") \(interval(abs(delta)))"
    }

    private func overdueLabel(_ count: Int) -> some View {
        Text("\(count) 个逾期未完成").font(.caption).foregroundStyle(.secondary)
    }

    private func rateColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if colorScheme == .dark {
            switch value {
            case 0.9...: return Color(red: 0.40, green: 0.82, blue: 0.55)
            case 0.8...: return Color(red: 0.32, green: 0.80, blue: 0.78)
            case 0.6...: return Color(red: 0.94, green: 0.76, blue: 0.30)
            case 0.4...: return Color(red: 1.00, green: 0.62, blue: 0.30)
            default: return Color(red: 1.00, green: 0.48, blue: 0.48)
            }
        }
        switch value {
        case 0.9...: return Color(red: 0.13, green: 0.48, blue: 0.28)
        case 0.8...: return Color(red: 0.05, green: 0.48, blue: 0.47)
        case 0.6...: return Color(red: 0.57, green: 0.40, blue: 0.02)
        case 0.4...: return Color(red: 0.72, green: 0.32, blue: 0.06)
        default: return Color(red: 0.76, green: 0.22, blue: 0.22)
        }
    }

    private func rate(_ value: Double?) -> String {
        value.map { "\(($0 * 100).formatted(.number.precision(.fractionLength(0...1))))%" } ?? "—"
    }

    private func interval(_ hours: Double?) -> String {
        guard let hours else { return "—" }
        return hours >= 24
            ? "\(DisplayFormat.number(hours / 24)) 天"
            : "\(DisplayFormat.number(hours)) 小时"
    }
}

private struct StatisticsSettingsView: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var graceText = "10"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("全局宽限")
                        TextField("10", text: $graceText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("全局宽限百分比")
                        Text("%")
                    }
                } footer: {
                    Text("允许比计划间隔延迟的比例。任务单独配置优先；保存后重算历史，不改变到期或通知时间。")
                }
            }.navigationTitle("统计设置").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            guard let value = StatisticsCalculator.validGrace(Double(graceText)) else { return }
                            store.setGracePercentage(value)
                            dismiss()
                        }.disabled(StatisticsCalculator.validGrace(Double(graceText)) == nil)
                    }
                }
        }.onAppear { graceText = DisplayFormat.number(store.gracePercentage) }
    }

}

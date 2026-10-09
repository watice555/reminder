import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @State private var showingInfo = false
    @State private var expandedTasks: Set<String> = []

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let statistics = StatisticsCalculator.calculate(
                    tasks: store.tasks, now: context.date, globalGrace: store.gracePercentage
                )
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
                            Text(rate(statistics.onTimeRate))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(rateColor(statistics.onTimeRate))
                            Text("全部历史 · \(statistics.cycleCount) 个周期")
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
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    if expandedTasks.contains(item.id) { expandedTasks.remove(item.id) }
                                    else { expandedTasks.insert(item.id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(item.name).font(.headline).foregroundStyle(.primary)
                                            Spacer()
                                            Text(rate(item.onTimeRate)).font(.body.weight(.semibold))
                                                .foregroundStyle(rateColor(item.onTimeRate))
                                            Image(systemName: expandedTasks.contains(item.id) ? "chevron.up" : "chevron.down")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        HStack {
                                            Text("间隔 \(interval(item.medianIntervalHours))")
                                            Spacer()
                                            Text(item.medianIntervalRatio.map { "计划的 \(rate($0))" } ?? "计划比 —")
                                        }.font(.subheadline).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("\(item.name)，准时率 \(rate(item.onTimeRate))")
                                    .accessibilityHint(expandedTasks.contains(item.id) ? "收起详情" : "展开详情")
                                if item.overdueCount > 0 { overdueLabel(item.overdueCount) }
                                if expandedTasks.contains(item.id) {
                                    Text("\(item.cycleCount) 个周期 · 宽限 \(DisplayFormat.number(item.gracePercentage))%")
                                    Text(item.intervalCount == 0
                                         ? "至少两条完成记录才能计算间隔"
                                         : "间隔取中位数 · \(item.intervalCount) 组相邻完成记录")
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
                Button("设置") {
                    showingSettings = true
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
                        Section("间隔") {
                            Text("间隔取相邻真实完成记录的中位数；计划比取每组实际间隔与当时计划间隔之比的中位数。")
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

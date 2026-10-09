import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject private var store: ReminderStore
    @State private var graceText = ""

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let statistics = StatisticsCalculator.calculate(
                    tasks: store.tasks, now: context.date, globalGrace: store.gracePercentage
                )
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("加权准时率").font(.headline)
                            Text(rate(statistics.onTimeRate))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(AppPalette.green)
                            Text("基于 \(statistics.cycleCount) 个周期，其中 \(statistics.overdueCount) 个超出宽限未完成")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    } footer: {
                        Text("全部历史 · 按当前宽限重算。以每个周期当时的计划间隔加权；当前超出宽限的周期计入一次不准时，完成后不重复计数。")
                    }

                    Section {
                        HStack {
                            Text("全局宽限")
                            TextField("10", text: $graceText)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                .accessibilityLabel("全局宽限百分比")
                            Text("%")
                            Button("保存") {
                                guard let value = StatisticsCalculator.validGrace(Double(graceText)) else { return }
                                store.setGracePercentage(value)
                            }.disabled(StatisticsCalculator.validGrace(Double(graceText)) == nil)
                        }
                        if StatisticsCalculator.validGrace(Double(graceText)) == nil {
                            Text("请输入大于或等于 0 的百分比").foregroundStyle(AppPalette.red)
                        }
                    } footer: {
                        Text("允许比计划间隔延迟的比例。任务单独配置优先；修改后立即重算历史，不改变到期或通知时间。")
                    }

                    Section("任务概览") {
                        if statistics.taskRanking.isEmpty {
                            Text("添加任务后，这里会显示统计。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(statistics.taskRanking) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(item.name).font(.headline)
                                    Spacer()
                                    Text("准时率 \(rate(item.onTimeRate))").foregroundStyle(AppPalette.green)
                                }
                                Text("实际间隔中位数：\(interval(item.medianIntervalHours))")
                                Text("实际／计划间隔比：\(rate(item.medianIntervalRatio))")
                                Text("\(item.cycleCount) 个周期 · \(item.overdueCount) 个超出宽限未完成 · 宽限 \(DisplayFormat.number(item.gracePercentage))%")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(item.intervalCount == 0
                                     ? "至少两条真实完成记录才能计算间隔"
                                     : "间隔基于 \(item.intervalCount) 组相邻完成记录")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("统计")
        }
        .onAppear { graceText = DisplayFormat.number(store.gracePercentage) }
        .onChange(of: store.gracePercentage) { graceText = DisplayFormat.number($0) }
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

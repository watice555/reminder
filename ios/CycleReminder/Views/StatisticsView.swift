import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject private var store: ReminderStore

    private let metricColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let statistics = StatisticsCalculator.calculate(tasks: store.tasks, now: context.date)
                ScrollView {
                    VStack(spacing: 12) {
                        summary(statistics)
                        trend(statistics)
                        ranking(statistics)
                    }
                    .padding(16)
                }
                .background(AppPalette.background)
            }
            .navigationTitle("完成统计")
        }
    }

    @ViewBuilder
    private func summary(_ statistics: CompletionStatistics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("完成统计")
                    .font(.headline)
                Text(
                    statistics.total == 0
                        ? "统计从本次升级后开始；旧任务不会被伪造成完成记录。"
                        : "共记录 \(statistics.total) 次完成，准时 \(statistics.onTimeCount) 次。"
                )
                .font(.caption)
                .foregroundStyle(AppPalette.muted)
            }

            LazyVGrid(columns: metricColumns, spacing: 10) {
                MetricCard(title: "今天", value: "\(statistics.today)")
                MetricCard(title: "近 7 天", value: "\(statistics.lastSevenDays)")
                MetricCard(title: "累计完成", value: "\(statistics.total)")
                MetricCard(
                    title: "准时率",
                    value: statistics.onTimeRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
                )
            }
        }
        .panelStyle()
    }

    @ViewBuilder
    private func trend(_ statistics: CompletionStatistics) -> some View {
        let maximum = max(1, statistics.daily.map(\.count).max() ?? 1)

        VStack(alignment: .leading, spacing: 14) {
            Text("最近 7 天")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(statistics.daily) { item in
                    VStack(spacing: 6) {
                        Text("\(item.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(AppPalette.muted)
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppPalette.green)
                            .frame(height: max(3, CGFloat(item.count) / CGFloat(maximum) * 96))
                        Text(DisplayFormat.day(item.date))
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(DisplayFormat.day(item.date)) 完成 \(item.count) 次")
                }
            }
            .frame(height: 145)
        }
        .panelStyle()
    }

    @ViewBuilder
    private func ranking(_ statistics: CompletionStatistics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("任务排行")
                .font(.headline)
                .padding(.bottom, 10)

            if statistics.taskRanking.isEmpty {
                Text("完成一次任务后，这里会显示任务排行。")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(statistics.taskRanking.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(item.name)")
                                .font(.subheadline.bold())
                            Text("最近完成 \(DisplayFormat.dateTime(item.latestCompletedAt))")
                                .font(.caption)
                                .foregroundStyle(AppPalette.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(item.total) 次")
                                .font(.headline)
                                .foregroundStyle(AppPalette.green)
                            Text(item.onTimeRate.map { "准时 \(Int(($0 * 100).rounded()))%" } ?? "暂无准时率")
                                .font(.caption)
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .panelStyle()
    }
}

private struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(AppPalette.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(16)
            .background(Color.white)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

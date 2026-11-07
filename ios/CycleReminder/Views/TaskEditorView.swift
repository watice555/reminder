import SwiftUI

private struct ReminderDraft: Identifiable {
    let id: String
    var mode: ReminderMode
    var percentage: String
    var days: String
    var hours: String

    init(rule: ReminderRule, defaultRemainingHours: Double = 1) {
        id = rule.id
        mode = rule.mode
        percentage = rule.mode == .remainingPercentage
            ? DisplayFormat.number(rule.amount)
            : "20"

        let remainingHours = rule.mode == .remainingTime && rule.amount > 0
            ? rule.amount
            : defaultRemainingHours
        let dayValue = Int(remainingHours / 24)
        let hourValue = remainingHours - Double(dayValue * 24)
        days = dayValue > 0 ? String(dayValue) : ""
        hours = hourValue > 0 ? DisplayFormat.number(hourValue) : ""
    }

    func rule(intervalHours: Double) -> ReminderRule? {
        let amount: Double
        switch mode {
        case .due:
            amount = 0
        case .remainingPercentage:
            guard let value = Double(percentage.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            amount = value
        case .remainingTime:
            let dayText = days.trimmingCharacters(in: .whitespacesAndNewlines)
            let hourText = hours.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let dayValue = dayText.isEmpty ? 0 : Double(dayText),
                let hourValue = hourText.isEmpty ? 0 : Double(hourText),
                dayValue >= 0,
                hourValue >= 0
            else {
                return nil
            }
            amount = dayValue * 24 + hourValue
        }

        return ReminderRule(id: id, mode: mode, amount: amount)
            .normalized(intervalHours: intervalHours)
    }

    func validationMessage(intervalHours: Double?) -> String? {
        guard let intervalHours else { return nil }
        switch mode {
        case .due:
            return nil
        case .remainingPercentage:
            guard
                let value = Double(percentage.trimmingCharacters(in: .whitespacesAndNewlines)),
                value > 0,
                value < 100
            else {
                return "剩余百分比需大于 0 且小于 100。"
            }
        case .remainingTime:
            guard rule(intervalHours: intervalHours) != nil else {
                return "剩余时间需大于 0 且小于任务循环时间。"
            }
        }
        return nil
    }
}

private struct ReminderDraftRow: View {
    @Binding var draft: ReminderDraft
    let intervalHours: Double?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("提醒方式", selection: $draft.mode) {
                    ForEach(ReminderMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除这条提醒")
            }

            switch draft.mode {
            case .due:
                Text("任务到期时发送通知")
                    .font(.caption)
                    .foregroundStyle(AppPalette.muted)
            case .remainingPercentage:
                HStack {
                    Text("剩余")
                    TextField("20", text: $draft.percentage)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                }
            case .remainingTime:
                HStack {
                    Text("剩余")
                    TextField("0", text: $draft.days)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                    Text("天")
                    TextField("0", text: $draft.hours)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("小时")
                }
            }

            if let message = draft.validationMessage(intervalHours: intervalHours) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppPalette.red)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TaskEditorView: View {
    let task: ReminderTask?
    let onSave: (String, Double, [ReminderRule], Date?, Double?, ReminderKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ReminderKind
    @State private var notifyWhenReady: Bool
    @State private var customGrace: Bool
    @State private var graceText: String
    @State private var name: String
    @State private var days: String
    @State private var hours: String
    @State private var reminderDrafts: [ReminderDraft]
    @State private var advancedSettingsExpanded = false
    @State private var usesCustomInitialCompletion = false
    @State private var initialCompletedAt: Date
    @State private var showCustomCompletionConfirmation = false

    init(
        task: ReminderTask?,
        onSave: @escaping (String, Double, [ReminderRule], Date?, Double?, ReminderKind) -> Void
    ) {
        _kind = State(initialValue: task?.kind ?? .recurring)
        _notifyWhenReady = State(initialValue: task?.reminders.contains { $0.mode == .due } ?? true)
        _customGrace = State(initialValue: task?.gracePercentage != nil)
        _graceText = State(initialValue: DisplayFormat.number(task?.gracePercentage ?? 10))
        self.task = task
        self.onSave = onSave
        let interval = task?.intervalHours ?? 48
        let dayValue = Int(interval / 24)
        let hourValue = interval - Double(dayValue * 24)
        let initialRules = task?.reminders ?? [ReminderRule(mode: .due)]
        _name = State(initialValue: task?.name ?? "")
        _days = State(initialValue: dayValue > 0 ? String(dayValue) : "")
        _hours = State(initialValue: hourValue > 0 ? DisplayFormat.number(hourValue) : "")
        _reminderDrafts = State(
            initialValue: initialRules.map {
                ReminderDraft(rule: $0, defaultRemainingHours: max(0.25, interval / 2))
            }
        )
        _initialCompletedAt = State(initialValue: ReminderDate.floorToMinute(Date()))
    }

    private var isReverse: Bool { kind == .reverse }
    private var previousEvent: String { isReverse ? "上次发生" : "上次完成" }
    private var boundary: String { isReverse ? "最短间隔结束" : "下次到期" }

    private var intervalHours: Double? {
        let dayValue = days.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Double(days)
        let hourValue = hours.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Double(hours)
        guard
            let dayValue,
            let hourValue,
            dayValue >= 0,
            hourValue >= 0,
            dayValue * 24 + hourValue > 0,
            ((dayValue * 24 + hourValue) * 3_600).isFinite
        else {
            return nil
        }
        return dayValue * 24 + hourValue
    }

    private var reminderRules: [ReminderRule]? {
        guard let intervalHours else { return nil }
        if isReverse {
            guard notifyWhenReady else { return [] }
            return [task?.reminders.first { $0.mode == .due } ?? ReminderRule(mode: .due)]
        }
        let rules = reminderDrafts.compactMap { $0.rule(intervalHours: intervalHours) }
        return rules.count == reminderDrafts.count ? rules : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if task == nil {
                    Section {
                        Picker("任务类型", selection: $kind) {
                            ForEach(ReminderKind.allCases) { kind in Text(kind.title).tag(kind) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(isReverse
                             ? "每次发生后至少等满设定间隔。提前发生时也可以记录。"
                             : "按设定间隔完成任务，每次完成后开始新的循环。")
                    }
                }
                Section("任务名称") {
                    TextField(isReverse ? "例如：喝含糖饮料" : "例如：换滤芯", text: $name)
                        .textInputAutocapitalization(.never)
                }

                Section(isReverse ? "最短间隔" : "循环时间") {
                    HStack {
                        TextField("0", text: $days)
                            .keyboardType(.numberPad)
                        Text("天")
                            .foregroundStyle(AppPalette.muted)
                    }
                    HStack {
                        TextField("0", text: $hours)
                            .keyboardType(.decimalPad)
                        Text("小时")
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                if !isReverse {
                    Section {
                        Toggle("单独设置宽限", isOn: $customGrace)
                        if customGrace {
                            HStack {
                                Text("允许延迟")
                                TextField("10", text: $graceText).keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("%")
                            }
                            if StatisticsCalculator.validGrace(Double(graceText)) == nil {
                                Text("请输入大于或等于 0 的百分比").foregroundStyle(AppPalette.red)
                            }
                        }
                    } header: { Text("统计宽限") } footer: {
                        Text("未单独设置时使用当前 Profile 的宽限。修改后重算历史统计，不改变通知时间。")
                    }
                }

                if task == nil {
                    Section {
                        DisclosureGroup(
                            "高级设置",
                            isExpanded: $advancedSettingsExpanded
                        ) {
                            Toggle(
                                "自定义\(previousEvent)时间",
                                isOn: $usesCustomInitialCompletion
                            )

                            if usesCustomInitialCompletion {
                                DatePicker(
                                    "\(previousEvent)时间",
                                    selection: $initialCompletedAt,
                                    in: ...Date(),
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                Text(isReverse
                                     ? "用于计算最短间隔，不计为一条记录。"
                                     : "只用于确定当前周期，不会计入完成统计。")
                                    .font(.caption)
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                }

                if isReverse {
                    Section {
                        Toggle("最短间隔结束时提醒", isOn: $notifyWhenReady)
                    } header: {
                        Text("系统提醒")
                    } footer: {
                        Text("记录后开始计时。间隔结束时会提醒可以再做，随后等待下一次记录。")
                    }
                } else {
                    recurringReminders
                }
            }
            .navigationTitle(task == nil ? "新增任务" : (isReverse ? "编辑反向任务" : "编辑任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let intervalHours, let reminderRules else { return }
                        if task == nil, usesCustomInitialCompletion {
                            showCustomCompletionConfirmation = true
                        } else {
                            saveAndDismiss(
                                intervalHours: intervalHours,
                                reminderRules: reminderRules,
                                lastCompletedAt: nil
                            )
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (!isReverse && customGrace && StatisticsCalculator.validGrace(Double(graceText)) == nil)
                            || intervalHours == nil
                            || reminderRules == nil
                            || (usesCustomInitialCompletion && initialCompletedAt > Date())
                    )
                }
            }
            .onChange(of: usesCustomInitialCompletion) { enabled in
                if enabled {
                    initialCompletedAt = ReminderDate.floorToMinute(Date())
                }
            }
            .alert("确认自定义\(previousEvent)时间", isPresented: $showCustomCompletionConfirmation) {
                Button("确认创建") {
                    guard let intervalHours, let reminderRules else { return }
                    saveAndDismiss(
                        intervalHours: intervalHours,
                        reminderRules: reminderRules,
                        lastCompletedAt: ReminderDate.floorToMinute(initialCompletedAt)
                    )
                }
                Button("取消", role: .cancel) {}
            } message: {
                let completedAt = ReminderDate.floorToMinute(initialCompletedAt)
                let dueAt = intervalHours.map {
                    completedAt.addingTimeInterval($0 * 3_600)
                }
                Text(
                    "\(previousEvent)：\(DisplayFormat.dateTime(completedAt))\n" +
                    "\(boundary)：\(DisplayFormat.dateTime(dueAt))\n\n" +
                    "这个时间用于确定本轮的间隔，不计为一条记录。"
                )
            }
        }
    }

    private var recurringReminders: some View {
        Section {
            if reminderDrafts.isEmpty {
                Text("未设置系统提醒")
                    .foregroundStyle(AppPalette.muted)
            }

            ForEach($reminderDrafts) { $draft in
                ReminderDraftRow(
                    draft: $draft,
                    intervalHours: intervalHours,
                    onDelete: { removeReminder(id: draft.id) }
                )
            }

            Button {
                addReminder()
            } label: {
                Label("添加提醒", systemImage: "plus.circle")
            }
        } header: {
            Text("系统提醒")
        } footer: {
            Text("可添加多条提醒。首次保存提醒时，系统会请求通知权限。")
        }
    }

    private func saveAndDismiss(
        intervalHours: Double,
        reminderRules: [ReminderRule],
        lastCompletedAt: Date?
    ) {
        onSave(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            intervalHours,
            reminderRules,
            lastCompletedAt,
            !isReverse && customGrace ? Double(graceText) : nil,
            kind
        )
        dismiss()
    }

    private func removeReminder(id: String) {
        reminderDrafts.removeAll { $0.id == id }
    }

    private func addReminder() {
        let modes = Set(reminderDrafts.map(\.mode))
        let mode: ReminderMode
        if !modes.contains(.due) {
            mode = .due
        } else if !modes.contains(.remainingPercentage) {
            mode = .remainingPercentage
        } else {
            mode = .remainingTime
        }

        let defaultRemainingHours = max(0.25, (intervalHours ?? 48) / 2)
        reminderDrafts.append(
            ReminderDraft(
                rule: ReminderRule(mode: mode, amount: mode == .remainingPercentage ? 20 : 0),
                defaultRemainingHours: defaultRemainingHours
            )
        )
    }
}

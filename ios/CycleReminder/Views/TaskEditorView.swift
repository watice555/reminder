import SwiftUI

struct TaskEditorView: View {
    let task: ReminderTask?
    let onSave: (String, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var days: String
    @State private var hours: String

    init(task: ReminderTask?, onSave: @escaping (String, Double) -> Void) {
        self.task = task
        self.onSave = onSave
        let interval = task?.intervalHours ?? 48
        let dayValue = Int(interval / 24)
        let hourValue = interval - Double(dayValue * 24)
        _name = State(initialValue: task?.name ?? "")
        _days = State(initialValue: dayValue > 0 ? String(dayValue) : "")
        _hours = State(initialValue: hourValue > 0 ? DisplayFormat.number(hourValue) : "")
    }

    private var intervalHours: Double? {
        let dayValue = days.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Double(days)
        let hourValue = hours.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Double(hours)
        guard
            let dayValue,
            let hourValue,
            dayValue >= 0,
            hourValue >= 0,
            dayValue * 24 + hourValue > 0
        else {
            return nil
        }
        return dayValue * 24 + hourValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务名称") {
                    TextField("例如：换滤芯", text: $name)
                        .textInputAutocapitalization(.never)
                }

                Section("循环时间") {
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
            }
            .navigationTitle(task == nil ? "新增任务" : "编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let intervalHours else { return }
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), intervalHours)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || intervalHours == nil)
                }
            }
        }
    }
}

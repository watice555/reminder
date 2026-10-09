import Foundation
import SwiftUI

enum AppPalette {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let line = Color(uiColor: .separator)
    static let green = adaptive(light: (0.13, 0.48, 0.28), dark: (0.40, 0.82, 0.55))
    static let teal = adaptive(light: (0.05, 0.48, 0.47), dark: (0.32, 0.80, 0.78))
    static let yellow = adaptive(light: (0.57, 0.40, 0.02), dark: (0.94, 0.76, 0.30))
    static let orange = adaptive(light: (0.72, 0.32, 0.06), dark: (1, 0.62, 0.30))
    static let red = adaptive(light: (0.76, 0.22, 0.22), dark: (1, 0.48, 0.48))

    private static func adaptive(
        light: (Double, Double, Double), dark: (Double, Double, Double)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

enum DisplayFormat {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("MMddHHmm")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "时间无效" }
        return dateFormatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func interval(_ intervalHours: Double) -> String {
        let days = Int(intervalHours / 24)
        let hours = intervalHours - Double(days * 24)
        var parts: [String] = []
        if days > 0 { parts.append("\(days) 天") }
        if hours > 0 { parts.append("\(number(hours)) 小时") }
        return parts.isEmpty ? "0 小时" : parts.joined(separator: " ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }

    static func number(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

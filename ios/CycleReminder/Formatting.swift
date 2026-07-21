import Foundation
import SwiftUI

enum AppPalette {
    static let background = Color(red: 246 / 255, green: 244 / 255, blue: 239 / 255)
    static let ink = Color(red: 31 / 255, green: 41 / 255, blue: 51 / 255)
    static let green = Color(red: 23 / 255, green: 97 / 255, blue: 58 / 255)
    static let red = Color(red: 178 / 255, green: 57 / 255, blue: 35 / 255)
    static let muted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let line = Color(red: 229 / 255, green: 224 / 255, blue: 216 / 255)
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

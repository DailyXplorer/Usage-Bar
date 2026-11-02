import Foundation

enum ClockText {
    static var systemUses24HourClock: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "HH"
        return !format.contains("a")
    }

    static func from(
        _ date: Date,
        relativeTo reference: Date,
        uses24HourClock: Bool = systemUses24HourClock,
        calendar: Calendar = .current
    ) -> String {
        let parts = components(date, relativeTo: reference, uses24HourClock: uses24HourClock, calendar: calendar)
        return [parts.day, parts.time].compactMap { $0 }.joined(separator: " ")
    }

    static func at(
        _ date: Date,
        relativeTo reference: Date,
        uses24HourClock: Bool = systemUses24HourClock,
        calendar: Calendar = .current
    ) -> String {
        let parts = components(date, relativeTo: reference, uses24HourClock: uses24HourClock, calendar: calendar)
        guard let day = parts.day else { return "at \(parts.time)" }
        return parts.isDate ? "on \(day) at \(parts.time)" : "\(day) at \(parts.time)"
    }

    private static func components(
        _ date: Date,
        relativeTo reference: Date,
        uses24HourClock: Bool,
        calendar: Calendar
    ) -> (day: String?, time: String, isDate: Bool) {
        let time = formatter(uses24HourClock ? "HH:mm" : "h:mm a", calendar: calendar).string(from: date)
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: reference),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case 0:
            return (nil, time, false)
        case 1:
            return ("tomorrow", time, false)
        case -1:
            return ("yesterday", time, false)
        case -6...6:
            return (formatter("EEE", calendar: calendar).string(from: date), time, false)
        default:
            return (formatter("MMM d", calendar: calendar).string(from: date), time, true)
        }
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}

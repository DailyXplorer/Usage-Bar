import Foundation

enum RetryAfter {
    static func date(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        date(from: response.value(forHTTPHeaderField: "Retry-After"), now: now)
    }

    static func date(from value: String?, now: Date = Date()) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }),
           let seconds = TimeInterval(value), seconds.isFinite {
            let date = now.addingTimeInterval(seconds)
            return date.timeIntervalSinceReferenceDate.isFinite ? date : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.isLenient = false
        return formatter.date(from: value)
    }
}

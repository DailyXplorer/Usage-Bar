import Foundation

enum MoneyText {
    static func spent(_ used: Double, of limit: Double, currency: String = "USD", period: String? = nil) -> String {
        let text = "\(amount(used, currency: currency)) / \(amount(limit, currency: currency)) spent"
        return period.map { "\(text) \($0)" } ?? text
    }

    static func amount(_ value: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }
}

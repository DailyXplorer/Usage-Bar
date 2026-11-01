import Foundation

struct UsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitStatus?
    let rateLimitReachedType: String?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?
    let additionalRateLimits: [AdditionalRateLimit]?
    let credits: CodexCredits?
    let spendControl: SpendControl?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case rateLimitReachedType = "rate_limit_reached_type"
        case rateLimitResetCredits = "rate_limit_reset_credits"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case spendControl = "spend_control"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = container.lenientString(forKey: .planType)
        rateLimit = try? container.decodeIfPresent(RateLimitStatus.self, forKey: .rateLimit)
        rateLimitReachedType = (try? container.decodeIfPresent(RateLimitReachedType.self, forKey: .rateLimitReachedType))?
            .type
        rateLimitResetCredits = try? container.decodeIfPresent(
            RateLimitResetCreditsSummary.self,
            forKey: .rateLimitResetCredits
        )
        additionalRateLimits = (try? container.decodeIfPresent(
            [Lenient<AdditionalRateLimit>].self,
            forKey: .additionalRateLimits
        ))?.compactMap(\.value)
        credits = try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        spendControl = try? container.decodeIfPresent(SpendControl.self, forKey: .spendControl)
    }
}

struct RateLimitReachedType: Decodable {
    let type: String?

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            type = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.lenientString(forKey: .type)
    }
}

struct AdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let normalModelSlug: String?
    let rateLimit: RateLimitStatus?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case normalModelSlug = "normal_model_slug"
        case rateLimit = "rate_limit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitName = container.lenientString(forKey: .limitName)
        meteredFeature = container.lenientString(forKey: .meteredFeature)
        normalModelSlug = container.lenientString(forKey: .normalModelSlug)
        rateLimit = try? container.decodeIfPresent(RateLimitStatus.self, forKey: .rateLimit)
    }
}

struct RateLimitStatus: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = container.lenientBool(forKey: .allowed)
        limitReached = container.lenientBool(forKey: .limitReached)
        primaryWindow = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .primaryWindow)
        secondaryWindow = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .secondaryWindow)
    }

    var isBlocked: Bool {
        limitReached == true || allowed == false
    }
}

struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int?
    let resetAfterSeconds: Int?
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let usedPercent = container.lenientDouble(forKey: .usedPercent) else {
            throw DecodingError.valueNotFound(
                Double.self,
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.usedPercent],
                    debugDescription: "A window without used_percent is unknown, not empty."
                )
            )
        }
        self.usedPercent = usedPercent
        limitWindowSeconds = CodexNumbers.seconds(container.lenientDouble(forKey: .limitWindowSeconds))
            .flatMap { $0 > 0 ? $0 : nil }
        resetAfterSeconds = CodexNumbers.seconds(container.lenientDouble(forKey: .resetAfterSeconds))
        resetAt = CodexNumbers.epochDate(container.lenientDouble(forKey: .resetAt))
    }
}

struct RateLimitResetCreditsSummary: Decodable {
    let availableCount: Int?
    let applicableAvailableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case applicableAvailableCount = "applicable_available_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = CodexNumbers.count(container.lenientDouble(forKey: .availableCount))
        applicableAvailableCount = CodexNumbers.count(container.lenientDouble(forKey: .applicableAvailableCount))
    }
}

struct CodexCredits: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = container.lenientBool(forKey: .hasCredits)
        unlimited = container.lenientBool(forKey: .unlimited)
        balance = container.lenientNumberText(forKey: .balance)
    }
}

struct SpendControl: Decodable {
    let reached: Bool?
    let individualLimit: SpendControlLimit?

    enum CodingKeys: String, CodingKey {
        case reached
        case individualLimit = "individual_limit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reached = container.lenientBool(forKey: .reached)
        individualLimit = try? container.decodeIfPresent(SpendControlLimit.self, forKey: .individualLimit)
    }
}

struct SpendControlLimit: Decodable {
    let limit: String?
    let used: String?
    let usedPercent: Double?
    let remainingPercent: Double?
    let resetAfterSeconds: Int?
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case limit
        case used
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = container.lenientNumberText(forKey: .limit)
        used = container.lenientNumberText(forKey: .used)
        usedPercent = container.lenientDouble(forKey: .usedPercent)
        remainingPercent = container.lenientDouble(forKey: .remainingPercent)
        resetAfterSeconds = CodexNumbers.seconds(container.lenientDouble(forKey: .resetAfterSeconds))
        resetAt = CodexNumbers.epochDate(container.lenientDouble(forKey: .resetAt))
    }
}

enum CodexNumbers {
    static let earliestEpoch: Double = 946_684_800
    static let latestEpoch: Double = 4_102_444_800
    static let maxSeconds: Double = 100 * 365 * 24 * 60 * 60

    static func epochDate(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value >= earliestEpoch, value <= latestEpoch else { return nil }
        return Date(timeIntervalSince1970: value.rounded())
    }

    static func seconds(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(min(maxSeconds, max(0, value.rounded())))
    }

    static func count(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(min(1_000_000, max(0, value.rounded())))
    }

    static func percent(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? 100 : 0 }
        return Int(min(100, max(0, value.rounded())))
    }

    static func amount(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text), value.isFinite, value >= 0, value < 1e15 else { return nil }
        return value
    }

    static func formattedAmount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }
}

extension KeyedDecodingContainer {
    func lenientDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let raw = try? decodeIfPresent(String.self, forKey: key),
           let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           value.isFinite {
            return value
        }
        return nil
    }

    func lenientBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let raw = try? decodeIfPresent(String.self, forKey: key) {
            switch raw.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        return nil
    }

    func lenientString(forKey key: Key) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func lenientNumberText(forKey key: Key) -> String? {
        if let value = lenientString(forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return String(value)
        }
        return nil
    }
}

struct LimitBucket: Identifiable, Codable {
    struct IdentityKey: Hashable {
        let provider: Provider
        let kind: Kind
        let scope: String?
        let windowSeconds: Int?
    }

    enum Provider: String, Codable, CaseIterable, Identifiable {
        case codex, claude, cursor, opencode, commandcode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .codex: return "Codex"
            case .claude: return "Claude"
            case .cursor: return "Cursor"
            case .opencode: return "OpenCode"
            case .commandcode: return "Command Code"
            }
        }
    }

    enum Kind: String, Codable {
        case primary, secondary
        case session, weeklyAll, weeklyScoped
        case cursorModels, otherModels, grokBot
        case rolling, weekly, monthly
        case additional, spendLimit, credit, balance
        case other
    }

    private enum CodingKeys: String, CodingKey {
        case provider, kind, name, usedPercent, resetAt, resetAfterSeconds
        case limitWindowSeconds, reached, detail, scope, isActive
    }

    var provider: Provider = .codex
    let kind: Kind
    var scope: String?
    var name: String
    var usedPercent: Int
    let resetAt: Date?
    var resetAfterSeconds: Int?
    let limitWindowSeconds: Int?
    var reached: Bool
    let detail: String?
    var isActive: Bool

    init(
        provider: Provider = .codex,
        kind: Kind,
        scope: String? = nil,
        name: String,
        usedPercent: Int,
        resetAt: Date?,
        resetAfterSeconds: Int?,
        limitWindowSeconds: Int?,
        reached: Bool,
        detail: String? = nil,
        isActive: Bool = false
    ) {
        self.provider = provider
        self.kind = kind
        self.scope = scope
        self.name = name
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.resetAfterSeconds = resetAfterSeconds
        self.limitWindowSeconds = limitWindowSeconds
        self.reached = reached
        self.detail = detail
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .codex
        kind = try container.decode(Kind.self, forKey: .kind)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        name = try container.decode(String.self, forKey: .name)
        usedPercent = max(0, min(100, try container.decode(Int.self, forKey: .usedPercent)))
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        resetAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .resetAfterSeconds)
        limitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
        reached = try container.decode(Bool.self, forKey: .reached)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encode(name, forKey: .name)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(resetAfterSeconds, forKey: .resetAfterSeconds)
        try container.encodeIfPresent(limitWindowSeconds, forKey: .limitWindowSeconds)
        try container.encode(reached, forKey: .reached)
        try container.encodeIfPresent(detail, forKey: .detail)
        if isActive {
            try container.encode(isActive, forKey: .isActive)
        }
    }

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var id: IdentityKey {
        IdentityKey(
            provider: provider,
            kind: kind,
            scope: scope ?? (kind == .other ? name : nil),
            windowSeconds: limitWindowSeconds
        )
    }

    var displayName: String {
        guard let first = name.first else { return name }
        return String(first).uppercased() + name.dropFirst()
    }

    var isValueOnly: Bool {
        kind == .balance
    }

    var drivesMenuBar: Bool {
        switch kind {
        case .spendLimit, .credit, .balance:
            return false
        default:
            return true
        }
    }

    var isTimeWindow: Bool {
        drivesMenuBar && resetAt != nil
    }

    var alertKey: String {
        [provider.rawValue, kind.rawValue, id.scope ?? "", limitWindowSeconds.map(String.init) ?? ""]
            .joined(separator: "|")
    }

    func remainingResetSeconds(at date: Date) -> Int? {
        guard let resetAt else { return nil }
        return Self.clampedSeconds(resetAt.timeIntervalSince(date))
    }

    func hasReset(at date: Date) -> Bool {
        guard let resetAt else { return false }
        return resetAt <= date
    }

    func hasReset(at date: Date, since fetchedAt: Date?) -> Bool {
        guard let resetAt, resetAt <= date else { return false }
        return fetchedAt.map { resetAt > $0 } ?? true
    }

    func resetApplied(at date: Date, since fetchedAt: Date?) -> LimitBucket {
        guard hasReset(at: date, since: fetchedAt), !isValueOnly else { return self }
        var copy = self
        copy.usedPercent = 0
        copy.reached = false
        copy.resetAfterSeconds = 0
        return copy
    }

    func recountingReset(from now: Date) -> LimitBucket {
        guard let resetAt else { return self }
        var copy = self
        copy.resetAfterSeconds = Self.clampedSeconds(resetAt.timeIntervalSince(now))
        return copy
    }

    private static func clampedSeconds(_ interval: TimeInterval) -> Int {
        guard interval.isFinite else { return interval > 0 ? Int(Int32.max) : 0 }
        return Int(max(0, min(Double(Int32.max), interval.rounded())))
    }
}

enum WindowLabels {
    static let currentSession = "Current Session"
    static let fiveHourLimit = "5-Hour Limit"
    static let dailyLimit = "Daily Limit"
    static let weeklyLimit = "Weekly Limit"
    static let monthlyLimit = "Monthly Limit"
    static let annualLimit = "Annual Limit"
    static let primaryLimit = "Primary Limit"
    static let secondaryLimit = "Secondary Limit"

    static let minutesPerHour: Int = 60
    static let minutesPer5Hours: Int = 5 * minutesPerHour
    static let minutesPerDay: Int = 24 * minutesPerHour
    static let minutesPerWeek: Int = 7 * minutesPerDay
    static let minutesPerMonth: Int = 30 * minutesPerDay
    static let minutesPerYear: Int = 365 * minutesPerDay

    static func label(forWindowSeconds windowSeconds: Int?, isSecondary: Bool) -> String {
        knownLabel(forWindowSeconds: windowSeconds) ?? fallbackLabel(isSecondary: isSecondary)
    }

    static func knownLabel(forWindowSeconds windowSeconds: Int?) -> String? {
        guard let windowSeconds else { return nil }
        let minutes = windowSeconds / 60
        if isApproximate(minutes, expected: minutesPer5Hours) {
            return currentSession
        }
        if isApproximate(minutes, expected: minutesPerDay) {
            return dailyLimit
        }
        if isApproximate(minutes, expected: minutesPerWeek) {
            return weeklyLimit
        }
        if isApproximate(minutes, expected: minutesPerMonth) {
            return monthlyLimit
        }
        if isApproximate(minutes, expected: minutesPerYear) {
            return annualLimit
        }
        return nil
    }

    static func fallbackLabel(isSecondary: Bool) -> String {
        isSecondary ? secondaryLimit : primaryLimit
    }

    private static func isApproximate(_ minutes: Int, expected: Int) -> Bool {
        let m = Double(minutes)
        let e = Double(expected)
        return m >= e * 0.95 && m <= e * 1.05
    }
}

enum CodexLimits {
    static let creditsDisplayName = "Credits"
    static let spendLimitDisplayName = "Monthly Credit Limit"
    static let unlimitedCredits = "Unlimited"
    static let availableCredits = "Available"
    static let additionalFallbackName = "Other"
    static let creditsScope = "credits"
    static let spendLimitScope = "spend-control"
    private static let rateLimitReachedType = "rate_limit_reached"

    static func buckets(from usage: UsageResponse, now: Date = Date()) -> [LimitBucket] {
        var result = windowBuckets(
            rateLimit: usage.rateLimit,
            markBindingWindow: usage.spendControl?.reached != true
                && (usage.rateLimitReachedType == nil || usage.rateLimitReachedType == rateLimitReachedType),
            now: now
        ) { window, position in
            (
                kind: position == .primary ? .primary : .secondary,
                scope: nil,
                name: WindowLabels.label(forWindowSeconds: window.limitWindowSeconds, isSecondary: position == .secondary)
            )
        }
        if let credits = usage.credits.flatMap(creditsBucket) {
            result.append(credits)
        }
        if let spendLimit = usage.spendControl.flatMap({ spendLimitBucket(from: $0, now: now) }) {
            result.append(spendLimit)
        }
        var usedScopes: Set<String> = []
        for (index, item) in (usage.additionalRateLimits ?? []).enumerated() {
            let base = item.limitName ?? item.normalModelSlug ?? additionalFallbackName
            var identifier = "additional.\(item.meteredFeature ?? item.limitName ?? String(index))"
            if usedScopes.contains(identifier) {
                identifier += ".\(index)"
            }
            usedScopes.insert(identifier)
            result += windowBuckets(rateLimit: item.rateLimit, markBindingWindow: true, now: now) { window, position in
                (
                    kind: .additional,
                    scope: "\(identifier).\(position.rawValue)",
                    name: additionalLimitName(base: base, window: window, position: position)
                )
            }
        }
        return result
    }

    private enum WindowPosition: String {
        case primary, secondary
    }

    private static func windowBuckets(
        rateLimit: RateLimitStatus?,
        markBindingWindow: Bool,
        now: Date,
        describe: (RateLimitWindow, WindowPosition) -> (kind: LimitBucket.Kind, scope: String?, name: String)
    ) -> [LimitBucket] {
        guard let rateLimit else { return [] }
        let windows = [
            rateLimit.primaryWindow.map { ($0, WindowPosition.primary) },
            rateLimit.secondaryWindow.map { ($0, WindowPosition.secondary) },
        ].compactMap { $0 }
        let anyWindowFull = windows.contains { $0.0.usedPercent >= 100 }
        let bindingIndex = markBindingWindow && rateLimit.isBlocked && !anyWindowFull
            ? windows.indices.max { windows[$0].0.usedPercent < windows[$1].0.usedPercent }
            : nil
        return windows.enumerated().map { index, entry in
            let (window, position) = entry
            let description = describe(window, position)
            return makeBucket(
                kind: description.kind,
                scope: description.scope,
                name: description.name,
                usedPercent: window.usedPercent,
                resetAt: window.resetAt,
                resetAfterSeconds: window.resetAfterSeconds,
                limitWindowSeconds: window.limitWindowSeconds,
                reached: window.usedPercent >= 100 || index == bindingIndex,
                now: now
            )
        }
    }

    private static func additionalLimitName(
        base: String,
        window: RateLimitWindow,
        position: WindowPosition
    ) -> String {
        switch WindowLabels.knownLabel(forWindowSeconds: window.limitWindowSeconds) {
        case WindowLabels.currentSession?:
            return "\(base) \(WindowLabels.fiveHourLimit)"
        case let label?:
            return "\(base) \(label)"
        case nil:
            return position == .primary ? base : "\(base) \(WindowLabels.secondaryLimit)"
        }
    }

    private static func creditsBucket(from credits: CodexCredits) -> LimitBucket? {
        let value: String
        if credits.unlimited == true {
            value = unlimitedCredits
        } else if credits.hasCredits == true {
            value = CodexNumbers.amount(credits.balance).map(creditsText) ?? availableCredits
        } else {
            return nil
        }
        return LimitBucket(
            kind: .balance,
            scope: creditsScope,
            name: creditsDisplayName,
            usedPercent: 0,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: nil,
            reached: false,
            detail: value
        )
    }

    private static func creditsText(_ amount: Double) -> String {
        let text = CodexNumbers.formattedAmount(amount)
        return text == "1" ? "1 credit" : "\(text) credits"
    }

    private static func spendLimitBucket(from spendControl: SpendControl, now: Date) -> LimitBucket? {
        guard let limit = spendControl.individualLimit else { return nil }
        let used = CodexNumbers.amount(limit.used)
        let total = CodexNumbers.amount(limit.limit)
        let usedPercent: Double
        if let value = limit.usedPercent {
            usedPercent = value
        } else if let remaining = limit.remainingPercent {
            usedPercent = 100 - remaining
        } else if let used, let total, total > 0 {
            usedPercent = used / total * 100
        } else {
            return nil
        }
        let detail: String? = {
            guard let used, let total else { return nil }
            return "\(CodexNumbers.formattedAmount(used)) of \(CodexNumbers.formattedAmount(total)) credits used"
        }()
        return makeBucket(
            kind: .spendLimit,
            scope: spendLimitScope,
            name: spendLimitDisplayName,
            usedPercent: usedPercent,
            resetAt: limit.resetAt,
            resetAfterSeconds: limit.resetAfterSeconds,
            limitWindowSeconds: nil,
            reached: spendControl.reached == true || usedPercent >= 100,
            detail: detail,
            now: now
        )
    }

    static func relabeled(_ bucket: LimitBucket) -> LimitBucket {
        guard bucket.provider == .codex,
              bucket.kind == .primary || bucket.kind == .secondary else {
            return bucket
        }
        let nextName = WindowLabels.label(
            forWindowSeconds: bucket.limitWindowSeconds,
            isSecondary: bucket.kind == .secondary
        )
        guard nextName != bucket.name else { return bucket }
        return LimitBucket(
            provider: bucket.provider,
            kind: bucket.kind,
            scope: bucket.scope,
            name: nextName,
            usedPercent: bucket.usedPercent,
            resetAt: bucket.resetAt,
            resetAfterSeconds: bucket.resetAfterSeconds,
            limitWindowSeconds: bucket.limitWindowSeconds,
            reached: bucket.reached,
            detail: bucket.detail
        )
    }

    private static func makeBucket(
        kind: LimitBucket.Kind,
        scope: String?,
        name: String,
        usedPercent: Double,
        resetAt: Date?,
        resetAfterSeconds: Int?,
        limitWindowSeconds: Int?,
        reached: Bool,
        detail: String? = nil,
        now: Date
    ) -> LimitBucket {
        let resolvedResetAt = resetAt
            ?? resetAfterSeconds.map { now.addingTimeInterval(TimeInterval($0)) }
        let resolvedResetAfterSeconds = resetAfterSeconds
            ?? resolvedResetAt.map { max(0, Int($0.timeIntervalSince(now).rounded())) }
        return LimitBucket(
            kind: kind,
            scope: scope,
            name: name,
            usedPercent: CodexNumbers.percent(usedPercent),
            resetAt: resolvedResetAt,
            resetAfterSeconds: resolvedResetAfterSeconds,
            limitWindowSeconds: limitWindowSeconds,
            reached: reached,
            detail: detail
        )
    }
}

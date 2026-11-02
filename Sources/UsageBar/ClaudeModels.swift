import Foundation

struct ClaudeUsageResponse: Decodable {
    var limits: [ClaudeLimitEntry]?
    var fiveHour: ClaudeWindow?
    var sevenDay: ClaudeWindow?
    var sevenDayOpus: ClaudeWindow?
    var sevenDaySonnet: ClaudeWindow?
    var sevenDayOAuthApps: ClaudeWindow?
    var sevenDayCowork: ClaudeWindow?
    var cinderCove: ClaudeWindow?
    var wattleEmber: ClaudeWindow?
    var extraUsage: ClaudeExtraUsage?

    enum CodingKeys: String, CodingKey {
        case limits
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case sevenDayCowork = "seven_day_cowork"
        case cinderCove = "cinder_cove"
        case wattleEmber = "wattle_ember"
        case extraUsage = "extra_usage"
    }

    init(
        limits: [ClaudeLimitEntry]? = nil,
        fiveHour: ClaudeWindow? = nil,
        sevenDay: ClaudeWindow? = nil
    ) {
        self.limits = limits
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = (try? container.decodeIfPresent([Lenient<ClaudeLimitEntry>].self, forKey: .limits))?
            .flatMap { $0.compactMap(\.value) }
        fiveHour = container.lenient(ClaudeWindow.self, forKey: .fiveHour)
        sevenDay = container.lenient(ClaudeWindow.self, forKey: .sevenDay)
        sevenDayOpus = container.lenient(ClaudeWindow.self, forKey: .sevenDayOpus)
        sevenDaySonnet = container.lenient(ClaudeWindow.self, forKey: .sevenDaySonnet)
        sevenDayOAuthApps = container.lenient(ClaudeWindow.self, forKey: .sevenDayOAuthApps)
        sevenDayCowork = container.lenient(ClaudeWindow.self, forKey: .sevenDayCowork)
        cinderCove = container.lenient(ClaudeWindow.self, forKey: .cinderCove)
        wattleEmber = container.lenient(ClaudeWindow.self, forKey: .wattleEmber)
        extraUsage = container.lenient(ClaudeExtraUsage.self, forKey: .extraUsage)
    }
}

struct ClaudeLimitEntry: Decodable {
    var kind: String?
    var group: String?
    var percent: Double?
    var severity: String?
    var resetsAt: Date?
    var modelID: String?
    var modelName: String?
    var isActive: Bool

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    private enum ScopeKeys: String, CodingKey {
        case model
    }

    private enum ModelKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    init(
        kind: String?,
        group: String? = nil,
        percent: Double?,
        resetsAt: Date? = nil,
        modelName: String? = nil,
        isActive: Bool = false
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.resetsAt = resetsAt
        self.modelName = modelName
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.lenientString(forKey: .kind)
        group = container.lenientString(forKey: .group)
        percent = container.lenientDouble(forKey: .percent)
        severity = container.lenientString(forKey: .severity)
        resetsAt = container.lenientDate(forKey: .resetsAt)
        isActive = container.lenientBool(forKey: .isActive) ?? false
        let model = (try? container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope))
            .flatMap { try? $0.nestedContainer(keyedBy: ModelKeys.self, forKey: .model) }
        modelID = model?.lenientString(forKey: .id)
        modelName = model?.lenientString(forKey: .displayName)
    }
}

struct ClaudeWindow: Decodable {
    var utilization: Double?
    var resetsAt: Date?
    var label: String?
    var limitDollars: Double?
    var usedDollars: Double?

    enum CodingKeys: String, CodingKey {
        case utilization, label
        case resetsAt = "resets_at"
        case limitDollars = "limit_dollars"
        case usedDollars = "used_dollars"
    }

    init(utilization: Double?, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = container.lenientDouble(forKey: .utilization)
        resetsAt = container.lenientDate(forKey: .resetsAt)
        label = container.lenientString(forKey: .label)
        limitDollars = container.lenientDouble(forKey: .limitDollars)
        usedDollars = container.lenientDouble(forKey: .usedDollars)
    }
}

struct ClaudeExtraUsage: Decodable {
    var isEnabled: Bool
    var monthlyLimit: Double?
    var usedCredits: Double?
    var utilization: Double?
    var currency: String?
    var decimalPlaces: Int?

    enum CodingKeys: String, CodingKey {
        case utilization, currency
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case decimalPlaces = "decimal_places"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.lenientBool(forKey: .isEnabled) ?? false
        monthlyLimit = container.lenientDouble(forKey: .monthlyLimit)
        usedCredits = container.lenientDouble(forKey: .usedCredits)
        utilization = container.lenientDouble(forKey: .utilization)
        currency = container.lenientString(forKey: .currency)
        decimalPlaces = container.lenientDouble(forKey: .decimalPlaces).map { Int(max(0, min(4, $0))) }
    }
}

enum ClaudeLimits {
    static let sessionKind = "session"
    static let weeklyAllKind = "weekly_all"
    static let weeklyScopedKind = "weekly_scoped"
    static let usageCreditsName = "Usage credits"

    private static let hour = 60 * 60
    private static let week = 7 * 24 * hour

    static func buckets(from response: ClaudeUsageResponse, now: Date = Date()) -> [LimitBucket] {
        var windows = (response.limits ?? []).compactMap { bucket(from: $0, now: now) }
        if windows.isEmpty {
            windows = legacyBuckets(from: response, now: now)
        }
        let sorted = windows.enumerated()
            .sorted { ($0.element.kind.claudeRank, $0.offset) < ($1.element.kind.claudeRank, $1.offset) }
            .map(\.element)
        return sorted + creditBuckets(from: response, now: now)
    }

    private static func bucket(from entry: ClaudeLimitEntry, now: Date) -> LimitBucket? {
        guard let percent = entry.percent, entry.kind != nil || entry.group != nil else { return nil }
        let kind = self.kind(for: entry.kind)
        return LimitBucket(
            provider: .claude,
            kind: kind,
            scope: scope(for: entry, kind: kind),
            name: label(kind: entry.kind, group: entry.group, scopeModel: entry.modelName),
            usedPercent: clampPercent(percent),
            resetAt: entry.resetsAt,
            resetAfterSeconds: secondsUntil(entry.resetsAt, from: now),
            limitWindowSeconds: windowSeconds(kind: entry.kind, group: entry.group),
            reached: percent >= 100,
            isActive: entry.isActive
        )
    }

    private static func legacyBuckets(from response: ClaudeUsageResponse, now: Date) -> [LimitBucket] {
        let windows: [(kind: LimitBucket.Kind, window: ClaudeWindow?, scope: String?, name: String, seconds: Int)] = [
            (.session, response.fiveHour, nil, label(kind: sessionKind, scopeModel: nil), 5 * hour),
            (.weeklyAll, response.sevenDay, nil, label(kind: weeklyAllKind, scopeModel: nil), week),
            (.weeklyScoped, response.sevenDayOpus, legacyModelScope("Opus"), weeklyLabel("Opus"), week),
            (.weeklyScoped, response.sevenDaySonnet, legacyModelScope("Sonnet"), weeklyLabel("Sonnet"), week),
            (.other, response.sevenDayOAuthApps, "seven_day_oauth_apps", weeklyLabel("OAuth apps"), week),
            (.other, response.sevenDayCowork, "seven_day_cowork", weeklyLabel("Cowork"), week),
        ]
        return windows.compactMap { kind, window, scope, name, seconds in
            guard let window, let utilization = window.utilization else { return nil }
            return LimitBucket(
                provider: .claude,
                kind: kind,
                scope: scope,
                name: name,
                usedPercent: clampPercent(utilization),
                resetAt: window.resetsAt,
                resetAfterSeconds: secondsUntil(window.resetsAt, from: now),
                limitWindowSeconds: seconds,
                reached: utilization >= 100
            )
        }
    }

    private static func creditBuckets(from response: ClaudeUsageResponse, now: Date) -> [LimitBucket] {
        var result: [LimitBucket] = []
        if let extra = response.extraUsage, extra.isEnabled {
            let currency = extra.currency?.uppercased() ?? "USD"
            let scale = pow(10, Double(extra.decimalPlaces ?? 2))
            if let limit = extra.monthlyLimit {
                let used = extra.usedCredits ?? 0
                let percent = extra.utilization ?? (limit > 0 ? used / limit * 100 : 100)
                result.append(LimitBucket(
                    provider: .claude,
                    kind: .spendLimit,
                    scope: "extra_usage",
                    name: usageCreditsName,
                    usedPercent: clampPercent(percent),
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: nil,
                    reached: percent >= 100,
                    detail: "\(money(used / scale, currency: currency)) / \(money(limit / scale, currency: currency)) spent"
                ))
            } else {
                result.append(LimitBucket(
                    provider: .claude,
                    kind: .balance,
                    scope: "extra_usage",
                    name: usageCreditsName,
                    usedPercent: 0,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: nil,
                    reached: false,
                    detail: "Unlimited"
                ))
            }
        }
        let credits: [(key: String, window: ClaudeWindow?, fallbackName: String)] = [
            ("cinder_cove", response.cinderCove, "Claude Code and Cowork credit"),
            ("wattle_ember", response.wattleEmber, "Credit"),
        ]
        for (key, window, fallbackName) in credits {
            guard let window, let utilization = window.utilization else { continue }
            var detail: String?
            if let used = window.usedDollars, let limit = window.limitDollars {
                detail = "\(money(used, currency: "USD")) / \(money(limit, currency: "USD")) spent"
            }
            result.append(LimitBucket(
                provider: .claude,
                kind: .credit,
                scope: key,
                name: nonEmpty(window.label) ?? fallbackName,
                usedPercent: clampPercent(utilization),
                resetAt: window.resetsAt,
                resetAfterSeconds: secondsUntil(window.resetsAt, from: now),
                limitWindowSeconds: nil,
                reached: utilization >= 100,
                detail: detail
            ))
        }
        return result
    }

    static func label(kind: String?, group: String? = nil, scopeModel: String?) -> String {
        switch kind {
        case sessionKind:
            return "Current session"
        case weeklyAllKind:
            return weeklyLabel("all models")
        case weeklyScopedKind:
            return weeklyLabel(nonEmpty(scopeModel) ?? "one model")
        default:
            guard let raw = nonEmpty(kind) ?? nonEmpty(group) else { return "Limit" }
            let words = raw.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    static func merged(
        fresh: [LimitBucket],
        previous: [LimitBucket],
        now: Date,
        previousFetchedAt: Date?
    ) -> [LimitBucket] {
        let freshIDs = Set(fresh.map(\.id))
        let kept = previous.filter { !freshIDs.contains($0.id) }.map { bucket -> LimitBucket in
            var copy = bucket.resetApplied(at: now, since: previousFetchedAt)
            copy.isActive = false
            return copy
        }
        return (fresh + kept).enumerated()
            .sorted { ($0.element.kind.claudeRank, $0.offset) < ($1.element.kind.claudeRank, $1.offset) }
            .map(\.element)
    }

    static func weeklyLabel(_ subject: String) -> String {
        "Current week (\(subject))"
    }

    static func relabeled(_ bucket: LimitBucket) -> LimitBucket {
        guard bucket.provider == .claude else { return bucket }
        let nextName: String
        let nextScope: String?
        switch bucket.kind {
        case .session:
            nextName = label(kind: sessionKind, scopeModel: nil)
            nextScope = bucket.scope
        case .weeklyAll:
            nextName = label(kind: weeklyAllKind, scopeModel: nil)
            nextScope = bucket.scope
        case .weeklyScoped:
            let model = scopedModel(fromStoredName: bucket.name)
            nextName = label(kind: weeklyScopedKind, scopeModel: model)
            nextScope = bucket.scope ?? model.map(legacyModelScope)
        default:
            return bucket
        }
        guard nextName != bucket.name || nextScope != bucket.scope else { return bucket }
        var copy = bucket
        copy.name = nextName
        copy.scope = nextScope
        return copy
    }

    static func scopedModel(fromStoredName name: String) -> String? {
        var remainder = name
        for prefix in ["Week · ", "Week • "] where remainder.hasPrefix(prefix) {
            remainder = String(remainder.dropFirst(prefix.count))
        }
        if remainder.hasPrefix("Current week ("), remainder.hasSuffix(")") {
            remainder = String(remainder.dropFirst("Current week (".count).dropLast())
        }
        if remainder.isEmpty { return nil }
        for placeholder in ["pinned model", "one model"]
        where remainder.compare(placeholder, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        return remainder
    }

    private static func scope(for entry: ClaudeLimitEntry, kind: LimitBucket.Kind) -> String? {
        switch kind {
        case .weeklyScoped:
            if let modelID = nonEmpty(entry.modelID) {
                return "model:\(modelID)"
            }
            return nonEmpty(entry.modelName).map(legacyModelScope)
        case .other:
            return nonEmpty(entry.kind) ?? nonEmpty(entry.group)
        default:
            return nil
        }
    }

    private static func legacyModelScope(_ displayName: String) -> String {
        "model-name:\(displayName.lowercased())"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func kind(for rawKind: String?) -> LimitBucket.Kind {
        switch rawKind {
        case sessionKind: return .session
        case weeklyAllKind: return .weeklyAll
        case weeklyScopedKind: return .weeklyScoped
        default: return .other
        }
    }

    private static func windowSeconds(kind: String?, group: String?) -> Int? {
        switch kind {
        case sessionKind: return 5 * hour
        case weeklyAllKind, weeklyScopedKind: return week
        default: break
        }
        switch group {
        case "session": return 5 * hour
        case "daily": return 24 * hour
        case "weekly": return week
        case "monthly": return 30 * 24 * hour
        default: return nil
        }
    }

    private static func money(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
    }

    private static func clampPercent(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? 100 : 0 }
        return Int(max(0, min(100, value.rounded())))
    }

    private static func secondsUntil(_ date: Date?, from now: Date) -> Int? {
        guard let date else { return nil }
        return Int(max(0, min(Double(Int32.max), date.timeIntervalSince(now).rounded())))
    }
}

enum ClaudeUnifiedHeaders {
    private static let prefix = "anthropic-ratelimit-unified-"

    static func response(
        from headers: [AnyHashable: Any],
        scopedModelName: String?
    ) -> ClaudeUsageResponse? {
        var values: [String: String] = [:]
        for (key, value) in headers {
            guard let key = (key as? String)?.lowercased(), key.hasPrefix(prefix) else { continue }
            values[String(key.dropFirst(prefix.count))] = "\(value)".trimmingCharacters(in: .whitespaces)
        }
        let claim = values["representative-claim"]
        let windows: [(abbreviation: String, claim: String, kind: String, model: String?)] = [
            ("5h", "five_hour", ClaudeLimits.sessionKind, nil),
            ("7d", "seven_day", ClaudeLimits.weeklyAllKind, nil),
            ("7d_oi", "seven_day_overage_included", ClaudeLimits.weeklyScopedKind, scopedModelName),
        ]
        let limits = windows.compactMap { abbreviation, claimName, kind, model -> ClaudeLimitEntry? in
            guard let raw = values["\(abbreviation)-utilization"], let fraction = Double(raw), fraction.isFinite else {
                return nil
            }
            let reset = values["\(abbreviation)-reset"].flatMap(Double.init).flatMap(FlexibleDate.fromEpoch)
            return ClaudeLimitEntry(
                kind: kind,
                percent: fraction * 100,
                resetsAt: reset,
                modelName: model,
                isActive: claim == claimName
            )
        }
        guard !limits.isEmpty else { return nil }
        return ClaudeUsageResponse(limits: limits)
    }
}

private extension LimitBucket.Kind {
    var claudeRank: Int {
        switch self {
        case .session: return 0
        case .weeklyAll: return 1
        case .weeklyScoped: return 2
        case .other: return 3
        default: return 4
        }
    }
}

struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        (try? decodeIfPresent(Lenient<Value>.self, forKey: key))??.value
    }

    func lenientDate(forKey key: Key) -> Date? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return ISODate.parse(text) ?? Double(text).flatMap(FlexibleDate.fromEpoch)
        }
        return lenientDouble(forKey: key).flatMap(FlexibleDate.fromEpoch)
    }
}

enum FlexibleDate {
    static let earliest = Date(timeIntervalSince1970: 946_684_800)
    static let latest = Date(timeIntervalSince1970: 4_102_444_800)

    static func fromEpoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value >= 100_000_000_000 ? value / 1000 : value
        let date = Date(timeIntervalSince1970: seconds)
        return date >= earliest && date <= latest ? date : nil
    }
}

enum ISODate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }

        guard let dot = value.firstIndex(of: "."),
              let zoneStart = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        else {
            return nil
        }
        return plain.date(from: String(value[..<dot]) + String(value[zoneStart...]))
    }
}

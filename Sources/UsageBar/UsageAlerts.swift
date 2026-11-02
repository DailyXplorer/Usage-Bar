import Foundation

struct UsageAlertPreferences: Equatable {
    static let warnsKey = "notifyWhenLow"
    static let warnAtKey = "notifyWarnAtPercentLeft"
    static let resetsKey = "notifyOnReset"
    static let warnAtChoices = [50, 30, 20, 10]
    static let defaultWarnAt = 20

    var warnsWhenLow = true
    var warnAtPercentLeft = defaultWarnAt
    var notifiesOnReset = true

    static func load(from defaults: UserDefaults) -> UsageAlertPreferences {
        var preferences = UsageAlertPreferences()
        if defaults.object(forKey: warnsKey) != nil {
            preferences.warnsWhenLow = defaults.bool(forKey: warnsKey)
        }
        if warnAtChoices.contains(defaults.integer(forKey: warnAtKey)) {
            preferences.warnAtPercentLeft = defaults.integer(forKey: warnAtKey)
        }
        if defaults.object(forKey: resetsKey) != nil {
            preferences.notifiesOnReset = defaults.bool(forKey: resetsKey)
        }
        return preferences
    }

    func save(to defaults: UserDefaults) {
        defaults.set(warnsWhenLow, forKey: Self.warnsKey)
        defaults.set(warnAtPercentLeft, forKey: Self.warnAtKey)
        defaults.set(notifiesOnReset, forKey: Self.resetsKey)
    }
}

struct UsageAlert: Equatable {
    enum Kind: String {
        case low, reached, reset
    }

    let kind: Kind
    let key: String
    let title: String
    let body: String
}

struct UsageAlertLedger: Codable, Equatable {
    static let defaultsKey = "usageAlertLedger"
    static let periodTolerance: TimeInterval = 30 * 60
    static let keepAfterPeriod: TimeInterval = 8 * 24 * 60 * 60

    struct Record: Codable, Equatable {
        var periodEnd: Date
        var warnedAt: [Int] = []
        var reachedNotified = false
    }

    var records: [String: Record] = [:]

    static func load(from defaults: UserDefaults) -> UsageAlertLedger {
        guard let data = defaults.data(forKey: defaultsKey),
              let ledger = try? JSONDecoder().decode(UsageAlertLedger.self, from: data)
        else {
            return UsageAlertLedger()
        }
        return ledger
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

enum UsageAlerts {
    static func evaluate(
        provider: LimitBucket.Provider,
        buckets: [LimitBucket],
        preferences: UsageAlertPreferences,
        ledger: UsageAlertLedger,
        now: Date
    ) -> (alerts: [UsageAlert], ledger: UsageAlertLedger) {
        var next = ledger
        var alerts: [UsageAlert] = []
        var seen: Set<String> = []
        for bucket in buckets where bucket.provider == provider && bucket.drivesMenuBar {
            let key = bucket.alertKey
            seen.insert(key)
            var record = next.records[key]
            guard let resetAt = bucket.resetAt else {
                if let previous = record, previous.periodEnd <= now, bucket.usedPercent == 0 {
                    if preferences.notifiesOnReset {
                        alerts.append(alert(.reset, for: bucket, now: now))
                    }
                    next.records[key] = nil
                }
                continue
            }
            guard resetAt > now else { continue }
            if let previous = record, resetAt > previous.periodEnd.addingTimeInterval(UsageAlertLedger.periodTolerance) {
                if preferences.notifiesOnReset {
                    alerts.append(alert(.reset, for: bucket, now: now))
                }
                record = nil
            }
            var current = record ?? UsageAlertLedger.Record(periodEnd: resetAt)
            current.periodEnd = max(current.periodEnd, resetAt)
            if preferences.warnsWhenLow, !current.reachedNotified {
                if bucket.reached || bucket.remainingPercent == 0 {
                    alerts.append(alert(.reached, for: bucket, now: now))
                    current.reachedNotified = true
                } else if bucket.remainingPercent <= preferences.warnAtPercentLeft,
                          !current.warnedAt.contains(where: { $0 <= preferences.warnAtPercentLeft }) {
                    alerts.append(alert(.low, for: bucket, now: now))
                    current.warnedAt.append(preferences.warnAtPercentLeft)
                }
            }
            let hasWarned = current.reachedNotified || !current.warnedAt.isEmpty
            next.records[key] = hasWarned ? current : nil
        }
        next.records = next.records.filter { key, record in
            if record.periodEnd < now.addingTimeInterval(-UsageAlertLedger.keepAfterPeriod) { return false }
            let ownedHere = key.hasPrefix("\(provider.rawValue)|")
            return !ownedHere || seen.contains(key) || record.periodEnd > now
        }
        return (alerts, next)
    }

    static func alert(_ kind: UsageAlert.Kind, for bucket: LimitBucket, now: Date) -> UsageAlert {
        let subject = "\(bucket.provider.title) \(windowPhrase(for: bucket))"
        let resets = bucket.resetAt.map { "Resets \(ClockText.at($0, relativeTo: now))." } ?? ""
        switch kind {
        case .low:
            return UsageAlert(kind: kind, key: bucket.alertKey, title: "\(subject): \(bucket.remainingPercent)% left", body: resets)
        case .reached:
            return UsageAlert(kind: kind, key: bucket.alertKey, title: "\(subject) reached", body: resets)
        case .reset:
            return UsageAlert(kind: kind, key: bucket.alertKey, title: "\(subject) has reset", body: "")
        }
    }

    static func windowPhrase(for bucket: LimitBucket) -> String {
        let length = lengthPhrase(forWindowSeconds: bucket.limitWindowSeconds)
        guard let qualifier = qualifier(for: bucket) else {
            if let length { return length }
            let name = bucket.name.lowercased()
            return name.hasSuffix("limit") ? name : "\(name) limit"
        }
        return "\(qualifier) \(length ?? "limit")"
    }

    private static func lengthPhrase(forWindowSeconds seconds: Int?) -> String? {
        switch WindowLabels.knownLabel(forWindowSeconds: seconds) {
        case WindowLabels.currentSession?: return "5-hour limit"
        case WindowLabels.dailyLimit?: return "daily limit"
        case WindowLabels.weeklyLimit?: return "weekly limit"
        case WindowLabels.monthlyLimit?: return "monthly limit"
        case WindowLabels.annualLimit?: return "annual limit"
        default: return nil
        }
    }

    private static func qualifier(for bucket: LimitBucket) -> String? {
        switch bucket.kind {
        case .weeklyScoped, .other:
            if let open = bucket.name.lastIndex(of: "("), let close = bucket.name.lastIndex(of: ")"), open < close {
                return String(bucket.name[bucket.name.index(after: open)..<close])
            }
            return bucket.kind == .other ? nil : bucket.name
        case .additional:
            let suffixes = [
                WindowLabels.fiveHourLimit, WindowLabels.dailyLimit, WindowLabels.weeklyLimit,
                WindowLabels.monthlyLimit, WindowLabels.annualLimit, WindowLabels.secondaryLimit,
            ]
            for suffix in suffixes where bucket.name.hasSuffix(" \(suffix)") {
                return String(bucket.name.dropLast(suffix.count + 1))
            }
            return bucket.name
        case .cursorModels, .otherModels, .grokBot:
            return bucket.name
        default:
            return nil
        }
    }
}

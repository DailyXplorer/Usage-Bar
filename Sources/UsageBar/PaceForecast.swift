import Foundation

enum PaceForecast {
    static let quietFraction = 0.05
    static let minimumUsedPercent = 3.0

    static func timeToExhaustion(
        windowSeconds: Int?,
        usedPercent: Double,
        resetAt: Date?,
        now: Date
    ) -> TimeInterval? {
        guard let windowSeconds, windowSeconds > 0, let resetAt, usedPercent.isFinite else { return nil }
        let window = TimeInterval(windowSeconds)
        let untilReset = resetAt.timeIntervalSince(now)
        let elapsed = window - untilReset
        guard untilReset > 0,
              elapsed >= window * quietFraction,
              usedPercent >= minimumUsedPercent,
              usedPercent < 100
        else {
            return nil
        }
        let exhaustion = (100 - usedPercent) * elapsed / usedPercent
        return exhaustion < untilReset ? exhaustion : nil
    }

    static func text(for bucket: LimitBucket, at date: Date) -> String? {
        guard bucket.isTimeWindow, !bucket.reached,
              let seconds = timeToExhaustion(
                  windowSeconds: bucket.limitWindowSeconds,
                  usedPercent: Double(bucket.usedPercent),
                  resetAt: bucket.resetAt,
                  now: date
              )
        else {
            return nil
        }
        return "Runs out in ~\(UsageModel.durationString(seconds: max(60, Int(seconds.rounded())))) at this pace"
    }
}

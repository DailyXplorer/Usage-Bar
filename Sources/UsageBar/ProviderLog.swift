import Foundation
import os

struct ProviderRejection: Equatable {
    var provider: String
    var endpoint: String
    var status: Int
    var errorType: String?
    var retryAfter: String?

    init(provider: String, endpoint: String, status: Int, errorType: String?, retryAfter: String?) {
        self.provider = provider
        self.endpoint = endpoint
        self.status = status
        self.errorType = errorType
        self.retryAfter = retryAfter
    }

    init(provider: String, endpoint: String, response: HTTPURLResponse, body: Data? = nil) {
        self.init(
            provider: provider,
            endpoint: endpoint,
            status: response.statusCode,
            errorType: body.flatMap(AnthropicErrorEnvelope.type(in:)),
            retryAfter: Self.retryAfter(from: response)
        )
    }

    var line: String {
        var parts = [provider, endpoint, "status=\(status)"]
        if let type = Self.safeErrorType(errorType) {
            parts.append("error_type=\(type)")
        }
        if let delay = Self.safeRetryAfter(retryAfter) {
            parts.append("retry_after=\(delay)")
        }
        return parts.joined(separator: " ")
    }

    static func safeErrorType(_ value: String?) -> String? {
        guard let value, value.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static func safeRetryAfter(_ value: String?) -> String? {
        guard let value,
              value.range(
                of: #"^([0-9]{1,10}|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func retryAfter(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }
        if header.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return header
        }
        return RetryAfter.date(from: header).map { ISO8601DateFormatter().string(from: $0) }
    }
}

enum ProviderLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.usagebar.app"

    static func rejected(
        _ provider: LimitBucket.Provider,
        endpoint: String,
        response: HTTPURLResponse,
        body: Data? = nil
    ) {
        guard !(200..<300).contains(response.statusCode) else { return }
        let rejection = ProviderRejection(provider: provider.rawValue, endpoint: endpoint, response: response, body: body)
        Logger(subsystem: subsystem, category: provider.rawValue).notice("\(rejection.line, privacy: .public)")
    }
}

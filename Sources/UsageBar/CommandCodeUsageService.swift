import Foundation

struct CommandCodeCredentials {
    let apiKey: String
}

enum CommandCodeUsageError: LocalizedError {
    case notSignedIn
    case invalidKey
    case throttled
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Command Code key. Run `cmd login` in your terminal."
        case .invalidKey:
            return "Command Code API key is invalid. Run `cmd login` again."
        case .throttled:
            return "Command Code usage endpoint is rate limited. Retrying at the next refresh."
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "Command Code returned HTTP \(code). Run `cmd login`."
        case .decoding(let message):
            return "Unreadable Command Code response: \(message)"
        }
    }
}

actor CommandCodeUsageService {
    static let defaultBaseURL = URL(string: "https://api.commandcode.ai")!

    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = CommandCodeUsageService.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchUsage() async throws -> (usage: CommandCodeUsageSnapshot, credentials: CommandCodeCredentials) {
        let credentials = try Self.loadCredentials(
            from: Self.authFileCandidates(),
            environment: ProcessInfo.processInfo.environment
        )
        let whoami: CommandCodeWhoamiResponse = try await get(
            path: "/alpha/whoami",
            token: credentials.apiKey
        )
        let orgId = whoami.org?.id
        async let subscriptionsResult: CommandCodeSubscriptionsResponse = get(
            path: "/alpha/billing/subscriptions",
            token: credentials.apiKey,
            query: Self.query(orgId: orgId)
        )
        async let creditsResult: CommandCodeCreditsResponse = get(
            path: "/alpha/billing/credits",
            token: credentials.apiKey,
            query: Self.query(orgId: orgId)
        )
        let subscriptions = try await subscriptionsResult
        let credits = try await creditsResult
        var monthlyUsed: Double?
        do {
            let summary: CommandCodeSummaryResponse = try await get(
                path: "/alpha/usage/summary",
                token: credentials.apiKey,
                query: Self.query(orgId: orgId, since: subscriptions.data?.currentPeriodStart)
            )
            monthlyUsed = summary.totalMonthlyCredits
        } catch let error as CommandCodeUsageError {
            switch error {
            case .throttled, .invalidKey:
                throw error
            default:
                monthlyUsed = nil
            }
        } catch {
            monthlyUsed = nil
        }
        let snapshot = CommandCodeUsageSnapshot(
            planId: subscriptions.data?.planId,
            subscriptionStatus: subscriptions.data?.status,
            currentPeriodEnd: subscriptions.data?.currentPeriodEnd,
            credits: credits.credits,
            windowLimits: credits.windowLimits,
            monthlyUsed: monthlyUsed
        )
        return (snapshot, credentials)
    }

    nonisolated static func authFileCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [home.appendingPathComponent(".commandcode/auth.json")]
    }

    nonisolated static func loadCredentials(
        from files: [URL],
        environment: [String: String] = [:]
    ) throws -> CommandCodeCredentials {
        for name in ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"] {
            if let key = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return CommandCodeCredentials(apiKey: key)
            }
        }
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let auth = try? JSONDecoder().decode(CommandCodeAuthFile.self, from: data),
                  let apiKey = auth.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                continue
            }
            return CommandCodeCredentials(apiKey: apiKey)
        }
        throw CommandCodeUsageError.notSignedIn
    }

    private func get<T: Decodable>(
        path: String,
        token: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: baseURL.appending(path: trimmed),
            resolvingAgainstBaseURL: false
        ) else {
            throw CommandCodeUsageError.network("invalid url")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw CommandCodeUsageError.network("invalid url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CommandCodeUsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CommandCodeUsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw CommandCodeUsageError.invalidKey
            }
            if http.statusCode == 429 {
                throw CommandCodeUsageError.throttled
            }
            throw CommandCodeUsageError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CommandCodeUsageError.decoding(error.localizedDescription)
        }
    }

    private static func query(orgId: String?, since: String? = nil) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let orgId, !orgId.isEmpty {
            items.append(URLQueryItem(name: "orgId", value: orgId))
        }
        if let since, !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        return items
    }
}

private struct CommandCodeAuthFile: Decodable {
    let apiKey: String?
}

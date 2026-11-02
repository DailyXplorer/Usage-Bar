import Foundation

enum CursorUsageError: LocalizedError {
    case notSignedIn
    case unreadableLogin
    case tokenExpired
    case throttled(retryAfter: Date?)
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Cursor. Sign in to the Cursor editor, or paste a Cursor session token in Settings."
        case .unreadableLogin:
            return "Usage Bar couldn’t open the Cursor sign-in. Allow Keychain access, or paste a Cursor session token in Settings."
        case .tokenExpired:
            return "Cursor sign-in expired. Open Cursor to renew it, or paste a new session token in Settings."
        case .throttled:
            return "Cursor paused usage updates. Usage Bar will try again later."
        case .network:
            return "Can’t reach Cursor. Check your connection."
        case .httpStatus:
            return "Cursor isn’t responding right now. Usage Bar will try again."
        case .decoding:
            return "Cursor sent usage in a format Usage Bar can’t read. Check for a Usage Bar update."
        }
    }
}

actor CursorUsageService {
    static let defaultBaseURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/")!
    private static let planInfoLifetime: TimeInterval = 60 * 60

    private let baseURL: URL
    private let session: URLSession
    private let credentials: CursorCredentialLoader
    private let now: @Sendable () -> Date
    private var planInfoCache: (token: String, info: CursorPlanInfoResponse, expiresAt: Date)?

    init(
        baseURL: URL = CursorUsageService.defaultBaseURL,
        session: URLSession = ProviderSession.shared,
        credentials: CursorCredentialLoader = .live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.credentials = credentials
        self.now = now
    }

    func fetchUsage() async throws -> CursorUsageSnapshot {
        let login = try await credentials.load()
        async let periodData = post("GetCurrentPeriodUsage", token: login.accessToken)
        async let sandStatus = fetchSand(token: login.accessToken)
        let period: CursorUsageResponse = try decode(try await periodData)
        let sand = try await sandStatus

        var planInfo: CursorPlanInfoResponse?
        if sand?.isUnified != true, period.planUsage != nil {
            planInfo = await fetchPlanInfo(token: login.accessToken)
        }
        return CursorUsageSnapshot(
            period: period,
            sand: sand,
            planInfo: planInfo,
            membershipType: login.membershipType
        )
    }

    private func fetchSand(token: String) async throws -> CursorSandUsageStatus? {
        do {
            let data = try await post("GetSandUsageStatus", token: token)
            return try? JSONDecoder().decode(CursorSandUsageStatus.self, from: data)
        } catch CursorUsageError.httpStatus(let code) where (400..<500).contains(code) {
            return nil
        } catch CursorUsageError.tokenExpired {
            return nil
        }
    }

    private func fetchPlanInfo(token: String) async -> CursorPlanInfoResponse? {
        let date = now()
        if let planInfoCache, planInfoCache.token == token, planInfoCache.expiresAt > date {
            return planInfoCache.info
        }
        guard let data = try? await post("GetPlanInfo", token: token),
              let info = try? JSONDecoder().decode(CursorPlanInfoResponse.self, from: data) else {
            return planInfoCache?.token == token ? planInfoCache?.info : nil
        }
        var expiresAt = date.addingTimeInterval(Self.planInfoLifetime)
        if let resetAt = info.weeklyResetAt, resetAt > date {
            expiresAt = min(expiresAt, resetAt)
        }
        planInfoCache = (token, info, expiresAt)
        return info
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CursorUsageError.decoding(String(describing: type(of: error)))
        }
    }

    private func post(_ method: String, token: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CursorUsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CursorUsageError.network("invalid response")
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw CursorUsageError.tokenExpired
        case 429:
            throw CursorUsageError.throttled(retryAfter: RetryAfter.date(from: http))
        default:
            throw CursorUsageError.httpStatus(http.statusCode)
        }
    }
}

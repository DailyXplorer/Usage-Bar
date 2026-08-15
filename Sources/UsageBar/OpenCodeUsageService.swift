import Foundation

struct OpenCodeCredentials {
    let apiKey: String
}

enum OpenCodeUsageError: LocalizedError {
    case notSignedIn
    case invalidKey
    case notSubscribed
    case throttled
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No OpenCode Go key. Run `/connect` in OpenCode and select OpenCode Go."
        case .invalidKey:
            return "OpenCode Go API key is invalid. Run `/connect` in OpenCode."
        case .notSubscribed:
            return "OpenCode Go subscription required. Subscribe at opencode.ai, then try again."
        case .throttled:
            return "OpenCode Go usage endpoint is rate limited. Retrying at the next refresh."
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "OpenCode returned HTTP \(code). Run `/connect` in OpenCode."
        case .decoding(let message):
            return "Unreadable OpenCode response: \(message)"
        }
    }
}

actor OpenCodeUsageService {
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    func fetchUsage() async throws -> (usage: OpenCodeUsageResponse, credentials: OpenCodeCredentials) {
        let credentials = try Self.loadCredentials(from: Self.authFileCandidates())

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenCodeUsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeUsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw OpenCodeUsageError.invalidKey
            }
            if http.statusCode == 403 {
                throw OpenCodeUsageError.notSubscribed
            }
            if http.statusCode == 429 {
                throw OpenCodeUsageError.throttled
            }
            throw OpenCodeUsageError.httpStatus(http.statusCode)
        }

        do {
            return (try JSONDecoder().decode(OpenCodeUsageResponse.self, from: data), credentials)
        } catch {
            throw OpenCodeUsageError.decoding(error.localizedDescription)
        }
    }

    nonisolated static func authFileCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var files: [URL] = []
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            files.append(
                URL(fileURLWithPath: xdg, isDirectory: true)
                    .appendingPathComponent("opencode", isDirectory: true)
                    .appendingPathComponent("auth.json")
            )
        }
        files.append(home.appendingPathComponent(".local/share/opencode/auth.json"))
        files.append(home.appendingPathComponent("Library/Application Support/opencode/auth.json"))

        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    nonisolated static func loadCredentials(from files: [URL]) throws -> OpenCodeCredentials {
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let auth = try? JSONDecoder().decode(OpenCodeAuthFile.self, from: data),
                  let apiKey = auth.opencodeGo?.key, !apiKey.isEmpty else {
                continue
            }
            return OpenCodeCredentials(apiKey: apiKey)
        }
        throw OpenCodeUsageError.notSignedIn
    }
}

private struct OpenCodeAuthFile: Decodable {
    struct Entry: Decodable {
        let key: String?
    }

    let opencodeGo: Entry?

    enum CodingKeys: String, CodingKey {
        case opencodeGo = "opencode-go"
    }
}

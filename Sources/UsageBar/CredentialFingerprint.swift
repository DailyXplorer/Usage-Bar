import CryptoKit
import Foundation

enum CredentialFingerprint {
    static func make(_ secret: String) -> String? {
        guard !secret.isEmpty else { return nil }
        return SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

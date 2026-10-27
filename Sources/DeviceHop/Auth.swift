import CryptoKit
import Foundation

/// Signs messages with the shared key (HMAC-SHA256) so the key itself never goes over the air.
/// The timestamp plus a seen-signature cache stops replays of captured requests.
enum Auth {
    static let window: Int64 = 120_000

    private static var seen: [String: Date] = [:]

    static func sign(_ m: Message, key: String) -> Message {
        var m = m
        m.key = nil
        m.ts = Int64(Date().timeIntervalSince1970 * 1000)
        m.sig = mac(m, key: key)
        return m
    }

    /// True for a fresh, correctly signed message that hasn't been seen before.
    static func verify(_ m: Message, key: String) -> Bool {
        guard !key.isEmpty, let ts = m.ts, let sig = m.sig else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(now - ts) < window, sig == mac(m, key: key) else { return false }
        let cutoff = Date().addingTimeInterval(-Double(window) / 1000 * 2)
        seen = seen.filter { $0.value > cutoff }
        guard seen[sig] == nil else { return false }
        seen[sig] = Date()
        return true
    }

    private static func mac(_ m: Message, key: String) -> String {
        let body = [
            m.cmd,
            String(m.ts ?? 0),
            (m.addresses ?? []).joined(separator: ","),
            m.ok.map { $0 ? "1" : "0" } ?? "",
            m.error ?? "",
        ].joined(separator: "|")
        let code = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

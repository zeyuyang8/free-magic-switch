import Foundation

/// Checks npm for a newer release and reinstalls from the matching GitHub tag.
final class Updater {
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DeviceHop-update.log")

    func latestVersion(completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://registry.npmjs.org/free-magic-switch/latest")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let version = (json?["version"] as? String).flatMap { Updater.isValid($0) ? $0 : nil }
            DispatchQueue.main.async { completion(version) }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// The version ends up in a shell command, so only plain x.y.z is accepted.
    static func isValid(_ v: String) -> Bool {
        v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    /// Runs the installer detached; on success it replaces and relaunches this app.
    func install(_ version: String, onFailure: @escaping () -> Void) throws {
        guard Updater.isValid(version) else { throw CocoaError(.featureUnsupported) }
        let tag = "v\(version)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [
            "-c",
            "curl -fsSL \"https://raw.githubusercontent.com/zeyuyang8/free-magic-switch/$1/install.sh\" | DEVICEHOP_REF=\"$1\" bash > \"$2\" 2>&1",
            "bash", tag, Updater.logURL.path,
        ]
        p.terminationHandler = { _ in
            DispatchQueue.main.async { onFailure() }
        }
        try p.run()
    }
}

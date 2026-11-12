import Foundation

/// Persists the expected startup before the swap. It lives beside the backup so
/// an interrupted helper or an install on quit can be confirmed on a later launch.
struct UpdateStartup: Codable {
    let token: UUID
    let version: String

    static func pending(for app: URL) -> URL {
        app.deletingLastPathComponent().appending(path: ".\(app.lastPathComponent).updater-startup")
    }

    static func confirmation(for app: URL) -> URL {
        app.deletingLastPathComponent().appending(path: ".\(app.lastPathComponent).updater-ready")
    }

    static func begin(for app: URL, version: String) throws -> Self {
        let record = Self(token: UUID(), version: version)
        try JSONEncoder().encode(record).write(to: pending(for: app), options: .atomic)
        return record
    }

    static func acknowledge(for app: URL, version: String) {
        guard let record = read(for: app), ReleaseInfo.versionsMatch(record.version, version) else { return }
        try? Data(record.token.uuidString.utf8).write(to: confirmation(for: app), options: .atomic)
    }

    static func read(for app: URL) -> Self? {
        guard let data = try? Data(contentsOf: pending(for: app)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func isAcknowledged(for app: URL) -> Bool {
        (try? String(contentsOf: Self.confirmation(for: app), encoding: .utf8)) == token.uuidString
    }

    static func clear(for app: URL) {
        try? FileManager.default.removeItem(at: pending(for: app))
        try? FileManager.default.removeItem(at: confirmation(for: app))
    }
}

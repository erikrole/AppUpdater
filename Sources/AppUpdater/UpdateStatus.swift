import Foundation

extension AppUpdater {
    /// The result of this app's own update checks, readable by another app on the same Mac.
    /// This snapshot contains version numbers, a timestamp, and the current restart state.
    public struct Status: Codable, Equatable, Sendable {
        public let installedVersion: String
        public let latestVersion: String
        public let lastSuccessfulCheck: Date
        public let channel: UpdateChannel
        public let restartRequired: Bool

        public static func read(bundleIdentifier: String) -> Self? {
            guard !bundleIdentifier.isEmpty,
                  let data = UserDefaults.standard.persistentDomain(forName: bundleIdentifier)?[Keys.status] as? Data else {
                return nil
            }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
    }

    func recordStatus(latestVersion: String? = nil, checkedAt: Date? = nil) {
        let prior = defaults.data(forKey: Keys.status).flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
        let channel = configuration.channel()
        if checkedAt == nil, prior?.channel != channel { return }
        guard let date = checkedAt ?? prior?.lastSuccessfulCheck,
              let latest = latestVersion ?? prior?.latestVersion else { return }
        let restartRequired: Bool
        if case .ready = state { restartRequired = true } else { restartRequired = false }
        let snapshot = Status(installedVersion: configuration.currentVersion, latestVersion: latest,
                              lastSuccessfulCheck: date, channel: channel, restartRequired: restartRequired)
        guard snapshot != prior, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.status)
    }
}

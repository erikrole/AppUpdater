import AppKit

extension AppUpdater {
    /// A verified update was swapped in but its startup has not yet been confirmed.
    public static func hasUnconfirmedUpdate(at app: URL) -> Bool {
        guard let startup = UpdateStartup.read(for: app), !startup.isAcknowledged(for: app) else { return false }
        return FileManager.default.fileExists(atPath: UpdateInstaller.backupURL(for: app).path)
    }

    /// Restore the previous bundle after an unsuccessful startup. Intended for an explicit
    /// action in a companion app. The target must be closed and both bundles must match the update record.
    public static func restoreUnconfirmedUpdate(at app: URL, bundleIdentifier: String,
                                                teamID: String = "T26T3G8C7Q") async throws {
        try UpdateInstaller.checkInstallable(app)
        let lease = try UpdateInstaller.InstallationLock(destination: app)
        defer { withExtendedLifetime(lease) {} }
        let backup = UpdateInstaller.backupURL(for: app)
        func isClosed() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
        guard isClosed() else { throw UpdateInstaller.Failure(message: "Quit the app before restoring its previous version.") }
        guard let startup = UpdateStartup.read(for: app), !startup.isAcknowledged(for: app),
              let version = UpdateInstaller.bundleInfo(app)?["CFBundleShortVersionString"] as? String,
              let previous = UpdateInstaller.bundleInfo(backup)?["CFBundleShortVersionString"] as? String,
              ReleaseInfo.versionsMatch(version, startup.version), ReleaseInfo.isNewer(version, than: previous),
              UpdateInstaller.bundleInfo(app)?["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateInstaller.Failure(message: "No matching unconfirmed update was found.")
        }
        let configuration = Configuration(repository: "unused/unused", assetName: "", bundleIdentifier: bundleIdentifier,
                                          teamID: teamID, appURL: app, currentVersion: version)
        try ZIPArchive.validateContents(in: backup)
        try await UpdateInstaller.verify(backup, configuration: configuration)
        try Task.checkCancellation()
        guard isClosed(), !startup.isAcknowledged(for: app) else {
            throw UpdateInstaller.Failure(message: "The app started while its backup was being verified.")
        }
        try UpdateInstaller.rollback(destination: app, backup: backup)
    }
}

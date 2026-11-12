import Foundation

/// The release gate uses the same preparation and verification as installed apps.
@MainActor
package enum ReleaseVerification {
    package static func check(previous: URL, archive: URL, version: String, sha256: String?) async throws {
        guard let info = UpdateInstaller.bundleInfo(previous),
              let bundleID = info["CFBundleIdentifier"] as? String,
              let previousVersion = info["CFBundleShortVersionString"] as? String,
              ReleaseInfo.isNewer(version, than: previousVersion) else {
            throw UpdateInstaller.Failure(message: "Supply a previous app bundle and a newer candidate version.")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "AppUpdater-release-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let destination = root.appending(path: previous.lastPathComponent)
        try fm.copyItem(at: previous, to: destination)

        let configuration = AppUpdater.Configuration(repository: "unused/unused", assetName: archive.lastPathComponent,
                                                      bundleIdentifier: bundleID, appURL: destination, currentVersion: previousVersion)
        try await UpdateInstaller.verify(destination, configuration: configuration)
        let release = ReleaseInfo(version: version, notes: "", downloadURL: archive, archiveSHA256: sha256)
        let prepared = try await UpdateInstaller.prepare(release: release, destination: destination,
                                                          configuration: configuration, localArchive: archive) { _ in }
        defer {
            try? fm.removeItem(at: prepared.workDirectory)
            withExtendedLifetime(prepared.lease) {}
        }
        let backup = try UpdateInstaller.swap(destination: destination, with: prepared.staged)
        try await UpdateInstaller.verify(destination, release: release, configuration: configuration)
        try UpdateInstaller.rollback(destination: destination, backup: backup)
        try await UpdateInstaller.verify(destination, configuration: configuration)
        guard UpdateInstaller.bundleInfo(destination)?["CFBundleShortVersionString"] as? String == previousVersion else {
            throw UpdateInstaller.Failure(message: "The previous version was not restored in the test copy.")
        }
    }
}

import AppKit
import XCTest
@testable import AppUpdater

private let releaseJSON = """
{"tag_name":"v1.5.3","html_url":"https://github.com/erikrole/offload-releases/releases/tag/v1.5.3",
 "draft":false,"prerelease":false,"published_at":"2026-10-18T12:00:00Z",
 "body":"## Faster naming\\n- One folder per camera\\n- **Games never merge**",
 "assets":[{"name":"Offload.dmg","browser_download_url":"https://github.com/erikrole/offload-releases/releases/download/v1.5.3/Offload.dmg"},
           {"name":"Offload-1.5.3.dmg","browser_download_url":"https://github.com/erikrole/offload-releases/releases/download/v1.5.3/Offload-1.5.3.dmg"}]}
"""

final class ReleaseInfoTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(ReleaseInfo.isNewer("1.5.3", than: "1.5.2"))
        XCTAssertTrue(ReleaseInfo.isNewer("v1.10", than: "1.9.9"))
        XCTAssertFalse(ReleaseInfo.isNewer("1.5", than: "1.5.0"))
        XCTAssertFalse(ReleaseInfo.isNewer("1.4.9", than: "1.5.0"))
    }

    func testParsePrefersVersionedAssetAndKeepsNotes() throws {
        let release = try XCTUnwrap(ReleaseInfo.parse(Data(releaseJSON.utf8), assetName: "Offload.dmg"))
        XCTAssertEqual(release.version, "1.5.3")
        XCTAssertTrue(release.downloadURL.lastPathComponent == "Offload-1.5.3.dmg")
        XCTAssertTrue(release.notes.contains("Games never merge"))
        XCTAssertNotNil(release.date)
    }

    func testParseRejectsDraftsPrereleasesAndForeignHosts() {
        let draft = releaseJSON.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
        XCTAssertNil(ReleaseInfo.parse(Data(draft.utf8), assetName: "Offload.dmg"))
        let pre = releaseJSON.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")
        XCTAssertNil(ReleaseInfo.parse(Data(pre.utf8), assetName: "Offload.dmg"))
        let foreign = releaseJSON.replacingOccurrences(of: "https://github.com/", with: "https://evil.example/")
        XCTAssertNil(ReleaseInfo.parse(Data(foreign.utf8), assetName: "Offload.dmg"))
        XCTAssertNil(ReleaseInfo.parse(Data(releaseJSON.utf8), assetName: "Missing.dmg"))
    }
}

@MainActor
final class CheckFlowTests: XCTestCase {
    private func make(version: String, status: Int = 200, body: String = releaseJSON) -> AppUpdater {
        let defaults = UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        let updater = AppUpdater(
            .init(repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "com.erole.Offload", currentVersion: version),
            defaults: defaults
        )
        updater.fetch = { _ in (Data(body.utf8), status) }
        return updater
    }

    func testOffersNewerRelease() async {
        guard case let .available(release) = await make(version: "1.5.2").evaluate(userInitiated: false) else { return XCTFail() }
        XCTAssertEqual(release.version, "1.5.3")
    }

    func testCurrentIsQuiet() async {
        let outcome = await make(version: "1.5.3").evaluate(userInitiated: false)
        XCTAssertEqual(outcome, .upToDate)
    }

    func testOfflineAndBadStatusFail() async {
        let updater = make(version: "1.0")
        updater.fetch = { _ in throw URLError(.notConnectedToInternet) }
        guard case .failed = await updater.evaluate(userInitiated: false) else { return XCTFail() }
        guard case .failed = await make(version: "1.0", status: 403).evaluate(userInitiated: false) else { return XCTFail() }
    }

    func testSkippedVersionStaysQuietUnlessAskedFor() async throws {
        let updater = make(version: "1.5.2")
        guard case let .available(release) = await updater.evaluate(userInitiated: false) else { return XCTFail() }
        updater.skip(release)
        let later = Date().addingTimeInterval(7 * 3600)
        let skipped = await updater.evaluate(userInitiated: false, now: later)
        XCTAssertEqual(skipped, .skipped("1.5.3"))
        guard case .available = await updater.evaluate(userInitiated: true, now: later) else { return XCTFail() }
    }

    func testLaunchChecksAreRateLimited() async {
        let updater = make(version: "1.5.2")
        _ = await updater.evaluate(userInitiated: false)
        let second = await updater.evaluate(userInitiated: false)
        XCTAssertEqual(second, .tooSoon)
        guard case .available = await updater.evaluate(userInitiated: true) else { return XCTFail() }
        guard case .available = await updater.evaluate(userInitiated: false, now: Date().addingTimeInterval(7 * 3600)) else { return XCTFail() }
    }
}

final class InstallerTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTeamIDParsing() {
        let output = "Identifier=com.erole.Fetch\nTeamIdentifier=T26T3G8C7Q\nSealed Resources version=2"
        XCTAssertEqual(UpdateInstaller.teamID(in: output), "T26T3G8C7Q")
        XCTAssertNil(UpdateInstaller.teamID(in: "TeamIdentifier=not set".replacingOccurrences(of: "Team", with: "Nope")))
    }

    func testSwapKeepsBackupThenRollbackRestores() throws {
        let dir = try makeDirectory()
        let app = dir.appending(path: "X.app"), staged = dir.appending(path: ".X.app.update")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "old".write(to: app.appending(path: "v"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try "new".write(to: staged.appending(path: "v"), atomically: true, encoding: .utf8)

        let backup = try UpdateInstaller.swap(destination: app, with: staged)
        XCTAssertEqual(try String(contentsOf: app.appending(path: "v"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup.appending(path: "v"), encoding: .utf8), "old")

        UpdateInstaller.rollback(destination: app, backup: backup)
        XCTAssertEqual(try String(contentsOf: app.appending(path: "v"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testSwapFailureLeavesCurrentAppInPlace() throws {
        let dir = try makeDirectory()
        let app = dir.appending(path: "X.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateInstaller.swap(destination: app, with: dir.appending(path: "missing.app")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testRefusesTranslocatedAndMountedCopies() {
        XCTAssertThrowsError(try UpdateInstaller.checkInstallable(URL(filePath: "/Volumes/Offload/Offload.app")))
        XCTAssertThrowsError(try UpdateInstaller.checkInstallable(URL(filePath: "/private/var/folders/x/AppTranslocation/y/d/Offload.app")))
    }

    func testFindsAppByNameThenFirstApp() throws {
        let dir = try makeDirectory()
        for name in ["A.app", "B.app"] { try FileManager.default.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: true) }
        XCTAssertEqual(UpdateInstaller.findApp(in: dir, named: "B.app")?.lastPathComponent, "B.app")
        XCTAssertNotNil(UpdateInstaller.findApp(in: dir, named: "Z.app"))
    }

    /// Downloads the real Offload release and runs the full verify path. `APPUPDATER_LIVE=1 swift test`.
    @MainActor
    func testLiveOffloadReleaseVerifies() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPUPDATER_LIVE"] == "1")
        let dir = try makeDirectory()
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/erikrole/offload-releases/releases/latest")!)
        let release = try XCTUnwrap(ReleaseInfo.parse(data, assetName: "Offload.dmg"))
        let configuration = AppUpdater.Configuration(
            repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "com.erole.Offload",
            appURL: dir.appending(path: "Offload.app"), currentVersion: "0.0.1"
        )
        let prepared = try await UpdateInstaller.prepare(release: release, destination: configuration.appURL, configuration: configuration) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.staged.path))
        try? FileManager.default.removeItem(at: prepared.workDirectory)

        // A different bundle ID must be refused.
        var wrong = configuration
        wrong.bundleIdentifier = "com.example.Other"
        do {
            _ = try await UpdateInstaller.prepare(release: release, destination: wrong.appURL, configuration: wrong) { _ in }
            XCTFail("expected refusal")
        } catch {}
    }
}

@MainActor
final class RendererTests: XCTestCase {
    func testBulletsHeadingsAndBold() {
        let text = ReleaseNotesRenderer.render("## Faster\n- One **bold** thing\n- Two").string
        XCTAssertEqual(text, "Faster\n•  One bold thing\n•  Two")
    }
}

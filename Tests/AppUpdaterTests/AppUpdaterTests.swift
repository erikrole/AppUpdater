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

        try UpdateInstaller.rollback(destination: app, backup: backup)
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
        defer {
            try? FileManager.default.removeItem(at: prepared.staged)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            withExtendedLifetime(prepared.lease) {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.staged.path))

        // A different bundle ID must be refused.
        var wrong = configuration
        wrong.bundleIdentifier = "com.example.Other"
        do {
            try await UpdateInstaller.verify(prepared.staged, release: release, configuration: wrong)
            XCTFail("expected refusal")
        } catch { XCTAssertTrue((error as? UpdateInstaller.Failure)?.message.contains("isn't this app") == true) }
    }
}

@MainActor
final class RendererTests: XCTestCase {
    func testBulletsHeadingsAndBold() {
        let text = ReleaseNotesRenderer.render("## Faster\n- One **bold** thing\n- Two").string
        XCTAssertEqual(text, "Faster\n•  One bold thing\n•  Two")
    }
}

final class NotesTests: XCTestCase {
    func testSectionsSplitHeadlineTitlesAndBullets() {
        let parsed = ReleaseNotesSections(markdown: "## Faster naming\n- One\n- Two\n### Fixes\n- Three\nPlain line")
        XCTAssertEqual(parsed.headline, "Faster naming")
        XCTAssertEqual(parsed.sections.count, 2)
        XCTAssertNil(parsed.sections[0].title)
        XCTAssertEqual(parsed.sections[0].items, ["One", "Two"])
        XCTAssertEqual(parsed.sections[1].title, "Fixes")
        XCTAssertEqual(parsed.sections[1].items, ["Three", .init("Plain line", kind: .paragraph)])
    }

    func testPlainParagraphIsNotBulleted() {
        let parsed = ReleaseNotesSections(markdown: "Just fixes.")
        XCTAssertNil(parsed.headline)
        XCTAssertEqual(parsed.sections, [.init(title: nil, items: [.init("Just fixes.", kind: .paragraph)])])
    }

    @MainActor
    func testNotesNeverEmptyAndFallBackInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterNotes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        var configuration = AppUpdater.Configuration(repository: "a/b", assetName: "A.dmg", bundleIdentifier: "com.x.NotesTests-\(UUID().uuidString)", currentVersion: "1.0")
        let updater = AppUpdater(configuration, defaults: defaults)
        try? FileManager.default.removeItem(at: updater.notesCache.directory)
        let release = ReleaseInfo(version: "2.0", notes: "", downloadURL: URL(string: "https://github.com/a/b")!)
        let withNotes = ReleaseInfo(version: "2.0", notes: "- Real notes", downloadURL: release.downloadURL)
        XCTAssertEqual(updater.resolvedNotes(for: release), "Improvements and fixes.")

        configuration.fallbackNotes = "Host notes"
        let hosted = AppUpdater(configuration, defaults: defaults)
        XCTAssertEqual(hosted.resolvedNotes(for: release), "Host notes")

        // Once real notes were seen, they win over the host fallback when a later fetch has none.
        XCTAssertEqual(hosted.resolvedNotes(for: withNotes), "- Real notes")
        XCTAssertEqual(hosted.resolvedNotes(for: release), "- Real notes")
        try? FileManager.default.removeItem(at: hosted.notesCache.directory)
    }

    func testCacheRoundTrip() {
        let base = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = NotesCache(bundleIdentifier: "com.x.A", base: base)
        XCTAssertNil(cache.load(version: "1.0"))
        cache.save("hello", version: "1.0")
        XCTAssertEqual(cache.load(version: "1.0"), "hello")
        XCTAssertNil(cache.load(version: "1.1"))
    }
}

@MainActor
final class WindowTests: XCTestCase {
    func testWindowBuildsWithAndWithoutStyleAndEmptyNotes() {
        _ = NSApplication.shared
        for style in [AppUpdater.Style(), AppUpdater.Style(accentColor: .systemRed, title: { _, _ in "Custom" }, primaryButtonTitle: "Go")] {
            let updater = AppUpdater(
                .init(repository: "a/b", assetName: "A.dmg", bundleIdentifier: "com.x.A", currentVersion: "1.0", style: style),
                defaults: UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
            )
            for notes in ["", "## Head\n- **a** b\n### More\n- c", "no markdown at all"] {
                let release = ReleaseInfo(version: "2.0", notes: notes, downloadURL: URL(string: "https://github.com/a/b")!)
                for mode in [UpdateWindowController.Mode.available(release), .updated(release)] {
                    let controller = UpdateWindowController(mode: mode, updater: updater)
                    XCTAssertGreaterThan(controller.window?.contentView?.fittingSize.height ?? 0, 100)
                    controller.window?.close()
                }
            }
        }
    }
}

final class HardeningTests: XCTestCase {
    func testSweepRemovesLeftoversOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterSweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["X.app", ".X.app.backup", ".X.app.update-1234abcd", "Y.app", ".Y.app.backup"]
        for name in names { try FileManager.default.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: true) }
        UpdateInstaller.sweepLeftovers(for: dir.appending(path: "X.app"))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["X.app", "Y.app", ".Y.app.backup", ".X.app.updater-lock"])
    }

    func testSwapSucceedsWithStaleBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterStale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["X.app", ".X.app.backup", ".X.app.update-1"] {
            try FileManager.default.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: true)
        }
        let backup = try UpdateInstaller.swap(destination: dir.appending(path: "X.app"), with: dir.appending(path: ".X.app.update-1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "X.app").path))
    }

    @MainActor
    func testBadRepositoryNameIsRejected() async {
        let updater = AppUpdater(
            .init(repository: "not a repo/../x", assetName: "A.dmg", bundleIdentifier: "com.x.A", currentVersion: "1.0"),
            defaults: UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        )
        updater.fetch = { _ in XCTFail("must not fetch"); return (Data(), 200) }
        guard case .failed = await updater.evaluate(userInitiated: true) else { return XCTFail() }
    }

    func testWritableFolderIsAccepted() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterRO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try UpdateInstaller.checkInstallable(dir.appending(path: "X.app")))
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var hang = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if StubProtocol.hang { return }
        guard let (response, data) = StubProtocol.handler?(request) else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DownloaderTests: XCTestCase {
    private static func fetch(_ url: String) async throws -> Data {
        let target = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        let downloader = Downloader()
        downloader.protocolClasses = [StubProtocol.self]
        try await downloader.fetch(URL(string: url)!, to: target) { _ in }
        return try Data(contentsOf: target)
    }

    func testDownloadsBody() async throws {
        StubProtocol.hang = false
        StubProtocol.handler = { request in (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("dmg".utf8)) }
        let data = try await Self.fetch("https://github.com/a/b/x.dmg")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "dmg")
    }

    func testNon200AndTransportErrorsThrow() async {
        StubProtocol.hang = false
        StubProtocol.handler = { request in (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("nope".utf8)) }
        do { _ = try await Self.fetch("https://github.com/a/b/x.dmg"); XCTFail() } catch {
            XCTAssertTrue((error as? UpdateInstaller.Failure)?.message.contains("404") == true)
        }
        StubProtocol.handler = nil
        do { _ = try await Self.fetch("https://github.com/a/b/x.dmg"); XCTFail() } catch {}
    }

    func testNonHTTPSRedirectIsRefused() async {
        StubProtocol.hang = false
        StubProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://evil.example/x.dmg"])!, Data())
        }
        do { _ = try await Self.fetch("https://github.com/a/b/x.dmg"); XCTFail() } catch {}
    }

    func testCancellationResumesOnceWithCancellationError() async {
        StubProtocol.hang = true
        defer { StubProtocol.hang = false }
        let task = Task { try await Self.fetch("https://github.com/a/b/x.dmg") }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor
final class VerifyTests: XCTestCase {
    private func makeApp(version: String, bundleID: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterVerify-\(UUID().uuidString)")
        let app = dir.appending(path: "T.app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: "T"))
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "T", "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: app.appending(path: "Contents/Info.plist"), atomically: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return app
    }

    func testAdHocSignedAppIsRefused() async throws {
        let app = try makeApp(version: "2.0", bundleID: "com.x.T")
        _ = try UpdateInstaller.runSync("/usr/bin/codesign", ["-s", "-", "--force", app.path])
        let configuration = AppUpdater.Configuration(repository: "a/b", assetName: "T.dmg", bundleIdentifier: "com.x.T", currentVersion: "1.0")
        let release = ReleaseInfo(version: "2.0", notes: "", downloadURL: URL(string: "https://github.com/a/b")!)
        do { try await UpdateInstaller.verify(app, release: release, configuration: configuration); XCTFail("must refuse") } catch {
            XCTAssertTrue(error is UpdateInstaller.Failure)
        }
    }

    func testUnsignedAppIsRefused() async throws {
        let app = try makeApp(version: "2.0", bundleID: "com.x.T")
        let configuration = AppUpdater.Configuration(repository: "a/b", assetName: "T.dmg", bundleIdentifier: "com.x.T", currentVersion: "1.0")
        do { try await UpdateInstaller.verify(app, configuration: configuration); XCTFail("must refuse") } catch {}
    }
}

final class NestedNotesTests: XCTestCase {
    func testNestedBulletsNumbersAndCode() {
        let md = "## Head\n- Top\n  - Nested\n    - Deeper\n1. First\n2) Second\n```\nswift build\n```\nDone."
        let items = ReleaseNotesSections(markdown: md).sections[0].items
        XCTAssertEqual(items[0], .init("Top"))
        XCTAssertEqual(items[1], .init("Nested", kind: .bullet, level: 1))
        XCTAssertEqual(items[2], .init("Deeper", kind: .bullet, level: 2))
        XCTAssertEqual(items[3], .init("First", kind: .number("1."), level: 0))
        XCTAssertEqual(items[4], .init("Second", kind: .number("2)"), level: 0))
        XCTAssertEqual(items[5], .init("swift build", kind: .code))
        XCTAssertEqual(items[6], .init("Done.", kind: .paragraph))
    }
}

@MainActor
final class RealSignedVerifyTests: XCTestCase {
    private func scratchCopyOfOffload() throws -> URL {
        let source = URL(filePath: "/Applications/Offload.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))
        let dir = FileManager.default.temporaryDirectory.appending(path: "AppUpdaterReal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appending(path: "Offload.app")
        _ = try UpdateInstaller.runSync("/usr/bin/ditto", [source.path, copy.path])
        return copy
    }

    func testRealSignedAppPassesThenWrongTeamAndVersionAreRefused() async throws {
        let app = try scratchCopyOfOffload()
        let built = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let url = URL(string: "https://github.com/erikrole/offload-releases")!
        var configuration = AppUpdater.Configuration(repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "com.erole.Offload", currentVersion: "1.0")
        try await UpdateInstaller.verify(app, release: ReleaseInfo(version: built, notes: "", downloadURL: url), configuration: configuration)

        do {
            try await UpdateInstaller.verify(app, release: ReleaseInfo(version: "9.9.9", notes: "", downloadURL: url), configuration: configuration)
            XCTFail("version mismatch must be refused")
        } catch { XCTAssertTrue((error as? UpdateInstaller.Failure)?.message.contains("doesn't match") == true) }

        configuration.teamID = "AAAAAAAAAA"
        do { try await UpdateInstaller.verify(app, release: nil, configuration: configuration); XCTFail("wrong team must be refused") } catch {}

        configuration.teamID = "T26T3G8C7Q"
        configuration.bundleIdentifier = "com.example.Other"
        do { try await UpdateInstaller.verify(app, release: nil, configuration: configuration); XCTFail("wrong bundle ID must be refused") } catch {}
    }
}

@MainActor
final class LayoutTests: XCTestCase {
    private let long = "A very long bullet that must wrap onto several lines instead of running off the right edge of the card, including `inline code` and **bold text** to make sure styled runs wrap too."

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func makeWindow(notes: String) -> NSWindow {
        _ = NSApplication.shared
        let updater = AppUpdater(
            .init(repository: "a/b", assetName: "A.dmg", bundleIdentifier: "com.x.A", displayName: "A", currentVersion: "1.0"),
            defaults: UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        )
        let release = ReleaseInfo(version: "2.0", notes: notes, downloadURL: URL(string: "https://github.com/a/b")!, pageURL: URL(string: "https://github.com/a/b"))
        let controller = UpdateWindowController(mode: .available(release), updater: updater)
        addTeardownBlock { controller.window?.close() }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller.window!
    }

    func testLongNotesWrapInsideTheCardAndSkipStaysOneLine() throws {
        let window = makeWindow(notes: "## Head\n- \(long)\n  - Nested: \(long)\n1. Numbered: \(long)\nPlain: \(long)\n```\nswift build --configuration release --arguments-that-are-long-enough-to-wrap-around\n```")
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let views = allViews(content)
        let card = try XCTUnwrap(views.first { String(describing: type(of: $0)).contains("CardView") })
        let cardFrame = card.convert(card.bounds, to: nil)

        let labels = views.compactMap { $0 as? NSTextField }.filter { $0.isDescendant(of: card) && !$0.stringValue.isEmpty }
        XCTAssertGreaterThan(labels.count, 5)
        for label in labels {
            let frame = label.convert(label.bounds, to: nil)
            XCTAssertLessThanOrEqual(frame.maxX, cardFrame.maxX + 0.5, "'\(label.stringValue.prefix(30))' runs past the card")
            XCTAssertGreaterThanOrEqual(frame.minX, cardFrame.minX - 0.5)
            // A wrapped label is as tall as the lines its text needs at its own width.
            if label.stringValue.count > 80 {
                let needed = label.attributedStringValue.boundingRect(
                    with: NSSize(width: frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
                XCTAssertGreaterThanOrEqual(label.frame.height + 2, needed, "'\(label.stringValue.prefix(30))' is clipped")
            }
        }

        let link = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "View on GitHub" })
        XCTAssertFalse(link.isHidden)
        XCTAssertGreaterThan(link.frame.width, 60)
        XCTAssertGreaterThan(link.frame.height, 10)
        let skip = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Skip This Version" })
        XCTAssertLessThan(skip.frame.height, 30, "Skip This Version wrapped")
        XCTAssertGreaterThanOrEqual(skip.frame.width, skip.intrinsicContentSize.width - 0.5)
        for button in views.compactMap({ $0 as? NSButton }) where button.isDescendant(of: content) {
            XCTAssertLessThanOrEqual(button.convert(button.bounds, to: nil).maxX, content.bounds.maxX, "\(button.title) is cut off")
        }
    }
}

@MainActor
final class EventTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        @MainActor var events: [AppUpdater.Event] = []
    }

    private let release = ReleaseInfo(version: "2.0", notes: "- New", downloadURL: URL(string: "https://github.com/a/b/A.dmg")!)

    private func make(version: String = "1.0", defaults: UserDefaults? = nil, busy: String? = nil, log: Log) -> AppUpdater {
        _ = NSApplication.shared
        let json = """
        {"tag_name":"v2.0","draft":false,"prerelease":false,"body":"- New thing","html_url":"https://github.com/a/b/releases/tag/v2.0",
         "assets":[{"name":"A.dmg","browser_download_url":"https://github.com/a/b/A.dmg"}]}
        """
        let updater = AppUpdater(
            .init(repository: "a/b", assetName: "A.dmg", bundleIdentifier: "com.x.A", appURL: FileManager.default.temporaryDirectory.appending(path: "Nope-\(UUID().uuidString).app"),
                  currentVersion: version, busyReason: { busy }, onEvent: { event in log.events.append(event) }),
            defaults: defaults ?? UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        )
        updater.fetch = { _ in (Data(json.utf8), 200) }
        return updater
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testShownFromLaunchAndManualThenDeferredOnClose() async {
        for (userInitiated, trigger) in [(false, AppUpdater.Event.Trigger.launch), (true, .manual)] {
            let log = Log()
            let updater = make(log: log)
            await updater.check(userInitiated: userInitiated, trigger: trigger)
            await settle()
            XCTAssertEqual(log.events, [.init(kind: .shown, fromVersion: "1.0", toVersion: "2.0", trigger: trigger, error: nil)])
            updater.window?.window?.close()
            await settle()
            XCTAssertEqual(log.events.map(\.kind), [.shown, .deferred])
            XCTAssertEqual(log.events.last?.fromVersion, "1.0")
            XCTAssertEqual(log.events.last?.toVersion, "2.0")
        }
    }

    func testEventsAreDeliveredAfterTheCallNotInline() async {
        let log = Log()
        let updater = make(log: log)
        updater.skip(release)
        XCTAssertTrue(log.events.isEmpty, "the hook must not run inline")
        await settle()
        XCTAssertEqual(log.events.map(\.kind), [.skipped])
    }

    func testSkipIsNotFollowedByDeferred() async {
        let log = Log()
        let updater = make(log: log)
        await updater.check(userInitiated: false, trigger: .launch)
        updater.skip(release)
        updater.window?.window?.close()
        await settle()
        XCTAssertEqual(log.events.map(\.kind), [.shown, .skipped])
    }

    func testAcceptedThenFailedCarriesTheReason() async {
        let log = Log()
        let updater = make(busy: "Busy copying.", log: log)
        do { try await updater.install(release, progress: { _ in }, status: { _ in }); XCTFail() } catch {}
        await settle()
        XCTAssertEqual(log.events.map(\.kind), [.accepted, .failed])
        XCTAssertEqual(log.events.last?.error, "Busy copying.")
        XCTAssertEqual(log.events.last?.toVersion, "2.0")
    }

    func testInstalledIsReportedByTheNewVersionOnItsFirstLaunch() async {
        let defaults = UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        let oldLog = Log()
        make(version: "1.0", defaults: defaults, log: oldLog).rememberInstall(of: release)

        let newLog = Log()
        let updated = make(version: "2.0", defaults: defaults, log: newLog)
        updated.fetch = { _ in throw URLError(.notConnectedToInternet) }
        updated.checkOnLaunch()
        await settle()
        XCTAssertEqual(newLog.events, [.init(kind: .installed, fromVersion: "1.0", toVersion: "2.0", trigger: nil, error: nil)])
        updated.window?.window?.close()
        await settle()
        XCTAssertEqual(newLog.events.map(\.kind), [.installed], "closing the what's-new window is not a deferral")

        // Only once: the next launch reports nothing.
        let again = Log()
        let relaunch = make(version: "2.0", defaults: defaults, log: again)
        relaunch.fetch = { _ in throw URLError(.notConnectedToInternet) }
        relaunch.checkOnLaunch()
        await settle()
        XCTAssertTrue(again.events.isEmpty)
    }

    func testNoHookIsFine() async {
        _ = NSApplication.shared
        let updater = AppUpdater(.init(repository: "a/b", assetName: "A.dmg", bundleIdentifier: "com.x.A", currentVersion: "1.0"),
                                 defaults: UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!)
        updater.skip(release)
        await settle()
    }
}

final class RelaunchHelperTests: XCTestCase {
    /// The helper waits for the old process, then (here, with nothing openable at the destination) restores the backup. It must
    /// run on its own and finish without the test process doing anything more.
    func testHelperRunsDetachedAndRestoresTheBackupWhenTheNewAppWontOpen() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relaunch-\(UUID().uuidString)")
        let destination = root.appending(path: "New.app"), backup = root.appending(path: ".New.app.backup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: backup.appending(path: "marker"))
        defer { try? FileManager.default.removeItem(at: root) }

        try UpdateInstaller.scheduleRelaunch(destination: destination, backup: backup, waitingFor: 999_999)

        let restored = destination.appending(path: "marker")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: restored.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}

/// The update hang: a host that answers `.terminateLater` and replies from its own task must still be able to quit when the
/// updater asks. Runs a real AppKit host (QuitProbe), because terminating the test process itself would end the run.
final class RequestQuitTests: XCTestCase {
    private func probe() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "QuitProbe")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: url.path), "QuitProbe not built next to the tests")
        return url
    }

    /// True when the host exited by itself within `seconds`.
    private func exits(_ arguments: [String], within seconds: TimeInterval) throws -> Bool {
        let process = Process()
        process.executableURL = try probe()
        process.arguments = arguments
        try process.run()
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let done = !process.isRunning
        if !done { process.terminate(); Thread.sleep(forTimeInterval: 0.3); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        return done
    }

    func testRequestQuitLetsATerminateLaterHostExit() throws {
        XCTAssertTrue(try exits([], within: 10))
    }

    func testAStalledQuitIsFinishedByTheFallbackWhenTheHostSaysItIsSafe() throws {
        XCTAssertTrue(try exits(["--stalled"], within: 10))
    }

    func testAStalledQuitStaysOpenWhenTheHostSaysItIsNotSafe() throws {
        XCTAssertFalse(try exits(["--stalled", "--not-safe"], within: 6))
    }

    func testCancelledFallbackNeverForcesExit() throws {
        XCTAssertFalse(try exits(["--stalled", "--cancel-fallback"], within: 4))
    }

    func testCancellationWhileHostSavesNeverForcesExit() throws {
        XCTAssertFalse(try exits(["--stalled", "--cancel-during-save"], within: 4))
    }

    func testSheetOpenedWhileHostSavesPreventsForcedExit() throws {
        XCTAssertFalse(try exits(["--stalled", "--sheet-during-save"], within: 4))
    }

    func testTerminateCalledInsideATaskStillHangs() throws {
        // The negative control: this is the bug requestQuit exists to avoid.
        XCTAssertFalse(try exits(["--direct"], within: 5))
    }
}

final class PostUpdateTests: XCTestCase {
    @MainActor
    private func run(_ postUpdate: AppUpdater.PostUpdate) -> (shown: Bool, window: Bool, events: [AppUpdater.Event.Kind]) {
        let defaults = UserDefaults(suiteName: "AppUpdaterPostUpdate-\(UUID().uuidString)")!
        defaults.set(["version": "2.0", "notes": "- New", "from": "1.0"], forKey: AppUpdater.Keys.justUpdated)
        var events: [AppUpdater.Event.Kind] = []
        let configuration = AppUpdater.Configuration(repository: "a/b", assetName: "A.dmg", bundleIdentifier: "com.x.A", currentVersion: "2.0",
                                                     postUpdate: postUpdate, onEvent: { events.append($0.kind) })
        let updater = AppUpdater(configuration, defaults: defaults)
        let shown = updater.showJustUpdated()
        let hadWindow = updater.window != nil
        updater.window?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (shown, hadWindow, events)
    }

    @MainActor func testTheDefaultStillOpensTheUpdatedWindow() {
        let result = run(.window)
        XCTAssertTrue(result.shown && result.window)
    }

    @MainActor func testQuietOpensNoWindowButStillReportsInstalled() {
        let result = run(.quiet)
        XCTAssertFalse(result.shown)
        XCTAssertFalse(result.window)
        XCTAssertEqual(result.events, [.installed])
    }
}

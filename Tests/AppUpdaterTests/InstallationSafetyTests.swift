import AppKit
import XCTest
@testable import AppUpdater

final class InstallationSafetyTests: XCTestCase {
    private func fixture() throws -> (root: URL, app: URL, backup: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdaterSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Example.app"), backup = root.appending(path: ".Example.app.backup")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: app.appending(path: "marker"))
        return (root, app, backup)
    }

    func testMissingBackupNeverDeletesInstalledApp() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstaller.rollback(destination: f.app, backup: f.backup))
        XCTAssertEqual(try String(contentsOf: f.app.appending(path: "marker"), encoding: .utf8), "new")
    }

    func testSweepRestoresOnlySurvivingBackupAfterInterruptedSwap() throws {
        let f = try fixture()
        try FileManager.default.moveItem(at: f.app, to: f.backup)
        UpdateInstaller.sweepLeftovers(for: f.app)
        XCTAssertEqual(try String(contentsOf: f.app.appending(path: "marker"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
    }

    func testActiveLeaseBlocksAnotherInstallAndCleanup() throws {
        let f = try fixture()
        try FileManager.default.copyItem(at: f.app, to: f.backup)
        let stage = f.root.appending(path: ".Example.app.update-active")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var lease: UpdateInstaller.InstallationLock? = try .init(destination: f.app)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try UpdateInstaller.InstallationLock(destination: f.app))
        UpdateInstaller.sweepLeftovers(for: f.app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.backup.path))
        lease = nil
        UpdateInstaller.sweepLeftovers(for: f.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
        XCTAssertNoThrow(try UpdateInstaller.InstallationLock(destination: f.app))
    }

    func testHelperRetainsLeaseAfterParentReleasesIt() throws {
        let f = try fixture()
        let oldProcess = Process()
        oldProcess.executableURL = URL(filePath: "/bin/sleep")
        oldProcess.arguments = ["30"]
        try oldProcess.run()
        var lease: UpdateInstaller.InstallationLock? = try .init(destination: f.app)
        let helper = try UpdateInstaller.scheduleRelaunch(destination: f.app, backup: f.backup,
                                                         waitingFor: oldProcess.processIdentifier, lease: lease)
        defer {
            kill(helper, SIGKILL)
            waitpid(helper, nil, 0)
            oldProcess.terminate()
            oldProcess.waitUntilExit()
        }
        lease = nil
        XCTAssertThrowsError(try UpdateInstaller.InstallationLock(destination: f.app), "the helper must own the same lock")
        UpdateInstaller.sweepLeftovers(for: f.app)
        XCTAssertEqual(try String(contentsOf: f.app.appending(path: "marker"), encoding: .utf8), "new")
    }

    func testAliasedDestinationSharesTheSameLease() throws {
        let f = try fixture()
        let alias = f.root.appending(path: "Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.app)
        XCTAssertThrowsError(try UpdateInstaller.checkInstallable(alias), "swapping an alias would change its lock identity")
        let lease = try UpdateInstaller.InstallationLock(destination: f.app)
        try withExtendedLifetime(lease) {
            XCTAssertThrowsError(try UpdateInstaller.InstallationLock(destination: alias))
        }
    }

    func testLockIsReadableForOtherUsersOfSharedInstall() throws {
        let f = try fixture()
        let lease = try UpdateInstaller.InstallationLock(destination: f.app)
        var info = stat()
        XCTAssertEqual(fstat(lease.descriptor, &info), 0)
        XCTAssertEqual(info.st_mode & 0o444, 0o444)
        XCTAssertEqual(fcntl(lease.descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
        XCTAssertEqual(fcntl(lease.descriptor, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
    }

    func testHelperFailedLaunchWithoutBackupKeepsInstalledApp() throws {
        let f = try fixture()
        let helper = try UpdateInstaller.scheduleRelaunch(destination: f.app, backup: f.backup, waitingFor: 999_999)
        waitpid(helper, nil, 0)
        XCTAssertEqual(try String(contentsOf: f.app.appending(path: "marker"), encoding: .utf8), "new")
    }

    func testHelperRestoresBackupWhenDestinationDisappeared() throws {
        let f = try fixture()
        try FileManager.default.moveItem(at: f.app, to: f.backup)
        let helper = try UpdateInstaller.scheduleRelaunch(destination: f.app, backup: f.backup, waitingFor: 999_999)
        waitpid(helper, nil, 0)
        XCTAssertEqual(try String(contentsOf: f.app.appending(path: "marker"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
    }

    func testCancellationWhileToolRunsIsObservedBeforeReturning() async throws {
        let f = try fixture()
        let signal = f.root.appending(path: "started")
        let task = Task {
            try await UpdateInstaller.run("/bin/sh", ["-c", "touch \"$1\"; sleep 0.3", "sh", signal.path])
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: signal.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: signal.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled preparation must not continue to swap") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testAlreadyCancelledDownloadReleasesItsDelegate() async throws {
        weak var released: Downloader?
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let downloader = Downloader()
            released = downloader
            do {
                try await downloader.fetch(URL(string: "https://github.com/example/update.dmg")!,
                                           to: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) { _ in }
                XCTFail("must cancel before a request")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        XCTAssertNil(released)
    }

    func testInitialNonHTTPSDownloadIsRejected() async {
        do {
            try await Downloader().fetch(URL(string: "http://github.com/example/update.dmg")!,
                                         to: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) { _ in }
            XCTFail("must refuse cleartext before a request")
        } catch { XCTAssertTrue((error as? UpdateInstaller.Failure)?.message.contains("HTTPS") == true) }
    }
}

final class ReleaseValidationTests: XCTestCase {
    func testMalformedVersionsNeverCompareEqual() {
        for version in ["", ".", "1..2", ".1", "1.", "vv1.2", "1.2beta", "١.٢"] {
            XCTAssertFalse(ReleaseInfo.versionsMatch(version, "1.2"), version)
            XCTAssertFalse(ReleaseInfo.versionsMatch(version, version), version)
        }
        XCTAssertTrue(ReleaseInfo.versionsMatch("v01.2", "1.2.0"))
        XCTAssertTrue(ReleaseInfo.isNewer("999999999999999999999999999999999", than: "2"))
    }

    func testMalformedReleaseTagsAreRejectedAndUnsafePageLinksDiscarded() throws {
        func parse(_ tag: String, page: String = "https://github.com/a/b/releases") throws -> ReleaseInfo? {
            let data = try JSONSerialization.data(withJSONObject: [
                "tag_name": tag, "html_url": page,
                "assets": [["name": "A.dmg", "browser_download_url": "https://github.com/a/b/A.dmg"]],
            ])
            return ReleaseInfo.parse(data, assetName: "A.dmg")
        }
        for tag in [".", "1..2", "1.", "vv1.2", "١.٢"] { XCTAssertNil(try parse(tag), tag) }
        for page in ["file:///tmp/test", "shortcuts://run-shortcut?name=Test", "https://evil.example/"] {
            XCTAssertNil(try XCTUnwrap(parse("v1.2", page: page)).pageURL)
        }
    }

    @MainActor func testReleaseNotesOnlyExposeWebLinks() {
        let text = ReleaseNotesRenderer.render("[Website](https://example.com) [Local](file:///tmp/test) [Command](shortcuts://run-shortcut)")
        var links: [URL] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }
}

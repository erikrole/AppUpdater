import AppKit
import XCTest
@testable import AppUpdater

final class QuietNotesTests: XCTestCase {
    func testBulletsComeFromTopLevelListsAndStopAtFive() {
        let notes = "## Head\n- one\n  - nested\n- two\n1. three\n- four\n- five\n- six\n"
        XCTAssertEqual(QuietNotes.lines(from: notes), ["one", "two", "three", "four", "five"])
    }

    func testParagraphsOnlyWhenThereAreNoBullets() {
        XCTAssertEqual(QuietNotes.lines(from: "## Head\nFixes a crash.\nAnd a leak."), ["Fixes a crash.", "And a leak."])
        XCTAssertEqual(QuietNotes.lines(from: "```\ncode\n```"), [])
    }

    func testEmptyNotesHaveNoBullets() {
        XCTAssertFalse(QuietNotes.hasBullets(""))
        XCTAssertFalse(QuietNotes.hasBullets("  \n\n"))
        XCTAssertFalse(QuietNotes.hasBullets("## Only a heading"))
    }
}

@MainActor
final class QuietUpdateTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600

    private func make(version: String = "2.0", defaults: UserDefaults? = nil, fallback: String? = nil, busy: String? = nil) -> AppUpdater {
        _ = NSApplication.shared
        let updater = AppUpdater(
            .init(repository: "a/b", assetName: "A.dmg", bundleIdentifier: "com.x.A.\(UUID().uuidString)",
                  appURL: FileManager.default.temporaryDirectory.appending(path: "Nope-\(UUID().uuidString).app"),
                  currentVersion: version, busyReason: { busy }, fallbackNotes: fallback, autoInstall: { false }),
            defaults: defaults ?? testDefaults("QuietUpdateTests"))
        addTeardownBlock { updater.pill.set(nil) }
        return updater
    }

    private func justUpdated(_ defaults: UserDefaults, notes: String = "- New thing\n- Another", version: String = "2.0") {
        defaults.set(["version": version, "notes": notes, "from": "1.0", "page": "https://github.com/a/b/releases/tag/v2.0"], forKey: AppUpdater.Keys.justUpdated)
    }

    // MARK: Pill copy and states

    func testPillCopyIsShort() {
        let updater = make()
        updater.state = .updating(version: "2.1.0")
        XCTAssertEqual(updater.pillContent(), PillContent(indicator: .spinner, text: "Updating", hoverText: "Installing v2.1.0", clickable: false))
        updater.state = .ready(version: "2.1.0")
        XCTAssertEqual(updater.pillContent()?.text, "Restart")
        XCTAssertEqual(updater.pillContent()?.clickable, true)
        XCTAssertEqual(updater.menuTitle, "Restart to update")
        updater.state = .idle
        XCTAssertNil(updater.pillContent())
        XCTAssertNil(updater.menuTitle)
    }

    func testFailureIsSilentUntilSomeoneAsksButAlwaysMenuable() {
        let updater = make()
        updater.state = .failed(message: "Nope")
        XCTAssertNil(updater.pillContent(), "a failed launch install stays quiet")
        XCTAssertEqual(updater.menuTitle, "Update failed. Retry")
        updater.showPreview(state: .failed(message: "Nope"))
        XCTAssertEqual(updater.pillContent()?.text, "Update failed. Retry")
    }

    func testStateChangesAreReported() {
        let updater = make()
        var seen: [AppUpdater.State] = []
        updater.onStateChange = { seen.append($0) }
        updater.state = .ready(version: "2.0")
        updater.state = .ready(version: "2.0")
        updater.state = .idle
        XCTAssertEqual(seen, [.ready(version: "2.0"), .idle])
    }

    func testBusyHostIsRetriedLaterNotReportedAsFailure() async {
        let updater = make(busy: "Copying.")
        updater.startStaging(ReleaseInfo(version: "2.1", notes: "", downloadURL: URL(string: "https://github.com/a/b/A.dmg")!), visibleFailure: false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(updater.state, .idle)
        XCTAssertEqual(updater.failureCount(for: "2.1"), 0)
    }

    func testBusyHostOnAManualCheckShowsTheReason() async {
        let updater = make(busy: "Copying.")
        updater.startStaging(ReleaseInfo(version: "2.1", notes: "", downloadURL: URL(string: "https://github.com/a/b/A.dmg")!), visibleFailure: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(updater.state, .failed(message: "Copying."))
        XCTAssertEqual(updater.pillContent()?.text, "Update failed. Retry")
    }

    func testRestartDoesNothingUnlessReady() {
        let updater = make()
        updater.restartToUpdate()
        XCTAssertEqual(updater.state, .idle)
        XCTAssertFalse(updater.isInstalling)
    }

    // MARK: What's new

    func testFirstLaunchAfterAnUpdateShowsWhatsNewWithBullets() {
        let defaults = testDefaults("QuietUpdateTests")
        justUpdated(defaults)
        let updater = make(defaults: defaults)
        XCTAssertTrue(updater.showJustUpdated())
        XCTAssertEqual(updater.pillContent()?.text, "What's new")
        XCTAssertEqual(updater.pillContent()?.opensNotes, true)
        XCTAssertEqual(QuietNotes.lines(from: updater.activeWhatsNew()?.notes ?? ""), ["New thing", "Another"])
        XCTAssertEqual(defaults.string(forKey: AppUpdater.Keys.lastSeen), "2.0")
        XCTAssertNil(defaults.object(forKey: AppUpdater.Keys.justUpdated), "the install record is consumed")
    }

    func testNoNotesMeansNoPill() {
        let defaults = testDefaults("QuietUpdateTests")
        justUpdated(defaults, notes: "")
        let updater = make(defaults: defaults)
        XCTAssertFalse(updater.showJustUpdated())
        XCTAssertNil(updater.pillContent())
    }

    func testFallbackNotesStandInForMissingOnes() {
        let defaults = testDefaults("QuietUpdateTests")
        justUpdated(defaults, notes: "")
        let updater = make(defaults: defaults, fallback: "- Faster startup")
        XCTAssertTrue(updater.showJustUpdated())
    }

    func testPillPersistsAcrossLaunchesUntilOpenedOrThreeDays() {
        let defaults = testDefaults("QuietUpdateTests")
        justUpdated(defaults)
        let start = Date()
        XCTAssertTrue(make(defaults: defaults).showJustUpdated(now: start))

        let relaunch = make(defaults: defaults)
        XCTAssertTrue(relaunch.showJustUpdated(now: start.addingTimeInterval(2 * day)), "still up on day two")
        XCTAssertNotNil(relaunch.activeWhatsNew(now: start.addingTimeInterval(2 * day)))
        XCTAssertNil(relaunch.activeWhatsNew(now: start.addingTimeInterval(3 * day + 1)), "gone after three days")
    }

    func testOpeningDismissesItForGoodButItStaysWhileThePopoverIsUp() {
        let defaults = testDefaults("QuietUpdateTests")
        justUpdated(defaults)
        let updater = make(defaults: defaults)
        XCTAssertTrue(updater.showJustUpdated())
        updater.pill.onNotesOpened?()
        XCTAssertNotNil(updater.activeWhatsNew(), "held while the popover is open")
        XCTAssertEqual(defaults.dictionary(forKey: AppUpdater.Keys.whatsNew)?["dismissed"] as? Bool, true)
        updater.pill.onNotesClosed?()
        XCTAssertNil(updater.activeWhatsNew())
        XCTAssertNil(updater.pillContent())

        let relaunch = make(defaults: defaults)
        XCTAssertFalse(relaunch.showJustUpdated(), "opened once, never again")
    }

    func testAnOldVersionsRecordIsNeverShownForANewerBuild() {
        let defaults = testDefaults("QuietUpdateTests")
        justUpdated(defaults)
        XCTAssertTrue(make(defaults: defaults).showJustUpdated())
        XCTAssertFalse(make(version: "2.1", defaults: defaults).showJustUpdated())
    }

    func testARevertedUpdateCountsAsAFailureAndShowsNothing() {
        let defaults = testDefaults("QuietUpdateTests")
        justUpdated(defaults, version: "2.0")
        let updater = make(version: "1.0", defaults: defaults)
        XCTAssertFalse(updater.showJustUpdated())
        XCTAssertEqual(updater.failureCount(for: "2.0"), 1)
        XCTAssertNil(updater.pillContent())
    }

    func testAnUpdateMadeByHandUsesNotesCachedAtTheLastCheck() {
        let defaults = testDefaults("QuietUpdateTests")
        defaults.set("1.0", forKey: AppUpdater.Keys.lastSeen)
        let updater = make(defaults: defaults)
        updater.notesCache.save("- Cached bullet", version: "2.0")
        defer { try? FileManager.default.removeItem(at: updater.notesCache.directory) }
        XCTAssertTrue(updater.showJustUpdated())
    }

    func testFirstEverLaunchShowsNothing() {
        let updater = make()
        XCTAssertFalse(updater.showJustUpdated())
        XCTAssertNil(updater.pillContent())
    }

    func testPreviewShowsWithoutSavingAnything() {
        let defaults = testDefaults("QuietUpdateTests")
        let updater = make(defaults: defaults)
        updater.showPreview(ReleaseInfo(version: "2.0", notes: "- A\n- B", downloadURL: URL(string: "https://github.com/a/b")!))
        XCTAssertEqual(updater.pillContent()?.text, "What's new")
        XCTAssertNil(defaults.dictionary(forKey: AppUpdater.Keys.whatsNew))
    }

    // MARK: The pill itself

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSView()
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        addTeardownBlock { window.close() }
        return window
    }

    func testButtonLivesInTheTitleBarTrailingSideAndStaysThereOnResize() throws {
        let host = window()
        let updater = make()
        updater.hostView = host.contentView
        updater.state = .ready(version: "2.0")
        XCTAssertTrue(updater.pill.isVisible)
        let accessories = host.titlebarAccessoryViewControllers
        XCTAssertEqual(accessories.count, 1)
        XCTAssertEqual(accessories.first?.layoutAttribute, .trailing)
        XCTAssertTrue(host.childWindows?.isEmpty ?? true, "nothing floats over the content")
        host.setContentSize(NSSize(width: 640, height: 300))
        updater.pill.reposition()
        XCTAssertEqual(host.titlebarAccessoryViewControllers.count, 1, "still one, still in the title bar")
    }

    func testButtonGrowsOnHoverToShowTheVersion() throws {
        let host = window()
        let updater = make()
        updater.hostView = host.contentView
        updater.state = .updating(version: "2.1.0")
        let view = try XCTUnwrap(updater.pill.view as? PillView)
        let before = view.fittingSize.width
        view.mouseEntered(with: NSEvent())
        XCTAssertGreaterThan(view.fittingSize.width, before)
        view.mouseExited(with: NSEvent())
        XCTAssertEqual(view.fittingSize.width, before, accuracy: 0.5)
    }

    func testButtonGoesAwayWhenThereIsNothingToSay() throws {
        let host = window()
        let updater = make()
        updater.hostView = host.contentView
        updater.state = .ready(version: "2.0")
        XCTAssertEqual(host.titlebarAccessoryViewControllers.count, 1)
        updater.state = .idle
        XCTAssertFalse(updater.pill.isVisible)
        XCTAssertTrue(host.titlebarAccessoryViewControllers.isEmpty)
    }

    func testWithoutAWindowTheMenuItemCarriesTheState() {
        let updater = make()
        XCTAssertTrue(updater.menuItem.isHidden)
        updater.state = .available(version: "2.0")
        XCTAssertFalse(updater.menuItem.isHidden)
        XCTAssertEqual(updater.menuItem.title, "Update available")
        updater.state = .updating(version: "2.0")
        XCTAssertEqual(updater.menuItem.title, "Updating…")
        XCTAssertFalse(updater.menuItem.isEnabled)
        updater.state = .ready(version: "2.0")
        XCTAssertEqual(updater.menuItem.title, "Restart to update")
        XCTAssertTrue(updater.menuItem.isEnabled)
        updater.state = .idle
        XCTAssertTrue(updater.menuItem.isHidden)
    }

    func testRetryRestartsTheDownloadOfTheReleaseThatFailed() async {
        let updater = make(busy: "Copying.")
        let release = ReleaseInfo(version: "2.1", notes: "", downloadURL: URL(string: "https://github.com/a/b/A.dmg")!)
        updater.startStaging(release, visibleFailure: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(updater.state, .failed(message: "Copying."))
        updater.performPrimaryAction()
        XCTAssertEqual(updater.state, .updating(version: "2.1"), "a click on the failed pill starts over")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(updater.state, .failed(message: "Copying."))
    }
}

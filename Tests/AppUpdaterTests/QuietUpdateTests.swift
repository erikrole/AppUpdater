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
        XCTAssertEqual(updater.pillContent()?.text, "Restart to update")
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

    func testPillAnchorsTopRightOfTheHostViewAndFollowsResizes() throws {
        let host = window()
        let updater = make()
        updater.hostView = host.contentView
        updater.state = .ready(version: "2.0")
        let panel = try XCTUnwrap(updater.pill.panelWindow)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(host.childWindows?.contains(panel) == true, "a child window, so it moves with the host")
        let layout = host.convertToScreen(host.contentLayoutRect)
        XCTAssertEqual(panel.frame.maxX, layout.maxX - PillController.inset, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, layout.maxY - PillController.inset, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, PillController.height, accuracy: 0.5)

        host.setContentSize(NSSize(width: 640, height: 300))
        updater.pill.reposition()
        let resized = host.convertToScreen(host.contentLayoutRect)
        XCTAssertEqual(panel.frame.maxX, resized.maxX - PillController.inset, accuracy: 0.5)
    }

    func testPillGrowsOnHoverToShowTheVersionAndNeverTakesFocus() throws {
        let host = window()
        let updater = make()
        updater.hostView = host.contentView
        updater.state = .updating(version: "2.1.0")
        let panel = try XCTUnwrap(updater.pill.panelWindow)
        XCTAssertFalse(panel.canBecomeKey)
        let before = panel.frame
        let view = try XCTUnwrap(updater.pill.view as? PillView)
        view.mouseEntered(with: NSEvent())
        XCTAssertGreaterThan(panel.frame.width, before.width)
        XCTAssertEqual(panel.frame.maxX, before.maxX, accuracy: 0.5, "the right edge stays put")
        view.mouseExited(with: NSEvent())
        XCTAssertEqual(panel.frame.width, before.width, accuracy: 0.5)
    }

    func testPillGoesAwayWhenThereIsNothingToSay() throws {
        let host = window()
        let updater = make()
        updater.hostView = host.contentView
        updater.state = .ready(version: "2.0")
        let panel = try XCTUnwrap(updater.pill.panelWindow)
        updater.state = .idle
        let deadline = Date().addingTimeInterval(2)
        while panel.isVisible, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(host.childWindows?.first { $0 === panel })
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

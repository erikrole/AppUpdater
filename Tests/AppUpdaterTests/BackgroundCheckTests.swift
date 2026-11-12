import Foundation
import XCTest
@testable import AppUpdater

private final class BackgroundChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var beta = false
    func set(_ beta: Bool) { lock.withLock { self.beta = beta } }
    func get() -> AppUpdater.UpdateChannel { lock.withLock { beta ? .beta : .production } }
}

@MainActor final class BackgroundCheckTests: XCTestCase {
    final class State { var busy = false; var eligible = true }
    actor Feed {
        var version = "2.0.0"
        var calls = 0
        var beta = false
        var paused = false
        var waiter: CheckedContinuation<Void, Never>?
        func set(_ version: String, beta: Bool = false) { self.version = version; self.beta = beta }
        func pause() { paused = true }
        func count() -> Int { calls }
        func resume() { paused = false; waiter?.resume(); waiter = nil }
        func fetch(list: Bool) async -> (Data, Int) {
            calls += 1
            if paused { await withCheckedContinuation { waiter = $0 } }
            let json = "{\"tag_name\":\"v\(version)\",\"draft\":false,\"prerelease\":\(beta),\"body\":\"New features\",\"assets\":[{\"name\":\"Offload.dmg\",\"browser_download_url\":\"https://github.com/erikrole/offload-releases/releases/download/v\(version)/Offload.dmg\"}]}"
            return (Data((list ? "[" + json + "]" : json).utf8), 200)
        }
    }
    private func make(_ feed: Feed, state: State = State(), defaults: UserDefaults? = nil, interval: TimeInterval = 0, channel: BackgroundChannel = BackgroundChannel()) -> AppUpdater {
        let updater = AppUpdater(.init(repository: "erikrole/offload-releases", assetName: "Offload.dmg",
            bundleIdentifier: "com.erole.BackgroundTests", appURL: URL.temporaryDirectory.appending(path: "BackgroundTests-" + UUID().uuidString + "/Test.app"),
            minimumCheckInterval: interval, currentVersion: "2.0.0", busyReason: { state.busy ? "Working" : nil }, postUpdate: .quiet, channel: { channel.get() }),
            defaults: defaults ?? testDefaults("BackgroundChecks"))
        updater.fetch = { url in await feed.fetch(list: url.path.hasSuffix("/releases")) }
        return updater
    }
    func waitForFetch(_ feed: Feed) async {
        for _ in 0..<500 { if await feed.count() > 0 { return }; await Task.yield() }
        XCTFail("Fetch did not begin")
    }
    func testNewReleaseAppearsWhileOpenAndLaterDoesNotNag() async {
        let feed = Feed(), updater = make(feed)
        var offers: [String] = []
        _ = await updater.checkInBackground { offers.append($0.version) }
        XCTAssertTrue(offers.isEmpty)
        await feed.set("2.1.0")
        _ = await updater.checkInBackground { offers.append($0.version) }
        _ = await updater.checkInBackground { offers.append($0.version) }
        XCTAssertEqual(offers, ["2.1.0"])
        await feed.set("2.2.0")
        _ = await updater.checkInBackground { offers.append($0.version) }
        await feed.set("2.1.0")
        _ = await updater.checkInBackground { offers.append($0.version) }
        XCTAssertEqual(offers, ["2.1.0", "2.2.0"])
    }
    func testBusyOrInactiveNeverFetches() async {
        let feed = Feed(), state = State(), updater = make(feed, state: state)
        state.busy = true
        let busy = await updater.checkInBackground { _ in XCTFail("Busy prompt") }
        state.busy = false; state.eligible = false
        let inactive = await updater.checkInBackground(shouldPresent: { state.eligible }, offer: { _ in XCTFail("Inactive prompt") })
        let count = await feed.count()
        XCTAssertNil(busy); XCTAssertNil(inactive); XCTAssertEqual(count, 0)
    }
    func testStateChangesDuringFetchDoNotConsumeTheOffer() async {
        for fault in ["busy", "inactive", "cancel"] {
            let feed = Feed(), state = State(), updater = make(feed, state: state)
            await feed.set("2.1.0"); await feed.pause()
            var offers: [String] = []
            let task = Task { await updater.checkInBackground(shouldPresent: { state.eligible }, offer: { offers.append($0.version) }) }
            await waitForFetch(feed)
            if fault == "busy" { state.busy = true }
            if fault == "inactive" { state.eligible = false }
            if fault == "cancel" { task.cancel() }
            await feed.resume()
            let result = await task.value
            XCTAssertNil(result); XCTAssertTrue(offers.isEmpty)
            state.busy = false; state.eligible = true
            _ = await updater.checkInBackground(shouldPresent: { state.eligible }, offer: { offers.append($0.version) })
            XCTAssertEqual(offers, ["2.1.0"])
        }
    }
    func testScheduledCheckFindsReleaseWhileBusyAndOffersItWithoutRefetching() async {
        let feed = Feed(), state = State(), updater = make(feed, state: state, interval: 3600)
        await feed.set("2.1.0")
        state.busy = true
        _ = await updater.checkInBackground(scheduled: true) { _ in XCTFail("Busy app") }

        state.busy = false
        var offered: String?
        _ = await updater.checkInBackground(scheduled: true) { offered = $0.version }
        XCTAssertEqual(offered, "2.1.0")
        let calls = await feed.count()
        XCTAssertEqual(calls, 1)
    }

    func testReopeningWithAnOutstandingUpdateChecksBeforeTheInterval() async {
        let feed = Feed(), defaults = testDefaults("OutstandingUpdate")
        let first = make(feed, defaults: defaults, interval: 3600)
        await feed.set("2.1.0")
        _ = await first.checkInBackground(scheduled: true) { _ in }

        let second = make(feed, defaults: defaults, interval: 3600)
        var offered: String?
        _ = await second.checkInBackground(scheduled: true) { offered = $0.version }
        XCTAssertEqual(offered, "2.1.0")
        let calls = await feed.count()
        XCTAssertEqual(calls, 2)
    }

    func testOverlappingChecksShareOneFetch() async {
        let feed = Feed(), updater = make(feed)
        await feed.set("2.1.0"); await feed.pause()
        var offers = 0
        let task = Task { await updater.checkInBackground { _ in offers += 1 } }
        await waitForFetch(feed)
        let second = await updater.checkInBackground { _ in XCTFail("Overlapping prompt") }
        XCTAssertNil(second)
        await feed.resume(); _ = await task.value
        let count = await feed.count()
        XCTAssertEqual(count, 1); XCTAssertEqual(offers, 1)
    }
    func testSkipSurvivesReopenAndManualChecksRemainAvailable() async throws {
        let feed = Feed(), defaults = testDefaults("BackgroundSkip")
        await feed.set("2.1.0")
        let updater = make(feed, defaults: defaults)
        guard case let .available(release)? = await updater.checkInBackground(offer: { _ in }) else { return XCTFail() }
        updater.skip(release)
        let reopened = make(feed, defaults: defaults)
        let result = await reopened.checkInBackground { _ in XCTFail("Skipped prompt") }
        XCTAssertEqual(result, .skipped("2.1.0"))
        guard case .available = await reopened.evaluate(userInitiated: true) else { return XCTFail() }
        await feed.set("2.2.0")
        var offered: String?
        _ = await reopened.checkInBackground { offered = $0.version }
        XCTAssertEqual(offered, "2.2.0")
    }
    func testManualPresentationAndPostUpdateQuietStateAreRetained() async {
        let feed = Feed(), defaults = testDefaults("BackgroundInstalled")
        defaults.set(["version":"2.0.0", "from":"1.9.0", "notes":"New features"], forKey: AppUpdater.Keys.justUpdated)
        let updater = make(feed, defaults: defaults)
        await feed.set("2.1.0")
        let release = ReleaseInfo(version: "2.1.0", notes: "", downloadURL: URL(string: "https://github.com/erikrole/offload-releases/releases/download/v2.1.0/Offload.dmg")!)
        updater.rememberOffer(release)
        _ = await updater.checkInBackground { _ in XCTFail("Already shown manually") }
        XCTAssertNil(defaults.object(forKey: AppUpdater.Keys.justUpdated))
        guard case .available = await updater.evaluate(userInitiated: true) else { return XCTFail() }
    }
    func testLeavingBetaStillOffersAnUnseenStableVersion() async {
        let feed = Feed(), channel = BackgroundChannel()
        channel.set(true)
        let updater = make(feed, channel: channel)
        await feed.set("4.0.0-beta.1", beta: true)
        var offered: [String] = []
        _ = await updater.checkInBackground { offered.append($0.version) }
        channel.set(false)
        await feed.set("2.1.0")
        _ = await updater.checkInBackground { offered.append($0.version) }
        XCTAssertEqual(offered, ["4.0.0-beta.1", "2.1.0"])
    }
    func testChannelChangeDuringFetchDefersTheOldResponse() async {
        let feed = Feed(), channel = BackgroundChannel()
        channel.set(true)
        let updater = make(feed, channel: channel)
        await feed.set("4.0.0-beta.1", beta: true); await feed.pause()
        var offered: [String] = []
        let task = Task { await updater.checkInBackground { offered.append($0.version) } }
        await waitForFetch(feed)
        channel.set(false); await feed.resume()
        let result = await task.value
        XCTAssertNil(result); XCTAssertTrue(offered.isEmpty)
        await feed.set("2.1.0")
        _ = await updater.checkInBackground { offered.append($0.version) }
        XCTAssertEqual(offered, ["2.1.0"])
    }
    func testOfflineAndCurrentChecksNeverPresent() async {
        let updater = make(Feed())
        updater.fetch = { _ in throw URLError(.notConnectedToInternet) }
        let result = await updater.checkInBackground { _ in XCTFail("Offline prompt") }
        guard case .failed? = result else { return XCTFail() }
    }
}

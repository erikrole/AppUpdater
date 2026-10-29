import XCTest
@testable import AppUpdater

private func feedRelease(_ tag: String, prerelease: Bool = false, draft: Bool = false, asset: String = "Offload.dmg") -> String {
    """
    {"tag_name":"\(tag)","html_url":"https://github.com/erikrole/offload-releases/releases/tag/\(tag)",
     "draft":\(draft),"prerelease":\(prerelease),"published_at":"2026-10-26T12:00:00Z","body":"Notes for \(tag)",
     "assets":[{"name":"\(asset)","browser_download_url":"https://github.com/erikrole/offload-releases/releases/download/\(tag)/\(asset)"}]}
    """
}

private func list(_ items: String...) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }

final class BetaVersionTests: XCTestCase {
    func testBetaVersionsOrderBelowTheirRelease() {
        XCTAssertTrue(ReleaseInfo.isNewer("3.0.0-beta.2", than: "3.0.0-beta.1"))
        XCTAssertTrue(ReleaseInfo.isNewer("3.0.0", than: "3.0.0-beta.2"))
        XCTAssertTrue(ReleaseInfo.isNewer("3.0.0-beta.1", than: "2.4.0"))
        XCTAssertFalse(ReleaseInfo.isNewer("3.0.0-beta.1", than: "3.0.0"))
        XCTAssertFalse(ReleaseInfo.isNewer("3.0.0-beta.1", than: "3.0.0-beta.1"))
        XCTAssertTrue(ReleaseInfo.isNewer("3.0.0-beta.10", than: "3.0.0-beta.9"))
        XCTAssertTrue(ReleaseInfo.isNewer("v3.0.1-beta.1", than: "3.0.0"))
        XCTAssertTrue(ReleaseInfo.isNewer("3.0.0-beta.007", than: "3.0.0-beta.6"))
    }

    func testOnlyBetaSuffixesAreVersions() {
        for bad in ["3.0.0-rc.1", "3.0.0-beta", "3.0.0-beta.", "3.0.0-beta.x", "3.0.0-beta.1.2", "3.0.0-", "-beta.1", "3.0.0-beta.1-x"] {
            XCTAssertFalse(ReleaseInfo.isNewer(bad, than: "1.0"), bad)
            XCTAssertFalse(ReleaseInfo.versionsMatch(bad, bad), bad)
        }
        XCTAssertTrue(ReleaseInfo.versionsMatch("3.0.0-beta.1", "v3.0.0-beta.1"))
        XCTAssertFalse(ReleaseInfo.versionsMatch("3.0.0-beta.1", "3.0.0"))
        XCTAssertTrue(ReleaseInfo.isBeta("3.0.0-beta.4"))
        XCTAssertFalse(ReleaseInfo.isBeta("3.0.0"))
    }

    func testProductionParsingNeverSeesBetas() {
        let flagged = Data(feedRelease("v3.0.0-beta.1", prerelease: true).utf8)
        XCTAssertNil(ReleaseInfo.parse(flagged, assetName: "Offload.dmg"))
        // A beta tag that was not flagged as a prerelease on GitHub is still a beta.
        let unflagged = Data(feedRelease("v3.0.0-beta.1").utf8)
        XCTAssertNil(ReleaseInfo.parse(unflagged, assetName: "Offload.dmg"))
        let beta = ReleaseInfo.parse(flagged, assetName: "Offload.dmg", allowPrerelease: true)
        XCTAssertEqual(beta?.version, "3.0.0-beta.1")
        XCTAssertEqual(beta?.isPrerelease, true)
        XCTAssertEqual(ReleaseInfo.parse(Data(feedRelease("v2.4.0").utf8), assetName: "Offload.dmg")?.isPrerelease, false)
    }

    func testNewestInListPicksTheHighestVersionWithTheAsset() {
        let data = list(feedRelease("v2.4.0"), feedRelease("v3.0.0-beta.1", prerelease: true), feedRelease("v3.0.0-beta.2", prerelease: true),
                        feedRelease("v3.1.0-beta.1", prerelease: true, draft: true), feedRelease("v3.0.0-beta.3", prerelease: true, asset: "Other.dmg"))
        XCTAssertEqual(ReleaseInfo.newest(inList: data, assetName: "Offload.dmg", allowPrerelease: true)?.version, "3.0.0-beta.2")
        XCTAssertEqual(ReleaseInfo.newest(inList: data, assetName: "Offload.dmg", allowPrerelease: false)?.version, "2.4.0")
        let withFinal = list(feedRelease("v3.0.0-beta.2", prerelease: true), feedRelease("v3.0.0"), feedRelease("v2.4.0"))
        XCTAssertEqual(ReleaseInfo.newest(inList: withFinal, assetName: "Offload.dmg", allowPrerelease: true)?.version, "3.0.0")
        XCTAssertNil(ReleaseInfo.newest(inList: Data("{}".utf8), assetName: "Offload.dmg", allowPrerelease: true))
        XCTAssertNil(ReleaseInfo.newest(inList: list(feedRelease("v1.0", draft: true)), assetName: "Offload.dmg", allowPrerelease: true))
    }
}

@MainActor
final class ChannelCheckTests: XCTestCase {
    private func make(version: String, channel: @escaping @Sendable () -> AppUpdater.UpdateChannel, body: Data) -> (AppUpdater, URLBox) {
        let box = URLBox()
        let updater = AppUpdater(
            .init(repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "com.erole.Offload",
                  currentVersion: version, channel: channel),
            defaults: testDefaults("AppUpdaterChannelTests"))
        updater.fetch = { url in box.url = url; return (body, 200) }
        return (updater, box)
    }
    final class URLBox: @unchecked Sendable { var url: URL? }

    private let feed = list(feedRelease("v3.0.0-beta.2", prerelease: true), feedRelease("v3.0.0-beta.1", prerelease: true), feedRelease("v2.4.0"))

    func testProductionIsTheDefaultAndUsesLatest() async {
        let box = URLBox()
        let updater = AppUpdater(.init(repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "x", currentVersion: "2.3.0"),
                                 defaults: testDefaults("AppUpdaterChannelTests"))
        updater.fetch = { url in box.url = url; return (Data(feedRelease("v2.4.0").utf8), 200) }
        guard case let .available(found) = await updater.evaluate(userInitiated: true) else { return XCTFail() }
        XCTAssertEqual(found.version, "2.4.0")
        XCTAssertEqual(box.url?.path, "/repos/erikrole/offload-releases/releases/latest")
    }

    func testBetaListsReleasesAndOffersTheNewestBeta() async {
        let (updater, box) = make(version: "2.4.0", channel: { .beta }, body: feed)
        guard case let .available(found) = await updater.evaluate(userInitiated: true) else { return XCTFail() }
        XCTAssertEqual(found.version, "3.0.0-beta.2")
        XCTAssertTrue(found.isPrerelease)
        XCTAssertEqual(box.url?.path, "/repos/erikrole/offload-releases/releases")
        XCTAssertEqual(box.url?.query, "per_page=20")
    }

    func testABetaMacMovesToTheNextBetaAndThenToTheFinalRelease() async {
        let (onBeta1, _) = make(version: "3.0.0-beta.1", channel: { .beta }, body: feed)
        guard case let .available(next) = await onBeta1.evaluate(userInitiated: true) else { return XCTFail() }
        XCTAssertEqual(next.version, "3.0.0-beta.2")
        let (onBeta2, _) = make(version: "3.0.0-beta.2", channel: { .beta }, body: feed)
        guard case .upToDate = await onBeta2.evaluate(userInitiated: true) else { return XCTFail() }
        let final = list(feedRelease("v3.0.0"), feedRelease("v3.0.0-beta.2", prerelease: true))
        let (production, _) = make(version: "3.0.0-beta.2", channel: { .production }, body: Data(feedRelease("v3.0.0").utf8))
        guard case let .available(done) = await production.evaluate(userInitiated: true) else { return XCTFail() }
        XCTAssertEqual(done.version, "3.0.0")
        let (beta, _) = make(version: "3.0.0-beta.2", channel: { .beta }, body: final)
        guard case let .available(viaBeta) = await beta.evaluate(userInitiated: true) else { return XCTFail() }
        XCTAssertEqual(viaBeta.version, "3.0.0")
    }

    func testTurningBetaOffNeverDowngradesAndKeepsABetaMacUntilANewerProductionRelease() async {
        // A beta Mac on the production channel: latest is 2.4.0, which is older than what is installed.
        let (updater, _) = make(version: "3.0.0-beta.2", channel: { .production }, body: Data(feedRelease("v2.4.0").utf8))
        guard case .upToDate = await updater.evaluate(userInitiated: true) else { return XCTFail() }
    }

    func testTheChannelIsReadAtEachCheck() async {
        final class Switch: @unchecked Sendable { var beta = false }
        let flag = Switch()
        let (updater, box) = make(version: "2.4.0", channel: { flag.beta ? .beta : .production }, body: feed)
        _ = await updater.evaluate(userInitiated: true)
        XCTAssertEqual(box.url?.path, "/repos/erikrole/offload-releases/releases/latest")
        flag.beta = true
        _ = await updater.evaluate(userInitiated: true)
        XCTAssertEqual(box.url?.path, "/repos/erikrole/offload-releases/releases")
    }
}

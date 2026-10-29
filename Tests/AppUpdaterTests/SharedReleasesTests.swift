import XCTest
@testable import AppUpdater

/// One public repository can hold releases for several apps; tags carry an app prefix.
private func sharedRelease(_ tag: String, asset: String, prerelease: Bool = false) -> String {
    """
    {"tag_name":"\(tag)","html_url":"https://github.com/erikrole/releases/releases/tag/\(tag)","draft":false,
     "prerelease":\(prerelease),"body":"Notes for \(tag)",
     "assets":[{"name":"\(asset)","browser_download_url":"https://github.com/erikrole/releases/releases/download/\(tag)/\(asset)"}]}
    """
}

private let sharedList = "[" + [
    sharedRelease("snipbar-v9.0.0", asset: "SnipBar.zip"),
    sharedRelease("scratchpad-v1.6.0-beta.1", asset: "Scratchpad.zip", prerelease: true),
    sharedRelease("scratchpad-v1.5.1", asset: "Scratchpad.zip"),
    sharedRelease("scratchpad-v1.5.0", asset: "Scratchpad.zip"),
    sharedRelease("scratchpadpro-v3.0.0", asset: "Scratchpad.zip"),
].joined(separator: ",") + "]"

final class SharedReleasesParseTests: XCTestCase {
    func testPrefixSelectsOnlyThisAppsNewestStableRelease() throws {
        let found = try XCTUnwrap(ReleaseInfo.newest(inList: Data(sharedList.utf8), assetName: "Scratchpad.zip",
                                                     allowPrerelease: false, tagPrefix: "scratchpad-"))
        XCTAssertEqual(found.version, "1.5.1")
        XCTAssertEqual(found.downloadURL.path, "/erikrole/releases/releases/download/scratchpad-v1.5.1/Scratchpad.zip")
    }

    func testPrefixWithBetaAllowsPrereleases() throws {
        let found = try XCTUnwrap(ReleaseInfo.newest(inList: Data(sharedList.utf8), assetName: "Scratchpad.zip",
                                                     allowPrerelease: true, tagPrefix: "scratchpad-"))
        XCTAssertEqual(found.version, "1.6.0-beta.1")
    }

    func testPrefixRejectsOtherAppsAndUnprefixedTags() {
        XCTAssertNil(ReleaseInfo.parse(Data(sharedRelease("snipbar-v9.0.0", asset: "Scratchpad.zip").utf8),
                                       assetName: "Scratchpad.zip", tagPrefix: "scratchpad-"))
        XCTAssertNil(ReleaseInfo.parse(Data(sharedRelease("v1.5.0", asset: "Scratchpad.zip").utf8),
                                       assetName: "Scratchpad.zip", tagPrefix: "scratchpad-"))
        // Without a prefix, a prefixed tag is not a version.
        XCTAssertNil(ReleaseInfo.parse(Data(sharedRelease("scratchpad-v1.5.0", asset: "Scratchpad.zip").utf8), assetName: "Scratchpad.zip"))
    }
}

@MainActor
final class SharedReleasesCheckTests: XCTestCase {
    func testCheckReadsTheListAndOffersThePrefixedRelease() async {
        let defaults = testDefaults("AppUpdaterTests")
        let updater = AppUpdater(.init(repository: "erikrole/releases", assetName: "Scratchpad.zip",
                                       bundleIdentifier: "com.erole.Scratchpad", currentVersion: "1.5.0",
                                       tagPrefix: "scratchpad-"), defaults: defaults)
        let requested = URLBox()
        updater.fetch = { url in requested.url = url; return (Data(sharedList.utf8), 200) }
        guard case let .available(found) = await updater.evaluate(userInitiated: true) else { return XCTFail() }
        XCTAssertEqual(found.version, "1.5.1")
        XCTAssertEqual(requested.url?.absoluteString, "https://api.github.com/repos/erikrole/releases/releases?per_page=100")
    }
}

private final class URLBox: @unchecked Sendable { var url: URL? }

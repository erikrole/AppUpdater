import Foundation
import XCTest
@testable import AppUpdater

final class StableReleaseFeedTests: XCTestCase {
    private func entry(_ version: String, minimum: String, repo: String = "erikrole/releases", digest: Bool = true) -> [String: Any] {
        let tag = "example-v\(version)"
        var asset = ["name": "Example.zip", "browser_download_url": "https://github.com/\(repo)/releases/download/\(tag)/Example.zip"]
        if digest { asset["digest"] = "sha256:" + String(repeating: "a", count: 64) }
        return ["tag_name": tag, "minimum_macos": minimum, "assets": [asset]]
    }

    func testSelectsNewestCompatibleStableReleaseFromTheConfiguredRepo() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            entry("4.0.0", minimum: "28.0"),
            entry("3.0.0", minimum: "27.0", repo: "another/releases"),
            entry("2.5.0", minimum: "26.0", digest: false),
            entry("2.1.0", minimum: "26.0"),
            entry("2.0.0", minimum: "26.0"),
        ])
        let selection = StableReleaseFeed.select(data, repository: "erikrole/releases", assetName: "Example.zip",
                                               tagPrefix: "example-", systemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(selection?.newestListed.version, "4.0.0")
        XCTAssertEqual(selection?.compatible?.version, "2.1.0")
        XCTAssertEqual(selection?.compatible?.archiveSHA256, String(repeating: "a", count: 64))
    }
}

import XCTest
@testable import AppUpdater

@MainActor
final class AutoInstallTests: XCTestCase {
    private func make(autoInstall: @escaping @Sendable () -> Bool = { true }, busy: String? = nil) -> AppUpdater {
        let defaults = UserDefaults(suiteName: "AutoInstallTests.\(UUID().uuidString)")!
        return AppUpdater(
            .init(repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "com.erole.Offload",
                  currentVersion: "2.0.0", busyReason: { busy }, autoInstall: autoInstall),
            defaults: defaults)
    }

    private func release(_ version: String, prerelease: Bool = false) -> ReleaseInfo {
        ReleaseInfo(version: version, notes: "", downloadURL: URL(string: "https://github.com/x")!, isPrerelease: prerelease)
    }

    func testStableUpdateInstallsByDefault() {
        XCTAssertTrue(make().shouldAutoInstall(release("2.1.0")))
    }

    func testSwitchBetaBusyAndFailuresAllFallBackToTheSplash() {
        XCTAssertFalse(make(autoInstall: { false }).shouldAutoInstall(release("2.1.0")))
        XCTAssertFalse(make().shouldAutoInstall(release("3.0.0-beta.1", prerelease: true)))
        XCTAssertFalse(make().shouldAutoInstall(release("3.0.0-beta.2")))
        XCTAssertFalse(make(busy: "Copying.").shouldAutoInstall(release("2.1.0")))
        let updater = make()
        updater.recordFailure(of: "2.1.0")
        XCTAssertTrue(updater.shouldAutoInstall(release("2.1.0")))
        updater.recordFailure(of: "2.1.0")
        XCTAssertFalse(updater.shouldAutoInstall(release("2.1.0")))
        XCTAssertTrue(updater.shouldAutoInstall(release("2.2.0")), "a newer release starts with a clean slate")
    }

    func testFailureCountResetsForANewVersion() {
        let updater = make()
        updater.recordFailure(of: "2.1.0")
        XCTAssertEqual(updater.failureCount(for: "2.1.0"), 1)
        XCTAssertEqual(updater.failureCount(for: "2.2.0"), 0)
    }
}

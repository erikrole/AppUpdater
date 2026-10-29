import Foundation

/// A throwaway defaults suite. Every suite made here is removed, plist file included, when the test process exits,
/// so test runs don't leave hundreds of files in ~/Library/Preferences.
func testDefaults(_ prefix: String) -> UserDefaults {
    let name = "\(prefix)-\(UUID().uuidString)"
    TestDefaultsCleanup.register(name)
    return UserDefaults(suiteName: name)!
}

private enum TestDefaultsCleanup {
    nonisolated(unsafe) static var names: [String] = []
    static let lock = NSLock()
    nonisolated(unsafe) static var installed = false

    static func register(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        names.append(name)
        guard !installed else { return }
        installed = true
        atexit {
            let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
            for name in TestDefaultsCleanup.names {
                UserDefaults.standard.removePersistentDomain(forName: name)
                try? FileManager.default.removeItem(at: preferences.appending(path: "\(name).plist"))
            }
        }
    }
}

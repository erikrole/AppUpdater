import Foundation

/// A throwaway defaults suite stored in the temporary folder. A plain suite name would leave a plist in
/// ~/Library/Preferences for every test, because cfprefsd rewrites removed domains after the process exits.
func testDefaults(_ prefix: String) -> UserDefaults {
    let path = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)").path
    return UserDefaults(suiteName: path)!
}

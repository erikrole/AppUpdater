import Foundation

/// Remembers the release notes last seen for each version, so the window has something to say when a later
/// fetch comes back without them.
struct NotesCache: Sendable {
    let directory: URL

    init(bundleIdentifier: String, base: URL? = nil) {
        let root = base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = root.appending(path: "AppUpdater").appending(path: bundleIdentifier.isEmpty ? "app" : bundleIdentifier)
    }

    private func file(_ version: String) -> URL {
        let safe = version.filter { $0.isNumber || $0 == "." }
        return directory.appending(path: "notes-\(safe).md")
    }

    func save(_ notes: String, version: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? notes.write(to: file(version), atomically: true, encoding: .utf8)
    }

    func load(version: String) -> String? {
        guard let text = try? String(contentsOf: file(version), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

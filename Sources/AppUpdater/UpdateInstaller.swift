import AppKit
import Foundation

/// Downloads a signed disk image and swaps the app it holds over the running one.
/// The old copy is kept as a hidden backup until the new one has relaunched, and put back on any failure.
enum UpdateInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Everything before the swap: download, mount, copy off the image, verify. Returns the verified staged app.
    static func prepare(
        release: ReleaseInfo,
        destination: URL,
        configuration: AppUpdater.Configuration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (staged: URL, workDirectory: URL) {
        try checkInstallable(destination)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "AppUpdater-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let dmg = work.appending(path: "update.dmg")
            try await Downloader().fetch(release.downloadURL, to: dmg, progress: progress)

            let mountPoint = work.appending(path: "mount")
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let attach = try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
            guard attach.status == 0 else { throw Failure(message: "Couldn't open the downloaded update.") }
            defer { _ = try? runSync("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

            guard let source = findApp(in: mountPoint, named: destination.lastPathComponent) else {
                throw Failure(message: "The update didn't contain \(destination.deletingPathExtension().lastPathComponent).")
            }
            // Stage beside the destination: the swap is then a rename on one volume, and what is verified is what is installed.
            let staged = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).update-\(UUID().uuidString.prefix(8))")
            let copy = try await run("/usr/bin/ditto", [source.path, staged.path])
            guard copy.status == 0 else {
                try? fm.removeItem(at: staged)
                throw Failure(message: "Couldn't copy the update next to \(destination.lastPathComponent).")
            }
            do {
                try await verify(staged, configuration: configuration)
            } catch {
                try? fm.removeItem(at: staged)
                throw error
            }
            return (staged, work)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Refuses installs that can't work: a read-only image, a translocated copy, or an unwritable folder.
    static func checkInstallable(_ destination: URL) throws {
        let path = destination.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            throw Failure(message: "Move \(destination.lastPathComponent) to your Applications folder first, then update.")
        }
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw Failure(message: "\(destination.lastPathComponent) is in a folder this Mac user can't change.")
        }
    }

    static func findApp(in directory: URL, named name: String) -> URL? {
        let apps = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        return apps.first { $0.lastPathComponent == name } ?? apps.first
    }

    // MARK: - Verification

    static func verify(_ app: URL, configuration: AppUpdater.Configuration) async throws {
        let strict = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard strict.status == 0 else { throw Failure(message: "The downloaded update's signature is invalid, so it wasn't installed.") }
        let details = try await run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard teamID(in: details.output) == configuration.teamID else {
            throw Failure(message: "The downloaded update isn't signed by the expected developer, so it wasn't installed.")
        }
        guard Bundle(url: app)?.bundleIdentifier == configuration.bundleIdentifier else {
            throw Failure(message: "The downloaded update isn't this app, so it wasn't installed.")
        }
        let assess = try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard assess.status == 0 else { throw Failure(message: "macOS Gatekeeper rejected the downloaded update.") }
    }

    /// The `TeamIdentifier=` value in `codesign -dv` output.
    static func teamID(in output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    // MARK: - Swap

    /// Moves the current app aside and the verified one into place. Returns the backup; call `rollback` to undo.
    static func swap(destination: URL, with staged: URL) throws -> URL {
        let fm = FileManager.default
        let backup = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).backup")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: backup, to: destination)
            throw Failure(message: "Couldn't put the update in place: \(error.localizedDescription). Your current version is untouched.")
        }
        return backup
    }

    static func rollback(destination: URL, backup: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.moveItem(at: backup, to: destination)
    }

    /// Opens the freshly installed app as a new instance (the old one is still running) and waits for it to start.
    @MainActor
    static func relaunch(_ app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    // MARK: - Processes

    struct ToolResult: Sendable { let status: Int32; let output: String }

    static func runSync(_ tool: String, _ arguments: [String]) throws -> ToolResult {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would block the tool forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func run(_ tool: String, _ arguments: [String]) async throws -> ToolResult {
        try await Task.detached(priority: .userInitiated) { try runSync(tool, arguments) }.value
    }
}

/// A disk-image download with progress. `URLSession.bytes` is far too slow for tens of megabytes.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var target: URL?

    func fetch(_ url: URL, to target: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        self.target = target
        self.progress = progress
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let target else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { finish(UpdateInstaller.Failure(message: "The download failed (HTTP \(status)).")); return }
        do { try FileManager.default.moveItem(at: location, to: target); finish(nil) } catch { finish(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

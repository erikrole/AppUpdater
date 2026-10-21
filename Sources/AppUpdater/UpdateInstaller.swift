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
        sweepLeftovers(for: destination)
        let work = fm.temporaryDirectory.appending(path: "AppUpdater-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let dmg = work.appending(path: "update.dmg")
            try await Downloader().fetch(release.downloadURL, to: dmg, progress: progress)
            try Task.checkCancellation()

            let mountPoint = work.appending(path: "mount")
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let attach = try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
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
                try await verify(staged, release: release, configuration: configuration)
                // Verified, so it is safe to let the OS treat it as the same trusted app (hosts with quarantine on).
                _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
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
        if destination.path.contains("/AppTranslocation/") {
            throw Failure(message: "Move \(destination.lastPathComponent) to your Applications folder first, then update.")
        }
        let folder = destination.deletingLastPathComponent()
        if (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw Failure(message: "Move \(destination.lastPathComponent) to your Applications folder first, then update.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Failure(message: "\(destination.lastPathComponent) is in a folder this Mac user can't change.")
        }
    }

    /// Removes staging copies and backups an interrupted update left beside the app.
    static func sweepLeftovers(for destination: URL) {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        for item in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            if item.hasPrefix(".\(name).update-") || item == ".\(name).backup" {
                try? fm.removeItem(at: folder.appending(path: item))
            }
        }
    }

    static func findApp(in directory: URL, named name: String) -> URL? {
        let apps = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        return apps.first { $0.lastPathComponent == name } ?? apps.first
    }

    // MARK: - Verification

    static func verify(_ app: URL, release: ReleaseInfo? = nil, configuration: AppUpdater.Configuration) async throws {
        // The requirement makes codesign itself insist on an Apple-anchored certificate for our Team ID.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(configuration.teamID)\""
        let strict = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path])
        guard strict.status == 0 else { throw Failure(message: "The downloaded update's signature is invalid, so it wasn't installed.") }
        let details = try await run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard teamID(in: details.output) == configuration.teamID else {
            throw Failure(message: "The downloaded update isn't signed by the expected developer, so it wasn't installed.")
        }
        let bundle = Bundle(url: app)
        guard bundle?.bundleIdentifier == configuration.bundleIdentifier else {
            throw Failure(message: "The downloaded update isn't this app, so it wasn't installed.")
        }
        // A release tagged newer than the build inside would be offered again after every install.
        if let release {
            let built = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            guard !ReleaseInfo.isNewer(release.version, than: built), !ReleaseInfo.isNewer(built, than: release.version) else {
                throw Failure(message: "The update's version (\(built)) doesn't match the release (\(release.version)), so it wasn't installed.")
            }
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

    /// Starts a detached helper that waits for this process to exit, opens the installed app as a new instance,
    /// and deletes the backup. If the new app won't open, the helper puts the backup back and opens that.
    /// Running it as a separate process means the old app can finish quitting (save sheets and all) first,
    /// and the swap never pulls files out from under live code that still needs them.
    static func scheduleRelaunch(destination: URL, backup: URL, waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if /usr/bin/open -n "$2"; then
          sleep 2
          rm -rf "$3"
        else
          rm -rf "$2"
          mv "$3" "$2" && /usr/bin/open -n "$2"
        fi
        """
        // Its own session, so the helper is not tied to this process's session or process group: a Force Quit of a stuck
        // app (or anything that signals the group) must not take the relaunch down with it.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in Int32(0)...2 { posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0) }
        let arguments = ["/bin/sh", "-c", script, "sh", String(pid), destination.path, backup.path]
        var cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, cArguments, environ)
        guard status == 0 else { throw Failure(message: "Couldn't start the relaunch helper (\(status)).") }
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

/// A disk-image download with progress, cancellation, and https-only redirects.
/// `URLSession.bytes` is far too slow for tens of megabytes.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var progress: (@Sendable (Double) -> Void)?
    private var target: URL?
    /// Extra URL protocol classes, for tests.
    var protocolClasses: [AnyClass] = []

    func fetch(_ url: URL, to target: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url)
                lock.withLock {
                    self.target = target
                    self.progress = progress
                    self.continuation = continuation
                    self.task = task
                }
                if Task.isCancelled { finish(CancellationError()); return }
                task.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.withLock { progress }?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let target = lock.withLock({ target }) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { finish(UpdateInstaller.Failure(message: "The download failed (HTTP \(status)).")); return }
        do { try FileManager.default.moveItem(at: location, to: target); finish(nil) } catch { finish(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish((error as? URLError)?.code == .cancelled ? CancellationError() : error)
    }

    private func finish(_ error: Error?) {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

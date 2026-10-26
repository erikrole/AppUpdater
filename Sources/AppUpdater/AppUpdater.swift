import AppKit
import os
import Foundation

/// Checks a GitHub releases repository for a newer build of this app, shows a splash with the release notes,
/// and installs the update and relaunches with one click.
///
///     let updater = AppUpdater(.init(repository: "erikrole/offload-releases", assetName: "Offload.dmg"))
///     updater.checkOnLaunch()          // applicationDidFinishLaunching
///     updater.checkNow()               // "Check for Updates…" menu item
@MainActor
public final class AppUpdater {
    /// Lets the host app dress the window in its own colours. Every field is optional; the defaults follow the system.
    public struct Style: @unchecked Sendable {
        /// Fill of the primary button and tint of the bullets. Default: the system accent colour.
        public var accentColor: NSColor?
        /// Colour of the small "UPDATE AVAILABLE" label. Default: `accentColor`.
        public var kickerColor: NSColor?
        /// Shown at the top of the window. Default: the app's icon.
        public var icon: NSImage?
        /// Replaces the headline ("Offload 1.5.3 is ready.") when it returns a string.
        public var title: (@MainActor @Sendable (_ release: ReleaseInfo, _ justUpdated: Bool) -> String?)?
        /// Replaces the primary button title ("Update and Relaunch").
        public var primaryButtonTitle: String?

        public init(
            accentColor: NSColor? = nil,
            kickerColor: NSColor? = nil,
            icon: NSImage? = nil,
            title: (@MainActor @Sendable (_ release: ReleaseInfo, _ justUpdated: Bool) -> String?)? = nil,
            primaryButtonTitle: String? = nil
        ) {
            self.accentColor = accentColor
            self.kickerColor = kickerColor
            self.icon = icon
            self.title = title
            self.primaryButtonTitle = primaryButtonTitle
        }
    }

    /// What opens after an update has installed and the new version launches.
    public enum PostUpdate: Sendable { case window, quiet }

    /// Which releases a check may offer. Production is every app's default: stable releases only (`releases/latest`).
    /// Beta also offers prereleases (`X.Y.Z-beta.N`) and picks the newest release of either kind. An update is only ever
    /// offered when it is newer than the installed version, so leaving beta never downgrades.
    public enum UpdateChannel: String, Sendable { case production, beta }

    public struct Configuration: @unchecked Sendable {
        /// `owner/name` of the public releases repository.
        public var repository: String
        /// The stable disk image name on each release, e.g. "Offload.dmg". A versioned `Offload-1.5.3.dmg` is preferred when present.
        public var assetName: String
        public var bundleIdentifier: String
        /// Updates must be signed by this Apple Team ID.
        public var teamID: String
        /// Where the app is installed. Defaults to the running bundle.
        public var appURL: URL
        public var displayName: String
        /// Launch checks are skipped if one ran more recently than this.
        public var minimumCheckInterval: TimeInterval
        /// The installed version; defaults to `CFBundleShortVersionString`. Override to test.
        public var currentVersion: String
        /// Return a reason (shown in the window) to hold an update back, such as "A copy is in progress."
        public var busyReason: @MainActor @Sendable () -> String?
        public var style: Style
        /// Called on the main actor, after the fact and never inline, for each step of the update flow. It cannot
        /// change the flow. Keep it quick (queue the event; don't do network work in it).
        public var onEvent: (@MainActor @Sendable (Event) -> Void)?
        /// Shown when a release has no notes and none were cached from an earlier fetch.
        public var fallbackNotes: String?
        /// What the new version does the first time it opens after an update: the "UPDATED" window (default), or nothing at all
        /// (`.quiet`; the host can show its own note when it sees the `.installed` event).
        public var postUpdate: PostUpdate
        /// Asked when the app is still open 5 seconds after the update asked it to quit (a quit that stalled, with no alert up).
        /// Return true only when exiting now loses nothing: flush anything unsaved first. AppUpdater then exits the process so the
        /// relaunch helper can open the new version. nil never forces an exit.
        public var safeToExit: (@MainActor @Sendable () async -> Bool)?
        /// Read at every check, so a Settings switch takes effect on the next check. Defaults to production.
        public var channel: @Sendable () -> UpdateChannel

        public init(
            repository: String,
            assetName: String,
            bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
            teamID: String = "T26T3G8C7Q",
            appURL: URL = Bundle.main.bundleURL,
            displayName: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent,
            minimumCheckInterval: TimeInterval = 6 * 3600,
            currentVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0",
            busyReason: @escaping @MainActor @Sendable () -> String? = { nil },
            style: Style = Style(),
            fallbackNotes: String? = nil,
            postUpdate: PostUpdate = .window,
            safeToExit: (@MainActor @Sendable () async -> Bool)? = nil,
            channel: @escaping @Sendable () -> UpdateChannel = { .production },
            onEvent: (@MainActor @Sendable (Event) -> Void)? = nil
        ) {
            self.postUpdate = postUpdate
            self.channel = channel
            self.safeToExit = safeToExit
            self.onEvent = onEvent
            self.style = style
            self.fallbackNotes = fallbackNotes
            self.repository = repository
            self.assetName = assetName
            self.bundleIdentifier = bundleIdentifier
            self.teamID = teamID
            self.appURL = appURL
            self.displayName = displayName
            self.minimumCheckInterval = minimumCheckInterval
            self.currentVersion = currentVersion
            self.busyReason = busyReason
        }
    }

    /// Something that happened in the update flow, for telemetry. See `Configuration.onEvent`.
    public struct Event: Sendable, Equatable {
        public enum Kind: String, Sendable { case shown, accepted, skipped, deferred, installed, failed }
        /// What opened the splash.
        public enum Trigger: String, Sendable { case launch, manual }

        public var kind: Kind
        /// The version that was running when the update was offered.
        public var fromVersion: String
        /// The version that was offered (or installed).
        public var toVersion: String
        /// For `.shown`: whether it came from the launch check or a menu item.
        public var trigger: Trigger?
        /// For `.failed`: what went wrong, in words.
        public var error: String?
    }

    public enum CheckOutcome: Equatable, Sendable {
        case available(ReleaseInfo)
        case upToDate
        case skipped(String)
        case tooSoon
        case failed(String)
    }

    let configuration: Configuration
    let defaults: UserDefaults
    /// Fetches the latest-release JSON. Replaced in tests.
    var fetch: @Sendable (URL) async throws -> (Data, Int)
    let notesCache: NotesCache
    private(set) var window: UpdateWindowController?
    private var checking = false

    public init(_ configuration: Configuration, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
        self.notesCache = NotesCache(bundleIdentifier: configuration.bundleIdentifier)
        self.fetch = { url in
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("\(configuration.bundleIdentifier)/\(configuration.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - Public entry points

    /// Call once at launch. Shows what's new if the app was just updated; otherwise checks quietly, at most
    /// once per `minimumCheckInterval`, and only opens a window when there's an update.
    public func checkOnLaunch() {
        UpdateInstaller.sweepLeftovers(for: configuration.appURL)
        if showJustUpdated() { return }
        Task { await check(userInitiated: false, trigger: .launch) }
    }

    /// For a "Check for Updates…" menu item: always checks, and says so when the app is current or offline.
    public func checkNow() {
        Task { await check(userInitiated: true, trigger: .manual) }
    }

    /// Opens the update window for a made-up release, to see how it looks. Installing from it will fail.
    public func showPreview(_ release: ReleaseInfo) { present(.available(release)) }

    // MARK: - Checking

    func check(userInitiated: Bool, trigger: Event.Trigger? = nil) async {
        guard !checking, window == nil else { window?.bringToFront(); return }
        checking = true
        defer { checking = false }
        switch await evaluate(userInitiated: userInitiated) {
        case let .available(release):
            present(.available(release), trigger: trigger ?? (userInitiated ? .manual : .launch))
        case .upToDate:
            if userInitiated { alert("\(configuration.displayName) is up to date.", "You have version \(configuration.currentVersion), the latest release.") }
        case .failed:
            if userInitiated { alert("Couldn't check for updates.", "Make sure you're online, then try again.") }
        case .skipped, .tooSoon:
            break
        }
    }

    /// The decision part of a check, without any UI.
    func evaluate(userInitiated: Bool, now: Date = Date()) async -> CheckOutcome {
        if !userInitiated, let last = defaults.object(forKey: Keys.lastCheck) as? Date,
           now.timeIntervalSince(last) < configuration.minimumCheckInterval {
            return .tooSoon
        }
        let beta = configuration.channel() == .beta
        guard configuration.repository.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(configuration.repository)/releases" + (beta ? "?per_page=20" : "/latest")) else {
            return .failed("Bad repository name.")
        }
        do {
            let (data, status) = try await fetch(url)
            let found = status == 200
                ? (beta ? ReleaseInfo.newest(inList: data, assetName: configuration.assetName, allowPrerelease: true)
                        : ReleaseInfo.parse(data, assetName: configuration.assetName))
                : nil
            guard let release = found else {
                return .failed(status == 200 ? "Couldn't read the release." : "GitHub returned status \(status).")
            }
            defaults.set(now, forKey: Keys.lastCheck)
            guard ReleaseInfo.isNewer(release.version, than: configuration.currentVersion) else { return .upToDate }
            if !userInitiated, defaults.string(forKey: Keys.skipped) == release.version { return .skipped(release.version) }
            return .available(release)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Notes to show: the release's own, else the last ones cached for that version, else the host's fallback,
    /// else a short generic line. Never empty.
    func resolvedNotes(for release: ReleaseInfo) -> String {
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            notesCache.save(notes, version: release.version)
            return notes
        }
        if let cached = notesCache.load(version: release.version) { return cached }
        if let fallback = configuration.fallbackNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty { return fallback }
        return "Improvements and fixes."
    }

    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version, forKey: Keys.skipped)
        decision = .skipped
        emit(.skipped, release)
    }

    // MARK: - Events

    private enum Decision { case none, skipped, installing }
    private var decision = Decision.none

    /// Hands an event to the host's hook on a later main-actor turn, so a slow or misbehaving hook can't hold up
    /// (or break) the update flow.
    func emit(_ kind: Event.Kind, _ release: ReleaseInfo, trigger: Event.Trigger? = nil, error: String? = nil, from: String? = nil) {
        guard let hook = configuration.onEvent else { return }
        let event = Event(kind: kind, fromVersion: from ?? configuration.currentVersion, toVersion: release.version, trigger: trigger, error: error)
        Task { @MainActor in hook(event) }
    }

    // MARK: - What's new after an update

    func showJustUpdated() -> Bool {
        guard let saved = defaults.dictionary(forKey: Keys.justUpdated),
              let version = saved["version"] as? String else { return false }
        defaults.removeObject(forKey: Keys.justUpdated)
        guard version == configuration.currentVersion else { return false }
        let release = ReleaseInfo(
            version: version,
            notes: saved["notes"] as? String ?? "",
            downloadURL: URL(string: "https://github.com")!,
            pageURL: (saved["page"] as? String).flatMap(URL.init(string:)),
            date: saved["date"] as? Date
        )
        emit(.installed, release, from: saved["from"] as? String ?? "")
        // Quiet: no window, and the launch check carries on as usual.
        guard configuration.postUpdate == .window else { return false }
        present(.updated(release))
        return true
    }

    /// The relaunch helper that is waiting for this app to quit, with the folders it will swap.
    private struct PendingRelaunch {
        var helper: pid_t?
        let destination: URL
        let backup: URL
        let lease: UpdateInstaller.InstallationLock
        let token = UUID()
    }
    private var pendingRelaunch: PendingRelaunch?

    /// The quit was cancelled (a save sheet answered "Keep Open", say) and the person no longer wants to wait: ends the helper,
    /// puts the previous version back and lets the update be started again. Does nothing when no relaunch is waiting.
    public func cancelPendingQuit() {
        do { try cancelPendingQuitAndRestore() }
        catch { Self.log.error("Couldn't restore the previous app: \(error.localizedDescription, privacy: .public)") }
    }

    func cancelPendingQuitAndRestore() throws {
        guard var pending = pendingRelaunch else { return }
        // Invalidate the fallback before touching the helper. If restoration fails, keep the lease and
        // backup for another attempt, but never signal a stale PID or force the host to quit.
        if let helper = pending.helper {
            var result: pid_t
            repeat { result = waitpid(helper, nil, WNOHANG) } while result < 0 && errno == EINTR
            if result == 0 {
                guard kill(helper, SIGKILL) == 0 || errno == ESRCH else {
                    throw UpdateInstaller.Failure(message: "Couldn't stop the relaunch helper. Try again before restoring the previous app.")
                }
                while waitpid(helper, nil, 0) < 0 && errno == EINTR {}
            }
        }
        pending.helper = nil
        pendingRelaunch = pending
        try UpdateInstaller.rollback(destination: pending.destination, backup: pending.backup)
        pendingRelaunch = nil
        defaults.removeObject(forKey: Keys.justUpdated)
        decision = .none
        isInstalling = false
    }

    /// Asks the app to quit from a run-loop callout, not from inside the caller's main-actor task.
    ///
    /// `terminate:` waits in a nested event loop when the delegate answers `.terminateLater`. Called from inside a Swift task
    /// (a main-queue job), that job is still running, so the main queue cannot run the delegate's own task that would reply:
    /// the quit never finishes and the update hangs on "Relaunching…". A timer callout is not a main-queue job, so the queue
    /// keeps running while `terminate:` waits.
    static let log = Logger(subsystem: "com.erole.AppUpdater", category: "update")

    /// `requestQuit()`, then, if the app is still open after `wait` with no alert or sheet up and `safeToExit` says nothing would be
    /// lost, exits the process so a waiting relaunch helper can open the new version. Returns only if the app stays open.
    @MainActor public static func requestQuit(fallbackAfter wait: Duration, safeToExit: (@MainActor () async -> Bool)?) async {
        await requestQuit(fallbackAfter: wait, safeToExit: safeToExit, stillPending: { true })
    }

    @MainActor static func requestQuit(
        fallbackAfter wait: Duration,
        safeToExit: (@MainActor () async -> Bool)?,
        stillPending: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, stillPending() else { return }
        requestQuit()
        do { try await Task.sleep(for: wait) } catch { return }
        guard !Task.isCancelled, stillPending(), !hasPendingDialog, let safeToExit, await safeToExit() else { return }
        // Saving yields the main actor: a sheet may open, the task may be cancelled, or Don't Wait
        // may restore the old app while the host is flushing its state.
        guard !Task.isCancelled, stillPending(), !hasPendingDialog else { return }
        log.error("the app was still open \(wait.components.seconds) s after the quit request with nothing pending; exiting so the update can open")
        exit(0)
    }

    private static var hasPendingDialog: Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil || $0.isSheet }
    }

    @MainActor public static func requestQuit() {
        log.info("requestQuit: scheduling terminate on the run loop")
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
    }

    func rememberInstall(of release: ReleaseInfo) {
        var saved: [String: Any] = ["version": release.version, "notes": release.notes, "from": configuration.currentVersion]
        if let page = release.pageURL { saved["page"] = page.absoluteString }
        if let date = release.date { saved["date"] = date }
        defaults.set(saved, forKey: Keys.justUpdated)
    }

    // MARK: - UI

    private func present(_ mode: UpdateWindowController.Mode, trigger: Event.Trigger? = nil) {
        let controller = UpdateWindowController(mode: mode, updater: self)
        decision = .none
        controller.onClose = { [weak self] in
            guard let self else { return }
            // Closing the splash without skipping or installing is "Later", however it was closed.
            if case let .available(release) = mode, self.decision == .none { self.emit(.deferred, release) }
            self.decision = .none
            self.window = nil
        }
        window = controller
        controller.show()
        if case let .available(release) = mode, let trigger { emit(.shown, release, trigger: trigger) }
    }

    private func alert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.icon = NSApp.applicationIconImage
        alert.runModal()
    }

    enum Keys {
        static let lastCheck = "AppUpdater.lastCheck"
        static let skipped = "AppUpdater.skippedVersion"
        static let justUpdated = "AppUpdater.justUpdated"
    }

    // MARK: - Install

    /// True from the moment an install starts until the app quits or the install fails. Hosts can consult this
    /// in `applicationShouldTerminate`.
    public private(set) var isInstalling = false

    /// True only after the verified swap and helper handoff. Hosts may allow the updater's quit at
    /// this point while continuing to block ordinary quit during preparation. Keep save/busy guards.
    public var isAwaitingRelaunch: Bool { pendingRelaunch?.helper != nil }

    /// Downloads, verifies, swaps in the new app and asks this one to quit. A detached helper opens the new app
    /// once this process has exited and removes the backup; if the new app won't open, it restores the old one.
    /// Progress is 0…1 for the download; `status` names later steps. Cancelling the task cancels the download.
    func install(
        _ release: ReleaseInfo,
        progress: @escaping @MainActor (Double) -> Void,
        status: @escaping @MainActor (String) -> Void,
        quitPending: @escaping @MainActor () -> Void = {}
    ) async throws {
        guard !isInstalling else { return }
        decision = .installing
        emit(.accepted, release)
        do {
            try await performInstall(release, progress: progress, status: status, quitPending: quitPending)
        } catch is CancellationError {
            // Backing out of the download is a "Later".
            decision = .none
            throw CancellationError()
        } catch {
            decision = .none
            emit(.failed, release, error: error.localizedDescription)
            throw error
        }
    }

    private func performInstall(
        _ release: ReleaseInfo,
        progress: @escaping @MainActor (Double) -> Void,
        status: @escaping @MainActor (String) -> Void,
        quitPending: @escaping @MainActor () -> Void
    ) async throws {
        if let reason = configuration.busyReason() { throw UpdateInstaller.Failure(message: reason) }
        isInstalling = true
        var finishedHandOff = false
        defer { if !finishedHandOff { isInstalling = false } }

        let destination = configuration.appURL
        let configuration = configuration
        let prepared = try await UpdateInstaller.prepare(release: release, destination: destination, configuration: configuration) { fraction in
            Task { @MainActor in progress(fraction) }
        }
        defer {
            try? FileManager.default.removeItem(at: prepared.staged)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            withExtendedLifetime(prepared.lease) {}
        }

        // The download can take minutes; the app may have started something since.
        try Task.checkCancellation()
        if let reason = configuration.busyReason() {
            throw UpdateInstaller.Failure(message: reason)
        }
        try Task.checkCancellation()
        status("Installing…")
        let backup: URL
        do {
            backup = try UpdateInstaller.swap(destination: destination, with: prepared.staged)
        } catch {
            try? FileManager.default.removeItem(at: prepared.staged)
            throw error
        }
        rememberInstall(of: release)
        do {
            let helper = try UpdateInstaller.scheduleRelaunch(destination: destination, backup: backup, lease: prepared.lease)
            pendingRelaunch = PendingRelaunch(helper: helper, destination: destination, backup: backup, lease: prepared.lease)
        } catch {
            try UpdateInstaller.rollback(destination: destination, backup: backup)
            defaults.removeObject(forKey: Keys.justUpdated)
            throw UpdateInstaller.Failure(message: "Couldn't finish the update, so the previous version was kept. \(error.localizedDescription)")
        }
        finishedHandOff = true
        status("Relaunching…")
        Self.log.info("update installed; asking the app to quit")
        // Still here afterwards: the app asked to finish something first (a save sheet, say) or its quit stalled.
        let token = pendingRelaunch?.token
        await Self.requestQuit(fallbackAfter: .seconds(5), safeToExit: configuration.safeToExit) { [weak self] in
            self?.pendingRelaunch?.token == token && self?.pendingRelaunch?.helper != nil
        }
        guard pendingRelaunch?.token == token, pendingRelaunch?.helper != nil else { return }
        Self.log.info("the app is still open after the quit request; waiting for it")
        status("Finish up in \(configuration.displayName). The update opens as soon as it quits.")
        quitPending()
    }
}

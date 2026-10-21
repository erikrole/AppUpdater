import AppKit
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
            onEvent: (@MainActor @Sendable (Event) -> Void)? = nil
        ) {
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
        guard configuration.repository.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(configuration.repository)/releases/latest") else {
            return .failed("Bad repository name.")
        }
        do {
            let (data, status) = try await fetch(url)
            guard status == 200, let release = ReleaseInfo.parse(data, assetName: configuration.assetName) else {
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

    private func showJustUpdated() -> Bool {
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
        present(.updated(release))
        emit(.installed, release, from: saved["from"] as? String ?? "")
        return true
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

    /// Downloads, verifies, swaps in the new app and asks this one to quit. A detached helper opens the new app
    /// once this process has exited and removes the backup; if the new app won't open, it restores the old one.
    /// Progress is 0…1 for the download; `status` names later steps. Cancelling the task cancels the download.
    func install(
        _ release: ReleaseInfo,
        progress: @escaping @MainActor (Double) -> Void,
        status: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !isInstalling else { return }
        decision = .installing
        emit(.accepted, release)
        do {
            try await performInstall(release, progress: progress, status: status)
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
        status: @escaping @MainActor (String) -> Void
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
        defer { try? FileManager.default.removeItem(at: prepared.workDirectory) }

        // The download can take minutes; the app may have started something since.
        if let reason = configuration.busyReason() {
            try? FileManager.default.removeItem(at: prepared.staged)
            throw UpdateInstaller.Failure(message: reason)
        }
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
            try UpdateInstaller.scheduleRelaunch(destination: destination, backup: backup)
        } catch {
            UpdateInstaller.rollback(destination: destination, backup: backup)
            defaults.removeObject(forKey: Keys.justUpdated)
            throw UpdateInstaller.Failure(message: "Couldn't finish the update, so the previous version was kept. \(error.localizedDescription)")
        }
        finishedHandOff = true
        status("Relaunching…")
        NSApp.terminate(nil)
        // Still here: the app asked to finish something first (a save sheet, say). The helper waits for it to quit,
        // then opens the new version, so there is nothing more to do but say so.
        status("Finish up in \(configuration.displayName). The update opens as soon as it quits.")
    }
}

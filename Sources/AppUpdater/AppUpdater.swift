import AppKit
import os
import Foundation
import Observation

/// Checks a GitHub releases repository for a newer build of this app and installs it quietly. There is no splash and no
/// modal: a small pill at the top-right of the host window (or under its menu bar item) shows "Updating", then
/// "Restart to update", and on the first launch of the new version a "What's new" pill with a few release-note bullets.
///
///     let updater = AppUpdater(.init(repository: "erikrole/offload-releases", assetName: "Offload.dmg"))
///     updater.hostView = window.contentView   // or statusItem.button for a menu bar app
///     updater.checkOnLaunch()          // applicationDidFinishLaunching
///     updater.checkNow()               // "Check for Updates…" menu item
@MainActor
public final class AppUpdater {
    /// Lets the host app dress the pill in its own colour. Every field is optional; the defaults follow the system.
    public struct Style: @unchecked Sendable {
        /// Tint of the pill's dot. Default: the system accent colour.
        public var accentColor: NSColor?
        /// No longer used: the splash window is gone. Kept so existing hosts still compile.
        public var kickerColor: NSColor?
        /// No longer used: the splash window is gone. Kept so existing hosts still compile.
        public var icon: NSImage?
        /// No longer used: the splash window is gone. Kept so existing hosts still compile.
        public var title: (@MainActor @Sendable (_ release: ReleaseInfo, _ justUpdated: Bool) -> String?)?
        /// No longer used: the splash window is gone. Kept so existing hosts still compile.
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

    /// What shows after an update has installed and the new version launches: the "What's new" pill (`.window`, the
    /// default name is kept for source compatibility), or nothing at all (`.quiet`; the host can show its own note when it sees
    /// the `.installed` event).
    public enum PostUpdate: Sendable { case window, quiet }

    /// Where the quiet update is. Hosts can mirror it in a menu (`menuTitle`, `performPrimaryAction()`).
    public enum State: Equatable, Sendable {
        case idle
        /// Downloading and verifying `version`.
        case updating(version: String)
        /// `version` is downloaded and verified; restarting installs it.
        case ready(version: String)
        /// A newer release was found but not downloaded (beta, or `autoInstall` is off). Clicking starts the download.
        case available(version: String)
        /// The last attempt failed. Quiet at launch; a manual check or `retry()` shows it.
        case failed(message: String)
    }

    /// Which releases a check may offer. Production is every app's default: stable releases only (`releases/latest`).
    /// Beta also offers prereleases (`X.Y.Z-beta.N`) and picks the newest release of either kind. An update is only ever
    /// offered when it is newer than the installed version, so leaving beta never downgrades.
    public enum UpdateChannel: String, Codable, Sendable { case production, beta }

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
        /// Minimum time between successful automatic checks.
        public var minimumCheckInterval: TimeInterval
        /// The installed version; defaults to `CFBundleShortVersionString`. Override to test.
        public var currentVersion: String
        /// Return a reason to hold an update back, such as "A copy is in progress." The update waits and retries later.
        public var busyReason: @MainActor @Sendable () -> String?
        public var style: Style
        /// Called on the main actor, after the fact and never inline, for each step of the update flow. It cannot
        /// change the flow. Keep it quick (queue the event; don't do network work in it).
        public var onEvent: (@MainActor @Sendable (Event) -> Void)?
        /// Used for the "What's new" pill when a release has no notes and none were cached from an earlier fetch.
        public var fallbackNotes: String?
        /// What the new version does the first time it opens after an update: the "UPDATED" window (default), or nothing at all
        /// (`.quiet`; the host can show its own note when it sees the `.installed` event).
        public var postUpdate: PostUpdate
        /// Asked when the app is still open 5 seconds after the update asked it to quit (a quit that stalled, with no alert up).
        /// Return true only when exiting now loses nothing: flush anything unsaved first. AppUpdater then exits the process so the
        /// relaunch helper can open the new version. nil never forces an exit.
        public var safeToExit: (@MainActor @Sendable () async -> Bool)?
        /// Set when `repository` holds releases for several apps (for example `erikrole/releases`): only tags that start with
        /// this prefix, such as `scratchpad-v1.5.0`, belong to this app. Checks then read the newest 100 releases instead of
        /// `releases/latest`, and the rate-limit web fallback is not used.
        public var tagPrefix: String?
        /// Optional per-app stable feed hosted on raw.githubusercontent.com.
        public var stableFeedURL: URL?
        /// Read at every check, so a Settings switch takes effect on the next check. Defaults to production.
        public var channel: @Sendable () -> UpdateChannel
        /// Whether automatic checks download and stage stable releases. This never initiates a restart.
        /// Hosts can wire this to a Settings switch.
        public var autoInstall: @Sendable () -> Bool
        /// Opt-in permission to apply a verified stable update on the next ordinary, host-approved quit.
        public var installOnQuit: @Sendable () -> Bool

        public init(
            repository: String,
            assetName: String,
            bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
            teamID: String = "T26T3G8C7Q",
            appURL: URL = Bundle.main.bundleURL,
            displayName: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent,
            minimumCheckInterval: TimeInterval = 3600,
            currentVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0",
            busyReason: @escaping @MainActor @Sendable () -> String? = { nil },
            style: Style = Style(),
            fallbackNotes: String? = nil,
            postUpdate: PostUpdate = .window,
            safeToExit: (@MainActor @Sendable () async -> Bool)? = nil,
            channel: @escaping @Sendable () -> UpdateChannel = { .production },
            autoInstall: @escaping @Sendable () -> Bool = { true },
            tagPrefix: String? = nil,
            stableFeedURL: URL? = nil,
            installOnQuit: @escaping @Sendable () -> Bool = { false },
            onEvent: (@MainActor @Sendable (Event) -> Void)? = nil
        ) {
            self.postUpdate = postUpdate
            self.tagPrefix = tagPrefix
            self.stableFeedURL = stableFeedURL
            self.channel = channel
            self.autoInstall = autoInstall
            self.installOnQuit = installOnQuit
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
        /// What put the "Update available" pill up.
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
    var fetchStableFeed: @Sendable (URL) async throws -> Data = StableReleaseFeed.fetch
    let notesCache: NotesCache
    private var checking = false
    private var preparedBackgroundChecks = false
    private var pendingOffer: ReleaseInfo?
    private var checkedDuringThisRun = false
    private var automaticSchedule: AutomaticUpdateSchedule?
    private var offeredVersions: Set<String> = []
    let pill = PillController()

    /// The view the pill hangs from, top-right: the window's content view, or a menu bar app's `statusItem.button`
    /// (the pill then sits under the item). This one line is all a host adds. Unset, the pill uses the main window.
    public weak var hostView: NSView? { didSet { pill.refresh() } }
    /// Convenience for `hostView = window?.contentView`.
    public var hostWindow: NSWindow? {
        get { hostView?.window }
        set { hostView = newValue?.contentView }
    }

    @Observable @MainActor
    final class Presentation {
        var state: State = .idle
    }

    private let presentation = Presentation()

    /// Where the update stands. SwiftUI can observe it directly, or AppKit can use `onStateChange`.
    public internal(set) var state: State {
        get { presentation.state }
        set {
            guard newValue != presentation.state else { return }
            presentation.state = newValue
            refreshPill()
            onStateChange?(newValue)
            recordStatus()
        }
    }
    /// Called on the main actor whenever `state` changes.
    public var onStateChange: (@MainActor (State) -> Void)?

    /// Text for a menu item that mirrors the pill: "Restart to update", "Update failed. Retry" or "Update available",
    /// nil when there's nothing to do. `performPrimaryAction()` does what the pill's click does.
    public var menuTitle: String? {
        switch state {
        case .ready: "Restart to update"
        case .failed: "Update failed. Retry"
        case .available: "Update available"
        case .idle, .updating: nil
        }
    }

    /// The release behind the current state, for retrying and for the "Installing vX" hover.
    private var currentRelease: ReleaseInfo?
    /// A failure is only drawn when a person asked for the check or the retry.
    private var failureVisible = false
    /// A short "Up to date" confirmation after a manual check.
    private var flash: PillContent?
    private var flashTask: Task<Void, Never>?
    private var stageTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    /// The What's new pill stays up while its popover is open, even after it was marked as seen.
    private var holdingWhatsNew = false
    var previewWhatsNew: WhatsNew?

    public init(_ configuration: Configuration, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
        self.notesCache = NotesCache(bundleIdentifier: configuration.bundleIdentifier)
        self.fetch = { url in
            try await ReleaseFetcher.fetch(url, assetName: configuration.assetName,
                userAgent: "\(configuration.bundleIdentifier)/\(configuration.currentVersion)")
        }
        pill.anchorView = { [weak self] in self?.hostView }
        pill.accent = { [weak self] in self?.configuration.style.accentColor ?? .controlAccentColor }
        pill.onClick = { [weak self] in self?.performPrimaryAction() }
        pill.notesProvider = { [weak self] in self?.notesPopoverContent() }
        pill.onNotesOpened = { [weak self] in self?.whatsNewOpened() }
        pill.onNotesClosed = { [weak self] in self?.whatsNewClosed() }
        // A downloaded update that was never applied is just a leftover; the next launch sweeps it too.
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.automaticSchedule?.stop()
                self.discardHeld()
                if case .ready = self.state { self.state = .idle }
            }
        }
    }

    isolated deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        automaticSchedule?.stop()
    }

    // MARK: - Public entry points

    /// Call once on a normal app launch to start automatic checks for this updater's lifetime.
    public func checkOnLaunch() {
        markStartupReady()
        startAutomaticChecks()
    }

    /// Checks at launch, periodically, on activation, after wake, and when the network returns.
    /// The host controls when an update can be presented and can call this again without creating a second schedule.
    public func startAutomaticChecks(shouldPresent: @escaping @MainActor () -> Bool = { true }) {
        guard automaticSchedule == nil else { return }
        prepareForChecks()
        let schedule = AutomaticUpdateSchedule { [weak self] in
            guard let self else { return nil }
            return await self.checkInBackground(shouldPresent: shouldPresent, scheduled: true) { release in
                self.handleAvailable(release, userInitiated: false, trigger: .launch)
            }
        }
        automaticSchedule = schedule
        schedule.start()
    }

    /// Call once after the host finishes essential startup and can safely accept input.
    public func markStartupReady() {
        UpdateStartup.acknowledge(for: configuration.appURL, version: configuration.currentVersion)
        if preparedBackgroundChecks { UpdateInstaller.sweepLeftovers(for: configuration.appURL) }
        prepareForChecks()
    }

    private func prepareForChecks() {
        guard !preparedBackgroundChecks else { return }
        preparedBackgroundChecks = true
        UpdateInstaller.sweepLeftovers(for: configuration.appURL)
        _ = showJustUpdated()
        recordStatus()
    }

    /// An automatic check without starting the scheduler. A skipped version stays skipped.
    @discardableResult
    public func checkInBackground(shouldPresent: @MainActor () -> Bool = { true }) async -> CheckOutcome? {
        await checkInBackground(shouldPresent: shouldPresent, offer: { release in
            self.handleAvailable(release, userInitiated: false, trigger: .launch)
        })
    }

    // Separate presentation from the asynchronous decision so tests never start a download.
    func checkInBackground(shouldPresent: @MainActor () -> Bool = { true }, scheduled: Bool = false,
                           offer: @MainActor (ReleaseInfo) -> Void) async -> CheckOutcome? {
        guard !Task.isCancelled, canCheck else { return nil }
        prepareForChecks()
        guard scheduled || (configuration.busyReason() == nil && shouldPresent()) else { return nil }
        checking = true
        defer { checking = false }
        let channel = configuration.channel()
        let minimumInterval = scheduled ? max(300, configuration.minimumCheckInterval) : configuration.minimumCheckInterval
        let outcome = await evaluate(userInitiated: false, minimumInterval: minimumInterval)
        guard !Task.isCancelled, configuration.channel() == channel else { return nil }
        switch outcome {
        case .available(let release):
            pendingOffer = release
        case .upToDate, .skipped:
            pendingOffer = nil
            clearOffer()
        case .failed, .tooSoon:
            break
        }
        guard !isInstalling, stageTask == nil, applyTask == nil,
              configuration.busyReason() == nil, shouldPresent() else { return scheduled ? outcome : nil }
        if let release = pendingOffer, permits(release),
           !offeredVersions.contains(release.version) || hasUpdatedArchive(release) {
            pendingOffer = nil
            rememberOffer(release)
            offer(release)
        }
        return outcome
    }

    private func hasUpdatedArchive(_ release: ReleaseInfo) -> Bool {
        guard let currentRelease, ReleaseInfo.versionsMatch(release.version, currentRelease.version) else { return false }
        return release.downloadURL != currentRelease.downloadURL
            || (release.archiveSHA256 != nil && release.archiveSHA256 != currentRelease.archiveSHA256)
    }

    func rememberOffer(_ release: ReleaseInfo) {
        offeredVersions.insert(release.version)
    }

    private var canCheck: Bool {
        !checking && !isInstalling && stageTask == nil && applyTask == nil
    }

    private func permits(_ release: ReleaseInfo) -> Bool {
        configuration.channel() == .beta || (!release.isPrerelease && !ReleaseInfo.isBeta(release.version))
    }

    private func clearOffer() {
        guard currentRelease != nil, stageTask == nil, applyTask == nil, !isInstalling else { return }
        discardHeld()
        currentRelease = nil
        state = .idle
    }

    /// For a "Check for Updates…" menu item: always checks. A found update downloads at once (any channel); "Up to date"
    /// flashes briefly; a failure shows "Update failed. Retry". Never a dialog.
    public func checkNow() {
        Task { await check(userInitiated: true, trigger: .manual) }
    }

    /// Shows the "What's new" pill for a made-up release, to see how it looks. Nothing is saved.
    public func showPreview(_ release: ReleaseInfo) {
        previewWhatsNew = WhatsNew(version: release.version, notes: release.notes, page: release.pageURL, shown: Date(), dismissed: false)
        refreshPill()
    }

    /// Puts the pill in `state` without checking or installing anything, for previews. Clicking does nothing harmful: there is no download.
    public func showPreview(state preview: State) {
        previewWhatsNew = nil
        failureVisible = true
        self.state = preview
        refreshPill()
    }

    /// Opens the "What's new" popover if a "What's new" pill is up (hover or click does the same).
    public func openWhatsNew() { pill.showNotes() }

    /// What the pill's click does, for a menu item that mirrors it: restart when ready, retry after a failure,
    /// start the download when an update is available.
    public func performPrimaryAction() {
        switch state {
        case .ready: restartToUpdate()
        case .failed: retry()
        case .available:
            if let release = currentRelease, permits(release) { startStaging(release, visibleFailure: true) }
            else { clearOffer(); checkNow() }
        case .idle, .updating: break
        }
    }

    /// Pair with `menuTitle` to make the same control check or perform the current update action.
    public func performMenuAction() {
        if menuTitle != nil { performPrimaryAction() }
        else { checkNow() }
    }

    /// Installs the downloaded update and relaunches. Does nothing unless the state is `.ready` (or a quit is still waiting,
    /// in which case it asks again).
    public func restartToUpdate() {
        if pendingRelaunch?.helper != nil { Self.requestQuit(); return }
        guard case let .ready(version) = state, let prepared = held, applyTask == nil else { return }
        guard permits(prepared.release) else { clearOffer(); checkNow(); return }
        // The host got busy since the download finished: stay ready and try again on the next click.
        if let reason = configuration.busyReason() { Self.log.info("restart held back: \(reason, privacy: .public)"); return }
        held = nil
        applyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.applyTask = nil }
            do {
                try await self.apply(prepared, status: { _ in }, quitPending: { self.state = .ready(version: version) })
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.failureVisible = true
                if Self.countsAgainstRelease(error) { self.recordFailure(of: version) }
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Call immediately before returning `.terminateNow` for a normal, user-requested quit.
    /// The host must already have completed its busy checks and saves. A successful swap
    /// keeps the app closed and preserves the previous build until the next healthy launch.
    @discardableResult
    public func applyOnQuitIfReady() -> Bool {
        guard configuration.installOnQuit(), canCheck, let prepared = held,
              !prepared.release.isPrerelease, !ReleaseInfo.isBeta(prepared.release.version),
              configuration.busyReason() == nil, NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.isSheet || $0.attachedSheet != nil }) else { return false }
        held = nil
        defer { Self.cleanUp(prepared) }
        do {
            _ = try swapForStartup(prepared)
            rememberInstall(of: prepared.release)
            return true
        } catch {
            Self.log.error("Install on quit failed: \(error.localizedDescription, privacy: .public)")
            emit(.failed, prepared.release, error: error.localizedDescription)
            return false
        }
    }

    /// Starts again after "Update failed. Retry".
    public func retry() {
        guard case .failed = state else { return }
        defaults.removeObject(forKey: Keys.failed)
        if let release = currentRelease, permits(release) {
            startStaging(release, visibleFailure: true)
        } else {
            state = .idle
            checkNow()
        }
    }

    // MARK: - Checking

    func check(userInitiated: Bool, trigger: Event.Trigger? = nil) async {
        guard canCheck else { return }
        checking = true
        defer { checking = false }
        switch await evaluate(userInitiated: userInitiated) {
        case let .available(release):
            handleAvailable(release, userInitiated: userInitiated, trigger: trigger)
        case .upToDate:
            clearOffer()
            if userInitiated { flashPill("Up to date") }
        case .failed(let reason):
            Self.log.error("update check failed: \(reason, privacy: .public)")
            if userInitiated, held == nil {
                failureVisible = true
                state = .failed(message: reason)
            }
        case .skipped, .tooSoon:
            break
        }
    }

    /// What a found update turns into: a quiet download, or a pill that waits for a click.
    func handleAvailable(_ release: ReleaseInfo, userInitiated: Bool, trigger: Event.Trigger?) {
        if let held {
            guard !ReleaseInfo.versionsMatch(held.release.version, release.version) || hasUpdatedArchive(release) else { return }
            discardHeld()
        }
        currentRelease = release
        rememberOffer(release)
        if userInitiated || shouldAutoInstall(release) {
            startStaging(release, visibleFailure: userInitiated)
        } else if failureCount(for: release.version) >= Self.maxAutoInstallFailures {
            failureVisible = false
            state = .failed(message: "Couldn't install \(release.version).")
        } else if configuration.busyReason() == nil {
            // Beta, or automatic updates are switched off: wait for a click instead of downloading.
            state = .available(version: release.version)
            emit(.shown, release, trigger: trigger ?? .launch)
        }
    }

    /// Downloads and verifies `release` in the background. The pill reads "Updating", then "Restart to update"; a failure
    /// is remembered and stays quiet unless a person asked for it.
    func startStaging(_ release: ReleaseInfo, visibleFailure: Bool) {
        guard stageTask == nil else { return }
        currentRelease = release
        failureVisible = visibleFailure
        state = .updating(version: release.version)
        stageTask = Task { [weak self] in
            guard let self else { return }
            defer { self.stageTask = nil }
            do {
                self.held = try await self.stage(release, progress: { _ in })
                self.automaticSchedule?.downloadFinished()
                self.state = .ready(version: release.version)
            } catch is CancellationError {
                self.state = .idle
            } catch {
                // Only a release that failed counts against it. A busy app, another updater or no network is just a later try.
                if Self.countsAgainstRelease(error) { self.recordFailure(of: release.version) }
                Self.log.error("update to \(release.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if !self.failureVisible, !Self.countsAgainstRelease(error) {
                    self.offeredVersions.remove(release.version)
                    self.pendingOffer = release
                    self.automaticSchedule?.retryAfterDownloadDeferral()
                    self.state = .idle
                } else {
                    self.state = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    /// The decision part of a check, without any UI.
    func evaluate(userInitiated: Bool, now: Date = Date(), minimumInterval: TimeInterval? = nil) async -> CheckOutcome {
        let channel = configuration.channel()
        if !userInitiated, defaults.string(forKey: Keys.lastCheckChannel) == channel.rawValue, let last = defaults.object(forKey: Keys.lastCheck) as? Date,
           now >= last, now.timeIntervalSince(last) < (minimumInterval ?? configuration.minimumCheckInterval),
           checkedDuringThisRun || !previousCheckFoundUpdate {
            return .tooSoon
        }
        let beta = channel == .beta
        let prefix = configuration.tagPrefix.flatMap { $0.isEmpty ? nil : $0 }
        let query = prefix != nil ? "?per_page=100" : (beta ? "?per_page=20" : "/latest")
        guard configuration.repository.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(configuration.repository)/releases" + query) else {
            return .failed("Bad repository name.")
        }
        do {
            let release = try await resolveRelease(url, beta: beta, prefix: prefix, userInitiated: userInitiated, now: now)
            guard !Task.isCancelled, configuration.channel() == channel else { return .tooSoon }
            guard let release else { return .failed("This Mac does not meet the minimum macOS version for the available releases.") }
            checkedDuringThisRun = true
            recordStatus(latestVersion: release.version, checkedAt: now)
            defaults.set(channel.rawValue, forKey: Keys.lastCheckChannel)
            defaults.set(now, forKey: Keys.lastCheck)
            guard ReleaseInfo.isNewer(release.version, than: configuration.currentVersion) else { return .upToDate }
            if !userInitiated, defaults.string(forKey: Keys.skipped) == release.version { return .skipped(release.version) }
            return .available(release)
        } catch {
            if case ReleaseFetcher.Failure.limited(let reset) = error {
                automaticSchedule?.retryAfterRateLimit(reset)
            }
            return .failed(error.localizedDescription)
        }
    }

    private func resolveRelease(_ url: URL, beta: Bool, prefix: String?, userInitiated: Bool,
                                now: Date) async throws -> ReleaseInfo? {
        var cached: StableReleaseFeed.Selection?
        if !beta, let feedURL = configuration.stableFeedURL, let data = try? await fetchStableFeed(feedURL) {
            cached = StableReleaseFeed.select(data, repository: configuration.repository,
                                             assetName: configuration.assetName, tagPrefix: prefix)
        }
        let lastAudit = defaults.object(forKey: Keys.lastStableFeedAudit) as? Date
        if let cached, !userInitiated, let lastAudit, now >= lastAudit, now.timeIntervalSince(lastAudit) < 24 * 3600 {
            return cached.compatible
        }
        try Task.checkCancellation()
        do {
            let (data, status) = try await fetch(url)
            guard status == 200 else { throw ReleaseFetcher.Failure.http(status) }
            let release = prefix != nil || beta
                ? ReleaseInfo.newest(inList: data, assetName: configuration.assetName, allowPrerelease: beta, tagPrefix: prefix)
                : ReleaseInfo.parse(data, assetName: configuration.assetName)
            guard let release else { throw ReleaseFetcher.Failure.invalidResponse }
            if let cached {
                defaults.set(now, forKey: Keys.lastStableFeedAudit)
                // A public release newer than the entire feed may have been published just before the feed refresh.
                if !ReleaseInfo.isNewer(release.version, than: cached.newestListed.version) {
                    return cached.compatible
                }
                defaults.removeObject(forKey: Keys.lastStableFeedAudit)
            }
            return release
        } catch {
            guard let cached, !Task.isCancelled else { throw error }
            defaults.set(now, forKey: Keys.lastStableFeedAudit)
            return cached.compatible
        }
    }

    private var previousCheckFoundUpdate: Bool {
        guard let data = defaults.data(forKey: Keys.status),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return false }
        return ReleaseInfo.isNewer(status.latestVersion, than: configuration.currentVersion)
            && defaults.string(forKey: Keys.skipped) != status.latestVersion
    }

    /// A version that fails to install or to launch this many times stops installing itself and asks instead.
    static let maxAutoInstallFailures = 2

    /// Whether a launch check may install `release` without asking: opted in, stable, not failing, host idle.
    func shouldAutoInstall(_ release: ReleaseInfo) -> Bool {
        configuration.autoInstall()
            && !release.isPrerelease && !ReleaseInfo.isBeta(release.version)
            && failureCount(for: release.version) < Self.maxAutoInstallFailures
            && configuration.busyReason() == nil
    }

    /// Whether an install error says something about the release (bad signature, wrong app, a swap that failed) and not the moment.
    static func countsAgainstRelease(_ error: Error) -> Bool {
        if error is URLError { return false }
        if let failure = error as? UpdateInstaller.Failure, failure.isDeferral { return false }
        return true
    }

    func failureCount(for version: String) -> Int {
        guard let saved = defaults.dictionary(forKey: Keys.failed), let v = saved["version"] as? String,
              ReleaseInfo.versionsMatch(v, version) else { return 0 }
        return saved["count"] as? Int ?? 0
    }

    func recordFailure(of version: String) {
        defaults.set(["version": version, "count": failureCount(for: version) + 1] as [String: Any], forKey: Keys.failed)
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

    func showJustUpdated(now: Date = Date()) -> Bool {
        let current = configuration.currentVersion
        var record = storedWhatsNew()
        if let saved = defaults.dictionary(forKey: Keys.justUpdated), let version = saved["version"] as? String {
            defaults.removeObject(forKey: Keys.justUpdated)
            guard version == current else {
                // The relaunch helper put the old version back: that release didn't open, so count it against auto-install.
                recordFailure(of: version)
                return false
            }
            defaults.removeObject(forKey: Keys.failed)
            let release = ReleaseInfo(
                version: version,
                notes: saved["notes"] as? String ?? "",
                downloadURL: URL(string: "https://github.com")!,
                pageURL: (saved["page"] as? String).flatMap(URL.init(string:)),
                date: saved["date"] as? Date
            )
            emit(.installed, release, from: saved["from"] as? String ?? "")
            record = WhatsNew(version: version, notes: release.notes, page: release.pageURL, shown: now, dismissed: false)
        } else if let last = defaults.string(forKey: Keys.lastSeen), ReleaseInfo.isNewer(current, than: last), record?.version != current,
                  let cached = notesCache.load(version: current) {
            // Updated some other way (copied over by hand, say): the notes cached at the last check still tell what changed.
            record = WhatsNew(version: current, notes: cached, page: nil, shown: now, dismissed: false)
        }
        defaults.set(current, forKey: Keys.lastSeen)
        // Quiet: no pill, and the launch check carries on as usual.
        guard configuration.postUpdate == .window else { return false }
        if let record { save(record) }
        refreshPill()
        return activeWhatsNew(now: now) != nil
    }

    // MARK: - What's new pill

    /// How long the pill waits to be opened before it goes away on its own.
    static let whatsNewLifetime: TimeInterval = 3 * 24 * 3600

    struct WhatsNew: Equatable {
        var version: String
        var notes: String
        var page: URL?
        var shown: Date
        var dismissed: Bool
    }

    func storedWhatsNew() -> WhatsNew? {
        guard let saved = defaults.dictionary(forKey: Keys.whatsNew), let version = saved["version"] as? String,
              let shown = saved["shown"] as? Date else { return nil }
        return WhatsNew(version: version, notes: saved["notes"] as? String ?? "", page: (saved["page"] as? String).flatMap(URL.init(string:)),
                        shown: shown, dismissed: saved["dismissed"] as? Bool ?? false)
    }

    private func save(_ record: WhatsNew) {
        var saved: [String: Any] = ["version": record.version, "notes": record.notes, "shown": record.shown, "dismissed": record.dismissed]
        if let page = record.page { saved["page"] = page.absoluteString }
        defaults.set(saved, forKey: Keys.whatsNew)
    }

    /// The "What's new" notes to show now, or nil: already opened, older than three days, for another version, or no notes.
    func activeWhatsNew(now: Date = Date()) -> WhatsNew? {
        if var preview = previewWhatsNew { preview.notes = notesText(for: preview); return QuietNotes.hasBullets(preview.notes) ? preview : nil }
        guard var record = storedWhatsNew() else { return nil }
        guard record.version == configuration.currentVersion else { return nil }
        guard holdingWhatsNew || (!record.dismissed && now.timeIntervalSince(record.shown) < Self.whatsNewLifetime) else { return nil }
        record.notes = notesText(for: record)
        return QuietNotes.hasBullets(record.notes) ? record : nil
    }

    /// The release's own notes, else those cached for that version, else the host's fallback. No made-up text: no notes, no pill.
    private func notesText(for record: WhatsNew) -> String {
        let own = record.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        if let cached = notesCache.load(version: record.version) { return cached }
        return configuration.fallbackNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func notesPopoverContent() -> NotesPopoverContent? {
        guard let record = activeWhatsNew() else { return nil }
        let page = record.page ?? URL(string: "https://github.com/\(configuration.repository)/releases")
        return NotesPopoverContent(version: record.version, bullets: QuietNotes.bullets(from: record.notes), pageURL: page)
    }

    private func whatsNewOpened() {
        holdingWhatsNew = true
        guard previewWhatsNew == nil, var record = storedWhatsNew() else { return }
        record.dismissed = true
        save(record)
    }

    private func whatsNewClosed() {
        holdingWhatsNew = false
        previewWhatsNew = nil
        refreshPill()
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
        state = .idle
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

    // MARK: - Pill

    private func refreshPill() { pill.set(pillContent()) }

    /// One pill at a time: an update in progress beats a failure someone asked about, which beats a flash, which beats "What's new".
    func pillContent() -> PillContent? {
        switch state {
        case let .updating(version):
            return PillContent(indicator: .spinner, text: "Updating", hoverText: "Installing v\(version)", clickable: false)
        case .ready:
            return PillContent(indicator: .dot, text: "Restart to update", hoverText: nil, clickable: true)
        case .available:
            return PillContent(indicator: .dot, text: "Update available", hoverText: nil, clickable: true)
        case .failed where failureVisible:
            return PillContent(indicator: .warning, text: "Update failed. Retry", hoverText: nil, clickable: true)
        case .failed, .idle:
            break
        }
        if let flash { return flash }
        if activeWhatsNew() != nil { return PillContent(indicator: .dot, text: "What's new", hoverText: nil, clickable: false, opensNotes: true) }
        return nil
    }

    private func flashPill(_ text: String) {
        flashTask?.cancel()
        flash = PillContent(indicator: .check, text: text, hoverText: nil, clickable: false)
        refreshPill()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            self.flash = nil
            self.refreshPill()
        }
    }

    enum Keys {
        static let lastCheck = "AppUpdater.lastCheck"
        static let lastCheckChannel = "AppUpdater.lastCheckChannel"
        static let status = "AppUpdater.status"
        static let lastStableFeedAudit = "AppUpdater.lastStableFeedAudit"
        static let skipped = "AppUpdater.skippedVersion"
        static let justUpdated = "AppUpdater.justUpdated"
        static let failed = "AppUpdater.failedUpdate"
        static let lastSeen = "AppUpdater.lastSeenVersion"
        static let whatsNew = "AppUpdater.whatsNew"
    }

    // MARK: - Install

    /// True from the moment a download or install starts until it is staged, the app quits, or it fails. Hosts can
    /// consult this in `applicationShouldTerminate`. A finished download waiting for "Restart to update" is not installing.
    public private(set) var isInstalling = false

    /// True only after the verified swap and helper handoff. Hosts may allow the updater's quit at
    /// this point while continuing to block ordinary quit during preparation. Keep save/busy guards.
    public var isAwaitingRelaunch: Bool { pendingRelaunch?.helper != nil }

    /// A downloaded, verified update that is waiting for the person to restart.
    struct Prepared {
        let staged: URL
        let workDirectory: URL
        let lease: UpdateInstaller.InstallationLock
        let release: ReleaseInfo
    }
    private var held: Prepared?
    private var applyTask: Task<Void, Never>?

    func discardHeld() {
        guard let held else { return }
        self.held = nil
        Self.cleanUp(held)
    }

    private static func cleanUp(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.staged)
        try? FileManager.default.removeItem(at: prepared.workDirectory)
        withExtendedLifetime(prepared.lease) {}
    }

    /// Downloads, verifies and stages `release` without touching the installed app. Progress is 0…1.
    /// Cancelling the task cancels the download.
    func stage(_ release: ReleaseInfo, progress: @escaping @MainActor (Double) -> Void) async throws -> Prepared {
        guard !isInstalling else { throw CancellationError() }
        decision = .installing
        emit(.accepted, release)
        do {
            let prepared = try await performStage(release, progress: progress)
            isInstalling = false
            return prepared
        } catch is CancellationError {
            decision = .none
            throw CancellationError()
        } catch {
            decision = .none
            emit(.failed, release, error: error.localizedDescription)
            throw error
        }
    }

    /// Stage, then swap in the new app and ask this one to quit, in one go. A detached helper opens the new app
    /// once this process has exited and removes the backup; if the new app won't open, it restores the old one.
    /// `status` names later steps. Cancelling the task cancels the download.
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
            let prepared = try await performStage(release, progress: progress)
            try await performApply(prepared, status: status, quitPending: quitPending)
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

    /// Swaps a staged update in and asks the app to quit.
    func apply(
        _ prepared: Prepared,
        status: @escaping @MainActor (String) -> Void,
        quitPending: @escaping @MainActor () -> Void = {}
    ) async throws {
        decision = .installing
        do {
            try await performApply(prepared, status: status, quitPending: quitPending)
        } catch {
            decision = .none
            if !(error is CancellationError) { emit(.failed, prepared.release, error: error.localizedDescription) }
            throw error
        }
    }

    private func performStage(_ release: ReleaseInfo, progress: @escaping @MainActor (Double) -> Void) async throws -> Prepared {
        if let reason = configuration.busyReason() { throw UpdateInstaller.Failure(message: reason, isDeferral: true) }
        isInstalling = true
        var succeeded = false
        defer { if !succeeded { isInstalling = false } }
        let configuration = configuration
        let prepared = try await UpdateInstaller.prepare(release: release, destination: configuration.appURL, configuration: configuration) { fraction in
            Task { @MainActor in progress(fraction) }
        }
        let result = Prepared(staged: prepared.staged, workDirectory: prepared.workDirectory, lease: prepared.lease, release: release)
        // The download can take minutes; the app may have started something since.
        do {
            try Task.checkCancellation()
            if let reason = configuration.busyReason() { throw UpdateInstaller.Failure(message: reason, isDeferral: true) }
        } catch {
            Self.cleanUp(result)
            throw error
        }
        succeeded = true
        return result
    }

    private func swapForStartup(_ prepared: Prepared) throws -> (URL, UpdateStartup) {
        let destination = configuration.appURL
        let startup = try UpdateStartup.begin(for: destination, version: prepared.release.version)
        do {
            return (try UpdateInstaller.swap(destination: destination, with: prepared.staged), startup)
        } catch {
            let backup = UpdateInstaller.backupURL(for: destination)
            if !FileManager.default.fileExists(atPath: backup.path) {
                UpdateStartup.clear(for: destination)
            }
            throw error
        }
    }

    private func performApply(
        _ prepared: Prepared,
        status: @escaping @MainActor (String) -> Void,
        quitPending: @escaping @MainActor () -> Void
    ) async throws {
        let release = prepared.release
        let destination = configuration.appURL
        let configuration = configuration
        isInstalling = true
        var finishedHandOff = false
        defer {
            if !finishedHandOff { isInstalling = false }
            Self.cleanUp(prepared)
        }
        // The app may have started something since the download.
        try Task.checkCancellation()
        if let reason = configuration.busyReason() {
            throw UpdateInstaller.Failure(message: reason, isDeferral: true)
        }
        try Task.checkCancellation()
        status("Installing…")
        let (backup, startup) = try swapForStartup(prepared)
        rememberInstall(of: release)
        do {
            let helper = try UpdateInstaller.scheduleRelaunch(destination: destination, backup: backup,
                                                             lease: prepared.lease, startup: startup)
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

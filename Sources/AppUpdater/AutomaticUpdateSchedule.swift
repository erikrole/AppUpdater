import AppKit
import Network

/// A single check stream for the lifetime of the host app. Notifications wake the stream;
/// only the updater decides whether enough time has elapsed to make a request.
@MainActor
final class AutomaticUpdateSchedule {
    private let check: @MainActor () async -> AppUpdater.CheckOutcome?
    private let network = NWPathMonitor()
    private var timer: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    private var wake: NSObjectProtocol?
    private var lastOnline: Bool?
    private var retryAt = Date.distantPast
    private var rateLimitUntil = Date.distantPast
    private var consecutiveFailures = 0
    private var consecutiveDownloadDeferrals = 0

    init(check: @escaping @MainActor () async -> AppUpdater.CheckOutcome?) {
        self.check = check
    }

    func start() {
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        network.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        network.start(queue: .global(qos: .utility))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        inFlight?.cancel()
        network.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
    }

    func retryAfterDownloadDeferral() {
        consecutiveDownloadDeferrals = min(consecutiveDownloadDeferrals + 1, 7)
        retryAt = max(retryAt, .now.addingTimeInterval(Self.delay(attempt: consecutiveDownloadDeferrals)))
    }

    func downloadFinished() {
        consecutiveDownloadDeferrals = 0
    }

    func retryAfterRateLimit(_ reset: Date?) {
        rateLimitUntil = reset ?? .now.addingTimeInterval(300)
    }

    private func networkChanged(online: Bool) {
        let reconnected = lastOnline == false && online
        lastOnline = online
        if reconnected {
            retryAt = .distantPast
            tick()
        }
    }

    private func tick() {
        guard timer != nil, inFlight == nil, lastOnline != false,
              Date.now >= retryAt, Date.now >= rateLimitUntil else { return }
        inFlight = Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = nil }
            switch await self.check() {
            case .failed:
                self.consecutiveFailures = min(self.consecutiveFailures + 1, 7)
                self.retryAt = max(self.retryAt, .now.addingTimeInterval(Self.delay(attempt: self.consecutiveFailures)))
            case .available, .upToDate, .skipped:
                self.consecutiveFailures = 0
            case .tooSoon, nil:
                break
            }
        }
    }

    private static func delay(attempt: Int) -> TimeInterval {
        min(1800, 30 * pow(2, Double(attempt - 1))) + Double.random(in: 0...10)
    }
}

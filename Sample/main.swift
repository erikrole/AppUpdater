import AppKit
import AppUpdater

// `swift run UpdaterPreview` opens a sample host window with the update pill (default: "What's new").
//   --state updating|ready|available|failed|whatsnew|whatsnew-open|uptodate   which pill to show
//   --dark                                                                   dark appearance
//   --menubar                                                                anchor to a menu bar item instead of the window
//   --render out.png                                                         save a composed screenshot of this app's windows (never the screen), then quit
// `UpdaterPreview --e2e /path/to/Scratch.app` runs a real update of that copy of Offload.app from GitHub.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let arguments = CommandLine.arguments
    var updater: AppUpdater!
    var window: NSWindow!
    var statusItem: NSStatusItem?

    func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Offload"
        let label = NSTextField(labelWithString: "Your app's content")
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: content.centerXAnchor), label.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        window.contentView = content
        if arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        if let path = value(after: "--e2e") {
            updater = AppUpdater(
                .init(
                    repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "com.erole.Offload",
                    appURL: URL(filePath: path), displayName: "Offload", currentVersion: "1.0.0"
                ),
                defaults: UserDefaults(suiteName: "AppUpdaterE2E")!
            )
            updater.hostView = window.contentView
            updater.onStateChange = { [updater] state in
                print("state:", state)
                if case .ready = state { updater?.restartToUpdate() }
            }
            updater.checkNow()
            return
        }
        updater = AppUpdater(.init(
            repository: "erikrole/offload-releases", assetName: "Offload.dmg",
            bundleIdentifier: "com.erole.Offload", displayName: "Offload", currentVersion: "1.5.2"
        ))
        if arguments.contains("--menubar") {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "Offload"
            statusItem = item
            updater.hostView = item.button
        } else {
            updater.hostView = window.contentView   // the one line a host adds
        }
        let notes = """
        ## One folder per camera
        - **A folder named for your camera.** SLOW2, ROAM1 and the rest get their own folder from the first card.
        - Checksums now run while the next card copies.
        - The card list remembers the last camera you chose.
        - Fixed a crash when a card was ejected mid-copy.
        """
        let release = ReleaseInfo(
            version: "1.5.3", notes: notes,
            downloadURL: URL(string: "https://github.com/erikrole/offload-releases/releases/latest/download/Offload.dmg")!,
            pageURL: URL(string: "https://github.com/erikrole/offload-releases/releases"), date: Date()
        )
        let state = value(after: "--state") ?? "whatsnew"
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            switch state {
            case "updating": updater.showPreview(state: .updating(version: "1.5.3"))
            case "ready": updater.showPreview(state: .ready(version: "1.5.3"))
            case "available": updater.showPreview(state: .available(version: "1.5.3"))
            case "failed": updater.showPreview(state: .failed(message: "Couldn't download the update."))
            case "whatsnew-open":
                updater.showPreview(release)
                try? await Task.sleep(for: .milliseconds(300))
                updater.openWhatsNew()
            default: updater.showPreview(release)
            }
            guard let out = value(after: "--render") else { return }
            try? await Task.sleep(for: .milliseconds(900))
            // Raise this app's windows above everything and capture only the screen area they cover (the host window, pill and
            // popover), on a plain backdrop window so nothing else on the desktop can appear in the image.
            let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 20 }
            let union = windows.map(\.frame).reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -24)
            let backdrop = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.backgroundColor = window.appearance?.name == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)
            backdrop.level = .floating
            backdrop.hasShadow = false
            backdrop.setFrame(union, display: true)
            backdrop.orderFrontRegardless()
            window.level = .floating
            window.orderFrontRegardless()
            for w in NSApp.windows where w !== backdrop && w !== window && w.isVisible { w.orderFrontRegardless() }
            try? await Task.sleep(for: .milliseconds(600))
            let primary = NSScreen.screens.first?.frame.height ?? 0
            let capture = Process()
            capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-R", "\(Int(union.minX)),\(Int(primary - union.maxY)),\(Int(union.width)),\(Int(union.height))", out]
            try? capture.run()
            capture.waitUntilExit()
            exit(0)
        }
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()

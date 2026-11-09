import AppKit
import AppUpdater

// `swift run UpdaterPreview` opens a sample host window with the title bar update button (default: "What's new").
//   --state updating|ready|available|failed|whatsnew|whatsnew-open|uptodate   which state to show
//   --dark                                                                   dark appearance
//   --menubar                                                                no window button: show the state as the first row of a menu bar item's menu
//   --render out.png                                                         save an image drawn from this app's own views (never the screen), then quit
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
            let menu = NSMenu()
            menu.addItem(updater.menuItem)   // first row; hidden when there is nothing to do
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            window.orderOut(nil)
        }   // window apps add nothing: the button appears in the title bar by itself
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
            // Draw this app's own views into a bitmap (the window's frame view, so the title bar and its button are included,
            // plus the open popover under it). Nothing is read from the screen, so no other window can appear in the image.
            guard let frame = window.contentView?.superview else { exit(1) }
            let dark = window.appearance?.name == .darkAqua
            let scale = window.backingScaleFactor
            @MainActor func bitmap(_ view: NSView) -> NSBitmapImageRep? {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
                view.cacheDisplay(in: view.bounds, to: rep)
                return rep
            }
            guard let host = bitmap(frame) else { exit(1) }
            let margin: CGFloat = 24
            let hostSize = frame.bounds.size
            var popRep: NSBitmapImageRep?
            var popSize = NSSize.zero
            if let pop = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil && $0.frame.width < 400 })?.contentView,
               let rep = bitmap(pop) {
                popRep = rep
                popSize = pop.bounds.size
            }
            let canvas = NSSize(width: hostSize.width + margin * 2,
                                height: hostSize.height + margin * 2 + (popRep == nil ? 0 : popSize.height + 8))
            guard let out_rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: out_rep) else { exit(1) }
            out_rep.size = canvas
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSRect(origin: .zero, size: canvas).fill()
            let top = canvas.height - margin
            host.draw(in: NSRect(x: margin, y: top - hostSize.height, width: hostSize.width, height: hostSize.height))
            if let popRep {
                popRep.draw(in: NSRect(x: margin + hostSize.width - popSize.width - 8, y: top - hostSize.height - 8 - popSize.height,
                                       width: popSize.width, height: popSize.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = out_rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(filePath: out)) }
            exit(0)
        }
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()

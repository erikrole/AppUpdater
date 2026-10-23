import AppKit
import AppUpdater

// `swift run UpdaterPreview` shows the update window with sample notes (add --red for a custom accent).
// `UpdaterPreview --e2e /path/to/Scratch.app` runs a real update of that copy of Offload.app from GitHub.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let arguments = CommandLine.arguments
    var updater: AppUpdater!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = arguments.firstIndex(of: "--e2e"), index + 1 < arguments.count {
            updater = AppUpdater(
                .init(
                    repository: "erikrole/offload-releases", assetName: "Offload.dmg", bundleIdentifier: "com.erole.Offload",
                    appURL: URL(filePath: arguments[index + 1]), displayName: "Offload", currentVersion: "1.0.0"
                ),
                defaults: UserDefaults(suiteName: "AppUpdaterE2E")!
            )
            updater.checkNow()
            // Press the splash's real primary button once it is up, so the whole flow runs unattended.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                @MainActor func button(in view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == "Update and Relaunch" { return button }
                    for sub in view.subviews { if let found = button(in: sub) { return found } }
                    return nil
                }
                for window in NSApp.windows { if let b = window.contentView.flatMap(button(in:)) { b.performClick(nil); print("clicked") } }
            }
            return
        }
        updater = AppUpdater(.init(
            repository: "erikrole/offload-releases", assetName: "Offload.dmg",
            bundleIdentifier: "com.erole.Offload", displayName: "Offload", currentVersion: "1.5.2",
            style: .init(accentColor: arguments.contains("--red") ? NSColor(red: 0.82, green: 0.1, blue: 0.1, alpha: 1) : nil)
        ))
        let long = "A very long bullet that must wrap onto several lines instead of running off the right edge of the card, including `inline code` and **bold text** to make sure styled runs wrap too."
        let notesFile = ProcessInfo.processInfo.environment["UPDATER_NOTES_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        updater.showPreview(ReleaseInfo(
            version: "1.5.3",
            notes: notesFile ?? """
            ## One folder per camera, named for the camera
            - **A folder named for your camera.** SLOW2, ROAM1 and the rest get their own folder from the first card.
            - \(long)
              - Nested: \(long)
            1. Numbered: \(long)
              - Checksums run while the next card copies.
            ## To try it
            1. Offload a card.
            2. Open the folder.
            ```
            Offload --verify
            ```
            """,
            downloadURL: URL(string: "https://github.com/erikrole/offload-releases/releases/latest/download/Offload.dmg")!,
            pageURL: URL(string: "https://github.com/erikrole/offload-releases/releases"),
            date: Date()
        ))
        // `--render out.png`: draw the window offscreen (light and dark) instead of capturing the screen, then quit.
        if let index = arguments.firstIndex(of: "--render"), index + 1 < arguments.count {
            let base = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }), let view = window.contentView else { exit(1) }
                // cacheDisplay can't clip a scroll view's content, so capture just this window's own pixels instead.
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try? await Task.sleep(for: .milliseconds(400))
                    let capture = Process()
                    capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), base.replacingOccurrences(of: ".png", with: "-\(name).png")]
                    try? capture.run()
                    capture.waitUntilExit()
                }
                exit(0)
            }
        }
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()

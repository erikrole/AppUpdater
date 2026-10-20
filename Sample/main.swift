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
                func button(in view: NSView) -> NSButton? {
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
        updater.showPreview(ReleaseInfo(
            version: "1.5.3",
            notes: """
            ## One folder per camera, named for the camera
            - **A folder named for your camera.** SLOW2, ROAM1 and the rest get their own folder from the first card.
            - **Games never merge.** A card from another game gets a dated folder, like `ROAM1_2026-10-24`.
            - Faster verification on large cards.
            """,
            downloadURL: URL(string: "https://github.com/erikrole/offload-releases/releases/latest/download/Offload.dmg")!,
            pageURL: URL(string: "https://github.com/erikrole/offload-releases/releases"),
            date: Date()
        ))
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()

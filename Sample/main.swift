import AppKit
import AppUpdater

// Shows the update window with sample release notes: `swift run UpdaterPreview`.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater(.init(
        repository: "erikrole/offload-releases", assetName: "Offload.dmg",
        bundleIdentifier: "com.erole.Offload", displayName: "Offload", currentVersion: "1.5.2"
    ))

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.showPreview(ReleaseInfo(
            version: "1.5.3",
            notes: """
            ## One folder per camera, named for the camera
            - **A folder named for your camera.** SLOW2, ROAM1 and the rest get their own folder from the first card.
            - **Games never merge.** A card from another game gets a dated folder, like `ROAM1_2026-10-24`.
            - Faster verification on large cards.
            """,
            downloadURL: URL(string: "https://github.com/erikrole/offload-releases/releases/latest/download/Offload.dmg")!,
            date: Date()
        ))
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()

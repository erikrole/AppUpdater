# AppUpdater

A small, dependency-free AppKit updater for Erik's own macOS apps (Swift 6, macOS 27). Apps check a public GitHub
releases repository on launch and, when there's an update, show a splash with the release notes and a one-click
**Update and Relaunch**. No Sparkle, no appcast, no helper tool.

## Integrate (5 lines)

1. Add the package: `.package(url: "https://github.com/erikrole/AppUpdater", branch: "main")`, product `AppUpdater`.
2. Keep the app's version in `CFBundleShortVersionString` and publish each release to `<name>-releases` with a tag
   like `v1.5.3`, a stable `<Name>.dmg` asset (optionally also `<Name>-1.5.3.dmg`) and the notes as the release body.
3. In your app delegate:

```swift
import AppUpdater

let updater = AppUpdater(.init(repository: "erikrole/offload-releases", assetName: "Offload.dmg"))
// applicationDidFinishLaunching:
updater.checkOnLaunch()
// "Check for Updates…" menu item:
updater.checkNow()
```

Optional configuration: `busyReason: { model.isCopying ? "Offload is busy with a copy." : nil }` holds the update
back (the window shows the reason), `minimumCheckInterval` (default 6 hours), `teamID`, `displayName`, `bundleIdentifier`.

Preview the window: `swift run UpdaterPreview`.

## What it does

- **Launch check:** at most once per 6 hours, silent when current, offline, or the version was skipped.
  The menu item always checks and says "up to date" or "couldn't check".
- **Splash:** app icon, version change, release date, release notes rendered from the GitHub release body
  (headings, bullets, bold, code, links). Buttons: Update and Relaunch, Later, Skip This Version.
- **Install:** download with progress, mount read-only, copy the app next to the installed one, verify
  (`codesign --verify --deep --strict`, Team ID `T26T3G8C7Q`, bundle ID, `spctl --assess`), swap with a hidden backup,
  relaunch as a new instance, delete the backup. If the new app won't open, the previous version is restored.
  Nothing is installed unless every check passes.
- **After updating:** the new version opens once with the same window in "what changed" mode.
- Refuses to update a copy running from a disk image or a translocated path; asks to move it to Applications.

## Release notes tips

The release body is the splash content. Start with a `## headline`, then bullets: `- **What changed.** Why it matters.`

## Tests

`swift test` (offline). `APPUPDATER_LIVE=1 swift test` also downloads the real Offload release and runs the full
verify path against it.

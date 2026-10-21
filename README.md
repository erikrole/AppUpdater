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

Optional configuration (all have defaults):
- `style: .init(accentColor:, kickerColor:, icon:, title:, primaryButtonTitle:)` dresses the window in the host's colours
  (default: system accent). The primary button is a filled accent pill; Later and Skip are quiet text buttons.
- `busyReason: { model.isCopying ? "Offload is busy with a copy." : nil }` holds the update back and shows the reason.
  It is checked before the download and again right before the swap.
- `fallbackNotes: "…"` is shown when a release has no notes and none were cached from an earlier fetch. Notes are cached
  per version in `~/Library/Caches/AppUpdater/<bundle id>/`, so the window is never empty.
- `minimumCheckInterval` (default 6 hours), `teamID` (default `T26T3G8C7Q`), `displayName`, `bundleIdentifier`, `appURL`.
- `updater.isInstalling` lets `applicationShouldTerminate` avoid quitting mid-install. Keep the `AppUpdater` instance
  alive for the life of the app (a property on your app delegate).

Preview the window: `swift run UpdaterPreview`.

## What it does

- **Launch check:** at most once per 6 hours, silent when current, offline, or the version was skipped.
  The menu item always checks and says "up to date" or "couldn't check".
- **Splash:** app icon, version change, release date, release notes rendered from the GitHub release body
  (headings, bullets, nested bullets, numbered lists, bold, code and code blocks, links) in a scrolling card with a
  "View on GitHub" link. Buttons: Update and Relaunch, Later (Cancel while downloading), Skip This Version.
- **Install:** download with progress, mount read-only, copy the app next to the installed one, verify
  (`codesign --verify --deep --strict`, Team ID `T26T3G8C7Q`, bundle ID, `spctl --assess`), swap with a hidden backup,
  then quit. A detached helper waits for the old process to exit, opens the new app as a new instance and deletes the
  backup; if the new app won't open it puts the old one back. If the app asks to finish something first (a save sheet),
  the update waits for it. Leftover staging copies and backups are swept at the next launch. The signature check also
  requires an Apple-anchored certificate for the Team ID and that the bundle version matches the release tag.
  Nothing is installed unless every check passes.
- **After updating:** the new version opens once with the same window in "what changed" mode.
- Refuses to update a copy running from a disk image or a translocated path; asks to move it to Applications.

## Telemetry hook

`onEvent` is called on the main actor, one event per step, on a later turn of the main loop (never inline, so a slow hook
can't hold up the update). It can't change the flow. Every event carries `fromVersion` (running) and `toVersion` (offered).

| `kind` | when |
|---|---|
| `shown` | the splash opened (`trigger`: `.launch` or `.manual`) |
| `accepted` | Update and Relaunch was clicked (again on a retry) |
| `skipped` | Skip This Version |
| `deferred` | Later, Cancel during the download, or the window was closed |
| `installed` | the **new** version, on its first launch after a successful update (same moment as the what's-new window) |
| `failed` | the install failed; `error` says why |

```swift
let updater = AppUpdater(.init(
    repository: "erikrole/offload-releases", assetName: "Offload.dmg",
    onEvent: { event in
        Analytics.record("update.\(event.kind.rawValue)", [
            "from": event.fromVersion, "to": event.toVersion,
            "trigger": event.trigger?.rawValue ?? "", "error": event.error ?? "",
        ])
    }
))
```

## Release notes tips

The release body is the splash content. Start with a `## headline`, then bullets: `- **What changed.** Why it matters.`

## Release notes tooling

The scripts live in this repo's `scripts/`; call them by path from a checkout of AppUpdater (or copy them into the app's repo).

The splash shows the GitHub release body, so release scripts should generate it and refuse to publish an empty one.

```sh
scripts/release-notes.sh > notes.md          # commits since the last tag → "## headline" + "- **Subject.** body" bullets
scripts/release-notes.sh --since v1.5.2 --headline "Fetch now updates itself" > notes.md
scripts/check-notes.sh notes.md              # exit 1 if empty, heading-only, too short or a TODO/TBD placeholder
scripts/check-notes.sh --release erikrole/fetch-releases v1.5.3   # same check on a published release (needs gh)
gh release create v1.5.3 Fetch.dmg --notes-file notes.md
```

Edit the generated file before publishing: commit subjects are a starting point, not the final wording.
`scripts/test-release-notes.sh` tests both scripts in a scratch git repo.

## Tests

`swift test` (offline) and `scripts/test-release-notes.sh`. `APPUPDATER_LIVE=1 swift test` also downloads the real Offload release and runs the full
verify path against it.

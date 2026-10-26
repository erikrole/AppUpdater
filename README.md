# AppUpdater

A small, dependency-free AppKit updater for Erik's own macOS apps (Swift 6, macOS 26 or later). Apps check a public GitHub
releases repository on launch and, when there's an update, show a splash with the release notes and a one-click
**Update and Relaunch**. No Sparkle, no appcast, no helper tool.

## Integrate (5 lines)

1. Add the package: `.package(url: "https://github.com/erikrole/AppUpdater", revision: "<reviewed-commit>")`, product `AppUpdater`.
2. Keep the app's version in `CFBundleShortVersionString` and publish each release to `<name>-releases` with a tag
   like `v1.5.3`, a `<Name>.dmg` or `<Name>.zip` asset (also accepts `<Name>-1.5.3-arm64.zip`, universal, and versioned names) and the notes as the release body.
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
- Block ordinary quit while `updater.isInstalling && !updater.isAwaitingRelaunch`. Once `isAwaitingRelaunch` is true,
  permit the updater quit through the host’s normal save and busy guards. Keep one updater alive for its lifetime.
  Leave `safeToExit` unset when the host must save, restore system state, or finish queued work.
- Automatic checks belong only in normal release launches. Skip tests, CLI helpers, snapshots, and command-only launches.

For release builds, pin a reviewed commit or tag in the host's package configuration and commit its `Package.resolved`.
Updating this package's `main` does not update an already installed app: each host must resolve the new revision, pass its
own checks, and ship a new build. See [the October 2026 audit](docs/audit-2026-10-23.md) for the original inventory and [host adoption verification](docs/adoption-2026-10-23.md) for the completed integrations.

Preview the window: `swift run UpdaterPreview`.

## What it does

- **Launch check:** at most once per 6 hours, silent when current, offline, or the version was skipped.
  The menu item always checks and says "up to date" or "couldn't check".
- **Splash:** app icon, version change, release date, release notes rendered from the GitHub release body
  (headings, bullets, nested bullets, numbered lists, bold, code and code blocks, links) in a scrolling card with a
  "View on GitHub" link. Buttons: Update and Relaunch, Later (Cancel while downloading), Skip This Version.
- **Install:** download with progress, mount a DMG read-only or safely extract a ZIP, copy the app next to the installed one, verify
  (`codesign --verify --deep --strict`, Team ID `T26T3G8C7Q`, bundle ID, `spctl --assess`), swap with a hidden backup,
  then quit. A detached helper waits for the old process to exit, opens the new app as a new instance and deletes the
  backup; if the new app won't open it puts the old one back. If the app asks to finish something first (a save sheet),
  the update waits for it. Leftover staging copies and backups are swept at the next launch. The signature check also
  requires an Apple-anchored certificate for the Team ID and that the bundle version matches the release tag.
  Nothing is installed unless every check passes.
- **ZIP archives:** use macOS’s libarchive-backed extractor with its default path safeguards. Require a bounded,
  single-disk non-encrypted ZIP (no ZIP64), at most 60,000 entries and 2 GiB expanded. Reject links outside the selected
  app, hard links, special objects, and ambiguous app payloads. Internal framework symlinks are preserved. ZIP and DMG
  apps pass the same signature, identity, version, and Gatekeeper checks before installation.
- **Recovery and cancellation:** a per-app file lock excludes other updater instances from preparation, cleanup, and
  rollback. The relaunch helper inherits the lock until it finishes; the small hidden `.AppName.app.updater-lock` file stays
  beside the app and must not be deleted. Cleanup restores a surviving backup if a swap was interrupted between renames.
  Rollback preserves the installed app when the backup is missing and reports restoration failures. Cancel closes the
  splash after the active preparation tool finishes and its temporary files and mount are cleaned up; it never proceeds
  to the swap. Downloads allow 60 seconds of inactivity and 15 minutes overall, and require HTTPS from the first request.
- **After updating:** by default the new version opens once with the same window in "what changed" mode. Set `postUpdate: .quiet` in the configuration for no window at all; the `.installed` event still fires, so the host can show its own note.
- Refuses to update a copy running from a disk image or a translocated path; asks to move it to Applications.
  A destination that is itself a symbolic link is also refused; open the original app to update it.

## Channels (production and beta)

`Configuration.channel` is a closure read at every check (default `{ .production }`, so existing apps are unchanged).
Production uses `releases/latest` and ignores drafts, GitHub prereleases and any `-beta.N` version. Beta lists
`releases?per_page=20`, skips drafts, accepts prereleases and offers the highest version that has the asset. An update is
offered only when it is newer than the installed version, so turning beta off never downgrades: a beta Mac stays where it is
until a newer production release. Versions are `X.Y.Z` or `X.Y.Z-beta.N`; `3.0.0-beta.1 < 3.0.0-beta.2 < 3.0.0`. Publish a beta
as a GitHub prerelease with `--latest=false` so `releases/latest/download/<asset>` keeps serving production. Hosts decide how a
person opts in (Offload: `updates.beta` in UserDefaults, a Settings switch).

## Quitting for the update

After the swap, AppUpdater asks the app to quit with `AppUpdater.requestQuit()`. It calls `terminate:` from a run-loop timer,
not from inside the install task. This matters if your `applicationShouldTerminate` returns `.terminateLater` and replies from
a Swift task (to save first): called from inside a main-actor task, `terminate:` blocks that task's job, so your reply task can
never run and the update hangs on "Relaunching…". If you start a quit yourself from a task, use `requestQuit()` too.
If the app is still open 5 seconds later the splash says to finish up and offers **Don't Wait**: it ends the relaunch helper,
puts the previous version back (`cancelPendingQuit()`) and lets the update be started again.
If restoration fails, the splash shows the error and preserves the backup for another attempt.

**Stalled quit:** if the app is still open 5 s after the quit request, no alert or sheet is up, and `Configuration.safeToExit` returns true (flush anything unsaved first), AppUpdater exits the process so the relaunch helper can open the new version. Without `safeToExit` it never forces an exit.
Cancellation, pending update ownership, and sheets on every app window are checked again after the asynchronous save finishes.

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

`RequestQuitTests` run a real AppKit host (`QuitProbe`, a `.terminateLater` delegate that replies from a task): `requestQuit()`
exits, and `NSApp.terminate` called inside a task still hangs (the negative control).

`swift test` (offline) and `scripts/test-release-notes.sh`. `APPUPDATER_LIVE=1 swift test` also downloads the real Offload DMG and the six active adopted hosts’ ZIPs (StatBar, Tweaks, UpdateBar, SnipBar, Cutdown, and TVBar), then runs the full
verification path without installing or launching them. Optional `APPUPDATER_GITHUB_TOKEN` read-only authentication
avoids shared unauthenticated API limits; never save a token in the repository.

`swift build -Xswiftc -warnings-as-errors` checks every package product. Tests include the helper's inherited lock,
concurrent cleanup exclusion, interrupted-swap recovery, missing-backup rollback, cancellation during preparation and
quit fallback, strict numeric versions, and web-only release-note links. The real signed-app test uses a scratch copy of
`/Applications/Offload.app` when present; it never changes the installed copy. AppKit, code-signing services, and normal
user cache access are required for the full suite.

All eight host releases were [published and verified on October 23, 2026](docs/releases-2026-10-23.md).
AgentBar and PowerBar were subsequently [retired](docs/retirement-2026-10-23.md); six of those ZIP hosts remain active. The minimum was lowered to macOS 26 (Tahoe) on October 24, 2026; no 27-only APIs are used.

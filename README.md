# AppUpdater

A small, dependency-free AppKit updater for Erik's own macOS apps (Swift 6, macOS 26 or later). Apps check a public GitHub
releases repository on launch and while running and, when there's an update, download it quietly. There is **no splash and no modal**: a small
pill at the top-right of the app's window shows the progress. A detached helper handles relaunch and rollback.

| Pill | Meaning |
|---|---|
| spinner **Updating** (hover: *Installing v1.5.3*) | downloading and verifying; fades into the next pill |
| dot **Restart to update** | the update is verified and waiting; a click installs and relaunches. It never nags |
| dot **What's new** | first launch after an update: hover or click opens a popover with 2 to 5 bullets from the release body and a *Full notes* link. Gone once opened or after 3 days; not shown when the release has no notes |
| **Update failed. Retry** | shown after a manual check or a retry; at launch a failure is silent and retried at the next launch |

Screenshots: [updating](docs/quiet-updates/updating.png), [restart](docs/quiet-updates/ready.png),
[what's new](docs/quiet-updates/whatsnew-open.png) ([dark](docs/quiet-updates/whatsnew-open-dark.png)), [failed](docs/quiet-updates/failed.png).

## Integrate (5 lines)

1. Add the package: `.package(url: "https://github.com/erikrole/AppUpdater", revision: "<reviewed-commit>")`, product `AppUpdater`.
2. Keep the app's version in `CFBundleShortVersionString` and publish each release to `<name>-releases` with a tag
   like `v1.5.3`, a `<Name>.dmg` or `<Name>.zip` asset (also accepts `<Name>-1.5.3-arm64.zip`, universal, and versioned names) and the notes as the release body.
3. In your app delegate:

```swift
import AppUpdater

let updater = AppUpdater(.init(repository: "erikrole/offload-releases", assetName: "Offload.dmg"))
// applicationDidFinishLaunching:
updater.hostView = window.contentView   // the pill hangs top-right of this view; a menu bar app passes statusItem.button
updater.checkOnLaunch()
// "Check for Updates…" menu item:
updater.checkNow()
```

Optional configuration (all have defaults):
- `updater.hostView` (or `hostWindow`) anchors the pill. Unset, it uses the main window. For a menu bar app pass
  `statusItem.button` and the pill sits under the item. A menu can mirror the pill: `updater.menuTitle` ("Restart to update",
  "Update failed. Retry", "Update available", else nil), `performPrimaryAction()`, `retry()`, `restartToUpdate()`, and
  `state` / `onStateChange` (`.idle`, `.updating`, `.ready`, `.available`, `.failed`).
- `style: .init(accentColor:)` tints the pill's dot (default: system accent). The other `Style` fields no longer do anything.
- `autoInstall: { settings.autoUpdate }` (default `{ true }`) lets a launch check download a stable update on its own; wire it to a Settings switch.
  With it off, or for a beta, the pill reads "Update available" and a click starts the download. A busy host can offer the update when work finishes;
  a version that failed twice stops downloading by itself (retry from the menu or the pill). A manual check always downloads.
- `channel: { settings.beta ? .beta : .production }` picks stable or beta releases.
- `busyReason: { model.isCopying ? "Offload is busy with a copy." : nil }` holds the update back and shows the reason.
  It is checked before the download and again right before the swap.
- `fallbackNotes: "…"` is shown when a release has no notes and none were cached from an earlier fetch. Notes are cached
  per version in `~/Library/Caches/AppUpdater/<bundle id>/`, so the window is never empty.
- `minimumCheckInterval` (default 1 hour), `teamID` (default `T26T3G8C7Q`), `displayName`, `bundleIdentifier`, `appURL`.
- Block ordinary quit while `updater.isInstalling && !updater.isAwaitingRelaunch`. Once `isAwaitingRelaunch` is true,
  permit the updater quit through the host’s normal save and busy guards. Keep one updater alive for its lifetime.
  Leave `safeToExit` unset when the host must save, restore system state, or finish queued work.
- Automatic checks belong only in normal release launches. Skip tests, CLI helpers, snapshots, and command-only launches.

For release builds, pin a reviewed commit or tag in the host's package configuration and commit its `Package.resolved`.
Updating this package's `main` does not update an already installed app: each host must resolve the new revision, pass its
own checks, and ship a new build. See [the October 2026 audit](docs/audit-2026-10-23.md) for the original inventory and [host adoption verification](docs/adoption-2026-10-23.md) for the completed integrations.

Preview the pill: `swift run UpdaterPreview --state updating|ready|available|failed|whatsnew|whatsnew-open` (`--dark`, `--menubar`,
`--render out.png` saves a composed screenshot of the app's own windows).

## What it does

- **Automatic checks:** launch, activation, wake, reconnect and a bounded timer. Successful requests are normally at least
  an hour apart. A discovered update waits for the host to be ready. Transport failures retry with backoff.
- **Quiet flow:** a launch check (or a manual one) downloads and verifies the update in the background (`stage`), and
  nothing on disk changes until the person clicks **Restart to update**, which swaps, hands off to the relaunch helper and
  quits. Quitting normally instead just discards the download; the next launch fetches it again. `isInstalling` is true only
  while downloading or swapping, not while waiting for the click. Last-seen version and the What's new state persist in
  UserDefaults (`AppUpdater.lastSeenVersion`, `AppUpdater.whatsNew`).
- **Install:** download with progress, mount a DMG read-only or safely extract a ZIP, copy the app next to the installed one, verify
  (`codesign --verify --deep --strict`, Team ID `T26T3G8C7Q`, bundle ID, `spctl --assess`), swap with a hidden backup,
  then quit. A detached helper waits for the old process to exit and opens the new app. It keeps the backup until the
  new host confirms startup and restores it if the new app exits before confirmation. A still-running app keeps its backup. If the app asks to finish something first (a save sheet),
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
  Rollback preserves the installed app when the backup is missing and reports restoration failures. Cancel ends the
  download after the active preparation tool finishes and its temporary files and mount are cleaned up; it never proceeds
  to the swap. Downloads allow 60 seconds of inactivity and 15 minutes overall, and require HTTPS from the first request.
- **After updating:** by default the new version shows the "What's new" pill. Set `postUpdate: .quiet` in the configuration for nothing at all; the `.installed` event still fires, so the host can show its own note.
- Refuses to update a copy running from a disk image or a translocated path; asks to move it to Applications.
  A destination that is itself a symbolic link is also refused; open the original app to update it.

## Shared releases repository

New apps publish to the one public `erikrole/releases` repository instead of a `<name>-releases` repo each. Tag every release
`<app>-vX.Y.Z` (for example `scratchpad-v1.5.1`) and set `tagPrefix: "scratchpad-"` with `repository: "erikrole/releases"`. Checks then list
the newest 100 releases and pick this app's highest version that has the asset; production still ignores prereleases and betas. Publish with
`gh release create scratchpad-v1.5.1 Scratchpad.zip --repo erikrole/releases --latest=false` so no single app claims "Latest". An app moves
over on its next release; installed copies follow once that release (still published to the old repo) reaches them.

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
If the app is still open 5 seconds later the pill goes back to **Restart to update** (a click asks to quit again). A host that wants
to give up calls `cancelPendingQuit()`: it ends the relaunch helper, puts the previous version back and lets the update start again.
If restoration fails, the error is logged and the backup is preserved for another attempt.

**Stalled quit:** if the app is still open 5 s after the quit request, no alert or sheet is up, and `Configuration.safeToExit` returns true (flush anything unsaved first), AppUpdater exits the process so the relaunch helper can open the new version. Without `safeToExit` it never forces an exit.
Cancellation, pending update ownership, and sheets on every app window are checked again after the asynchronous save finishes.

## Telemetry hook

`onEvent` is called on the main actor, one event per step, on a later turn of the main loop (never inline, so a slow hook
can't hold up the update). It can't change the flow. Every event carries `fromVersion` (running) and `toVersion` (offered).

| `kind` | when |
|---|---|
| `shown` | the "Update available" pill appeared (`trigger`: `.launch` or `.manual`) |
| `accepted` | a download started (again on a retry) |
| `skipped` | `skip(_:)` was called (the version is then ignored by launch checks) |
| `deferred` | no longer sent (there is no window to dismiss) |
| `installed` | the **new** version, on its first launch after a successful update (same moment as the What's new pill) |
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

The release body feeds the What's new popover (top-level bullets, up to five). Start with a `## headline`, then bullets: `- **What changed.** Why it matters.`

## Release notes tooling

The scripts live in this repo's `scripts/`; call them by path from a checkout of AppUpdater (or copy them into the app's repo).

The What's new pill shows the GitHub release body, so release scripts should generate it and refuse to publish an empty one.

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

## Public update-check fallback

Stable checks use GitHub's API normally. If it returns 403 or 429, the updater resolves the same public repository's latest stable release page and probes a tag-anchored asset with HEAD. Requests stay HTTPS and verified apps still pass the same team, bundle-ID, version, signature and Gatekeeper checks. Failed discovery stays a failure, with the actual reason and a View Releases button. It never guesses that the app is current. Public probes use no account credentials or cookies; cached real notes remain available when the API cannot supply notes.

For a local signed-app fixture, set `APPUPDATER_SIGNED_APP=/Applications/Fetch.app`. Enable `APPUPDATER_FALLBACK_LIVE=1` for the opt-in public-web fallback check.

## Automatic checks and safe quit

`checkOnLaunch()` acknowledges startup and starts checks for the lifetime of a simple host. For a host with asynchronous
restoration, call `markStartupReady()` after essential startup, then `startAutomaticChecks(shouldPresent:)` with its own
presentation gate. The updater can discover an update while work is active and apply the gate before presenting it.
Keep `busyReason` wired to the host's saves and work. Debug, test and command-only entry points should never start the schedule.

Automatic download and restart are distinct choices. A host may expose an off-by-default `installOnQuit` preference and
call `applyOnQuitIfReady()` immediately before returning `.terminateNow` for a normal quit. The next launch acknowledges
the new version. If it cannot start, the verified backup is retained. A companion can offer a user-initiated restore
with `restoreUnconfirmedUpdate(at:bundleIdentifier:)` after the target app has closed.

`AppUpdater.Status.read(bundleIdentifier:)` reads the local snapshot for an owner status view. It includes installed and
offered versions, channel, time of the last successful check, and restart state. Treat an absent or outdated snapshot as unknown.

## Release verification and per-app feeds

Run `swift run ReleaseCheck /path/to/previous.app /path/to/new.zip VERSION SHA256` before publishing. It checks the real
signed payload and runs swap and rollback on a disposable copy using AppUpdater's installer. Run a native previous-build
update and relaunch separately to verify host behavior. After publishing, pass the exact tested artifact to
`scripts/verify-published-release.sh OWNER/REPO TAG ARTIFACT` to verify the public download serves those bytes.

Optional `stableFeedURL` points to a per-app JSON feed on `raw.githubusercontent.com`. Generate entries with
`scripts/update-stable-feed.py` after verifying the public asset. Each entry specifies the minimum macOS and archive SHA-256.
The updater chooses the newest compatible stable entry and checks the checksum before extraction. Existing GitHub release
endpoints still serve older app versions, beta, and stable feed outages. Publish a new version for corrected artifacts.

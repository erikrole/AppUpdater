# AppUpdater

Swift 6 package, macOS 26+, AppKit only, no third-party dependencies. `swift build` / `swift test`
(`APPUPDATER_LIVE=1` adds live Offload DMG and six active public ZIP verification checks). `swift run UpdaterPreview` shows the window.

- AgentBar and PowerBar were retired on October 23, 2026. Exclude them from active host adoption and live release
  checks unless the user explicitly reactivates them. Current repository lifecycle state is in `docs/retirement-2026-10-23.md`.

- `ReleaseInfo` parses GitHub's latest-release JSON; `AppUpdater` decides (rate limit, skip, version) and installs;
  `UpdateInstaller` downloads, verifies, swaps and relaunches; `UpdateWindowController` is the splash.
- Install logic derives from UpdateBar's `DMGInstaller` (Team ID T26T3G8C7Q). Keep the verify-before-swap and
  backup/rollback order; never install an unverified app.
- `prepare` returns a verified staged app, work directory, and installation lease. Retain the lease through cleanup,
  rollback, and the pending quit; pass it to the relaunch helper. Never unlink the persistent lock file or explicitly
  unlock its shared flock; closing the last inherited descriptor releases it. Refuse terminal app symlinks.
- Observe cancellation before swapping. After mounting, register detach before observing cancellation. Let active tools
  finish before removing their files. Rollback must preserve a recoverable copy and report restoration failures.
- Quit fallback must recheck cancellation, its pending-install token, and all windows' sheets after awaiting host saves.
- Run `swift build -Xswiftc -warnings-as-errors`, `swift test -Xswiftc -warnings-as-errors`, and
  `scripts/test-release-notes.sh`. The full suite needs normal AppKit/signature-service and user-cache access.
- ZIP extraction uses system bsdtar with default path safeguards; retain central-directory limits and app-scoped
  link/type checks. DMG and ZIP payloads must pass identical verification before swapping.
- Hosts must allow updater quit only after `isAwaitingRelaunch`, preserving their own busy/save/restore guards.
- Apps integrate through their own repos; do not edit Fetch or Offload from here.

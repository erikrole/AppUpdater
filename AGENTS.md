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

- Stable release checks now fall back on HTTP 403/429 to HTTPS GitHub /releases/latest discovery and tag-anchored HEAD-verified assets. Keep discovery in the configured repository, probes as HEAD across redirects, and the existing install verification. Do not use this fallback for beta lists, TLS/network exceptions, or malformed successful API responses. No account/token/cookies are required; cached real notes take precedence over missing fallback notes. Manual failures show their reason and View Releases.
- Test real signed payloads with `APPUPDATER_SIGNED_APP=/Applications/Fetch.app swift test -Xswiftc -warnings-as-errors` when the default Offload fixture is a local, unnotarized build. This selects a fixture; it does not skip signature/Gatekeeper checks. `APPUPDATER_FALLBACK_LIVE=1 swift test --filter ReleaseFetcherTests/testLiveFallbackWithoutAPIQuota` exercises GitHub web discovery with a forced API limit. Fetch's compatibility branch is based on e1f5004 and does not import main's automatic-install, beta, lease or quit API changes.

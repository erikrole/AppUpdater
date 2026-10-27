# AppUpdater

Swift 6 package, macOS 27, AppKit only, no third-party dependencies. `swift build` / `swift test`
(`APPUPDATER_LIVE=1` adds a live Offload download check). `swift run UpdaterPreview` shows the window.

- `ReleaseInfo` parses GitHub's latest-release JSON; `AppUpdater` decides (rate limit, skip, version) and installs;
  `UpdateInstaller` downloads, verifies, swaps and relaunches; `UpdateWindowController` is the splash.
- Install logic derives from UpdateBar's `DMGInstaller` (Team ID T26T3G8C7Q). Keep the verify-before-swap and
  backup/rollback order; never install an unverified app.
- Apps integrate through their own repos; do not edit Fetch or Offload from here.

- Stable release checks now fall back on HTTP 403/429 to HTTPS GitHub /releases/latest discovery and tag-anchored HEAD-verified assets. Keep discovery in the configured repository, probes as HEAD across redirects, and the existing install verification. Do not use this fallback for beta lists, TLS/network exceptions, or malformed successful API responses. No account/token/cookies are required; cached real notes take precedence over missing fallback notes. Manual failures show their reason and View Releases.
- Test real signed payloads with `APPUPDATER_SIGNED_APP=/Applications/Fetch.app swift test -Xswiftc -warnings-as-errors` when the default Offload fixture is a local, unnotarized build. This selects a fixture; it does not skip signature/Gatekeeper checks. `APPUPDATER_FALLBACK_LIVE=1 swift test --filter ReleaseFetcherTests/testLiveFallbackWithoutAPIQuota` exercises GitHub web discovery with a forced API limit. Fetch's compatibility branch is based on e1f5004 and does not import main's automatic-install, beta, lease or quit API changes.

# AppUpdater

Swift 6 package, macOS 27, AppKit only, no third-party dependencies. `swift build` / `swift test`
(`APPUPDATER_LIVE=1` adds a live Offload download check). `swift run UpdaterPreview` shows the window.

- `ReleaseInfo` parses GitHub's latest-release JSON; `AppUpdater` decides (rate limit, skip, version) and installs;
  `UpdateInstaller` downloads, verifies, swaps and relaunches; `UpdateWindowController` is the splash.
- Install logic derives from UpdateBar's `DMGInstaller` (Team ID T26T3G8C7Q). Keep the verify-before-swap and
  backup/rollback order; never install an unverified app.
- Apps integrate through their own repos; do not edit Fetch or Offload from here.

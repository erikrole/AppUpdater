# Changelog

## 2026-10-28

- Add shared release repositories: `Configuration.tagPrefix`. With `repository: "erikrole/releases", tagPrefix: "scratchpad-"`, a check lists the
  newest 100 releases and offers the highest `scratchpad-vX.Y.Z` with the asset. Other apps' tags are ignored. The rate-limit web fallback is
  not used for prefixed checks. Unprefixed hosts are unchanged.

## 2026-10-26

- Add update channels: `Configuration.channel` (`.production` by default, `.beta`). Beta lists releases, accepts prereleases and picks the
  newest version with the asset. Versions may be `X.Y.Z-beta.N`, ordered below `X.Y.Z`. Production never offers a beta, and no channel downgrades.
- Add automatic install, on by default: `Configuration.autoInstall` (read each launch). A launch check installs a stable update quietly, and the new
  version shows What's New. Beta releases, manual checks, a busy host, skipped versions and a version that failed twice (install error, or the
  relaunch helper restoring the old app) open the splash instead.

## 2026-10-23

- Support signed ZIP releases alongside DMGs, including versioned native-architecture asset names and wrapped apps.
- Bound and validate ZIP extraction, retain internal framework links, and refuse ambiguous app payloads.
- Expose `isAwaitingRelaunch` so hosts can distinguish preparation from the guarded relaunch handoff.

- Serialize preparation, recovery, and relaunch across updater processes so active staging copies and backups survive
  concurrent launch checks. Keep shared installations updateable by other macOS users.
- Preserve recoverable app copies when rollback or relaunch fails, including a missing destination or backup.
- Honor cancellation throughout preparation and quit fallback; recheck pending ownership and sheets after host saves.
- Release cancelled download sessions, bound download timeouts, validate numeric versions, and restrict note links to web URLs.
- Generate release headlines from the newest included commit instead of a trailing WIP or version bump.

Hosts must resolve this package revision and ship a new build to receive these changes. The integration API adds `isAwaitingRelaunch`; existing configurations remain compatible.

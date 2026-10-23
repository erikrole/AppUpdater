# Changelog

## 2026-10-23

- Serialize preparation, recovery, and relaunch across updater processes so active staging copies and backups survive
  concurrent launch checks. Keep shared installations updateable by other macOS users.
- Preserve recoverable app copies when rollback or relaunch fails, including a missing destination or backup.
- Honor cancellation throughout preparation and quit fallback; recheck pending ownership and sheets after host saves.
- Release cancelled download sessions, bound download timeouts, validate numeric versions, and restrict note links to web URLs.
- Generate release headlines from the newest included commit instead of a trailing WIP or version bump.

Hosts must resolve this package revision and ship a new build to receive these changes. The public integration API is unchanged.

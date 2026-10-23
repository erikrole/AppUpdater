# AppUpdater roadmap

Current focus: reliable updates across adopting macOS apps. The October 23, 2026 audit added installation ownership,
checked recovery, preparation cancellation, quit fallback revalidation, and release/download validation without changing
the public integration API. See [audit and verification](docs/audit-2026-10-23.md).

Next work belongs in the adopting apps: resolve a reviewed revision, verify each app's busy/save/quit behavior, and ship
the resulting builds. Fetch and Offload remain on their existing pins until their own repository work updates them.
All eight active host candidates require macOS 27; adoption work must retain that minimum. See the
[platform baseline and verification](docs/host-platform-2026-10-23.md).

Further work to evaluate:

- A startup health acknowledgement before deleting the backup. Currently the helper confirms LaunchServices accepted
  `open`, then waits two seconds; it cannot detect a crash after launch was accepted.
- Automated macOS CI with an SDK matching the package's macOS 27 minimum. No CI workflow is configured in this repo.

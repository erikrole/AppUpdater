# AppUpdater roadmap

Current focus: reliable updates across adopting macOS apps. The October 23, 2026 audit added installation ownership,
checked recovery, preparation cancellation, quit fallback revalidation, and release/download validation. ZIP support
now adds an explicit host relaunch phase. See [audit and verification](docs/audit-2026-10-23.md).

All eight candidate apps now resolve ZIP support and passed their host checks; [delivery and verification](docs/adoption-2026-10-23.md)
records the source commits and remaining release work. All eight updater-enabled host builds are [published and verified](docs/releases-2026-10-23.md).
Next: validate individual installed update/relaunch flows. Fetch and Offload remain on their existing pins until their own repository work updates them.
All eight active host candidates require macOS 27; adoption work must retain that minimum. See the
[platform baseline and verification](docs/host-platform-2026-10-23.md).

Further work to evaluate:

- A startup health acknowledgement before deleting the backup. Currently the helper confirms LaunchServices accepted
  `open`, then waits two seconds; it cannot detect a crash after launch was accepted.
- CI runs the offline suite on the macOS 27 `xcode-27` image. Live download verification remains opt-in.

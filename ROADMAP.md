# AppUpdater roadmap

Current focus: reliable updates across adopting macOS apps. The October 23, 2026 audit added installation ownership,
checked recovery, preparation cancellation, quit fallback revalidation, and release/download validation. ZIP support
now adds an explicit host relaunch phase. See [audit and verification](docs/audit-2026-10-23.md).

Eight candidate apps adopted ZIP support and shipped [verified releases](docs/releases-2026-10-23.md); [delivery and verification](docs/adoption-2026-10-23.md)
records the original integration commits. AgentBar and PowerBar are now [retired](docs/retirement-2026-10-23.md).
The six active ZIP hosts are StatBar, Tweaks, UpdateBar, SnipBar, Cutdown, and TVBar; the live release check covers those six.
Next: validate individual installed update/relaunch flows. Fetch and Offload remain on their existing pins until their own repository work updates them.
All active macOS hosts require macOS 27; adoption work must retain that minimum. See the
[platform baseline and verification](docs/host-platform-2026-10-23.md).

Further work to evaluate:

- CI runs the offline suite on the macOS 27 `xcode-27` image. Live download verification remains opt-in.

Stable release checks now tolerate exhausted shared-network GitHub API quotas via verified public web discovery. Fetch adopts a compatibility backport on its e1f5004 pin; other hosts receive this change when they update their pins.

Opt-in `checkInBackground(shouldPresent:)` supports periodic host prompts without silent installation, duplicate focus changes or interruption of busy work. Hosts must adopt the new revision and own a bounded timer/activation policy.

Background-prompt validation: warnings-as-errors build/test passed (107 tests, 3 optional tests skipped, no failures), including delayed busy/foreground/cancellation/channel changes, new releases while open, Later/Skip, concurrency and post-update state. Release-note scripts and diff checks passed. Offload adopts this API through its own patch release.


The delivery work adds one shared automatic scheduler, opt-in install on ordinary quit, startup confirmation and
rollback, local status reporting, optional cached per-app stable feeds, and a disposable signed-release verification
tool. StatBar and Scratchpad are the initial hosts for native release acceptance. UpdateBar must route managed apps
through their own updaters before the broader rollout.

# AgentBar and PowerBar retirement - October 23, 2026

At the user's request, AgentBar and PowerBar are retired. Development and new releases have ended.

| App | Source | Public feed | Final release |
| --- | --- | --- | --- |
| AgentBar | [erikrole/AgentBar](https://github.com/erikrole/AgentBar) (private) | [erikrole/agentbar-releases](https://github.com/erikrole/agentbar-releases) | [0.1.1, build 2](https://github.com/erikrole/agentbar-releases/releases/tag/v0.1.1) |
| PowerBar | [erikrole/PowerBar](https://github.com/erikrole/PowerBar) (public) | Same repository | [0.1.1, build 5](https://github.com/erikrole/PowerBar/releases/tag/v0.1.1) |

Retirement notices identify the final releases. Source history, published ZIPs, checksums, manifests, and tags are retained. AgentBar source remains private. Local checkout paths remain stable.

The user explicitly approved archiving `erikrole/AgentBar`, `erikrole/agentbar-releases`, and `erikrole/PowerBar`, and disabling both PowerBar workflows. All three repositories are archived. PowerBar's **Release macOS app** and **Tests** workflows are disabled. Repository visibility and final release assets are preserved.

AppUpdater's active ZIP release check now covers StatBar, Tweaks, UpdateBar, SnipBar, Cutdown, and TVBar. It no longer depends on the two retired feeds. Historical audit, adoption, platform, and publication reports retain their original release evidence. All active hosts and the shared package retain the macOS 27 minimum.

Retirement changes project lifecycle and active verification coverage; no new app binaries were built or distributed. Existing installed apps, their saved data, and login/hook preferences are preserved.

## Verification

- `swift build -Xswiftc -warnings-as-errors` passed.
- `APPUPDATER_LIVE=1 swift test -Xswiftc -warnings-as-errors` passed all 73 tests with zero skips or failures, including the six active public ZIPs and Offload DMG. Downloads were prepared and verified in temporary locations.
- `scripts/test-release-notes.sh` and `git diff --check` passed.
- Retirement documentation is the only change in the two host repositories; their app binaries and macOS 27 deployment targets are unchanged.

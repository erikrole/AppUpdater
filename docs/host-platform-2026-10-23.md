# Host platform baseline — October 23, 2026

The required minimum for every active macOS host reviewed in the adoption inventory is **macOS 27.0**.
AgentBar and PowerBar were subsequently [retired](retirement-2026-10-23.md); their entries below preserve the original platform verification.
AppUpdater keeps its existing macOS 27 minimum. There is no compatibility work planned for earlier macOS versions.

| App | Source state |
| --- | --- |
| AgentBar | Raised to 27.0: `0ce6d55c8de2191102a5e634fb38022abd8b830b` |
| PowerBar | Raised to 27.0: `3c09adb577901ca2064894fe2459144058026a75` |
| Tweaks | App, Finder extension, media bundle, and shared package raised to 27.0: `f97380b2857cad42ab53e516e96c893b093b7570` |
| UpdateBar | Raised to 27.0: `17a4edd0d1f0a47860c9eaceeee67bbbeb0b247e` |
| StatBar | Already 27.0; source and generated project checked |
| SnipBar | Already 27.0; source and generated project checked |
| Cutdown | Already 27.0; source and generated project checked |
| TVBar | Already 27.0; source and generated project checked |

The four platform commits were pushed to their repositories' `main` branches. Concurrent version, UI, release, and
documentation work in UpdateBar was excluded from this task's commit. Other existing worktree changes were preserved.

## Verification

For each changed app, regenerated the Xcode project and ran:

```sh
xcodebuild -project <App>.xcodeproj -scheme <App> -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/appupdater-macos27-builds/<App> \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

| Suite | Reported tests | Skipped | Failures |
| --- | ---: | ---: | ---: |
| AgentBar | 14 | 0 | 0 |
| PowerBar | 44 | 0 | 0 |
| Tweaks | 190 | 2 opt-in profiles | 0 |
| UpdateBar | 96 | 4 opt-in live installs | 0 |
| Tweaks' FinderUtilitiesKit (`swift test --package-path Packages/FinderUtilitiesKit`) | 19 | 0 | 0 |

All source and generated deployment settings across the eight candidates are 27.0. The four changed Debug app bundles,
Tweaks' Finder extension, and its media bundle each have `LSMinimumSystemVersion = 27.0` and Mach-O `minos 27.0`.
Whitespace validation passed.

Warnings observed: App Intents metadata extraction is skipped because these apps do not depend on AppIntents.framework.
Tweaks also emits deprecation, capture/mutability, inferred-type, and test QoS warnings. These were not converted into
warning-free claims. Unit suites pass; live feature, performance, and release testing were not repeated for this setting change.

PowerBar's test and release workflows use GitHub's documented `xcode-27` image, which runs macOS 27 and includes its SDK.
The image is currently a public preview; see [GitHub's runner image documentation](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
[PowerBar's hosted Tests run](https://github.com/erikrole/PowerBar/actions/runs/39951770501) completed successfully for the
platform commit.

No app was installed, notarized, released, or deployed by this platform change. Already distributed builds retain their
original requirements. ZIP/release-channel preparation and AppUpdater integration remain separate adoption work.

# Clean-checkout reproducibility: G0-03 / ENG-01

**Result: PASSED for a fresh local checkout and build.** Checked September 25, 2026 on arm64 macOS 26.6.2 with Xcode 27.0, macOS SDK 27.0, and Zig 0.16.0. No app runtime was launched as part of this check.

The project was cloned with `git clone --no-hardlinks` from local commit `e7ce016c12ca49ae2805cd5c2b9d00aea66857ee` into ignored `.build/repro-checkout`. The clone was clean and had no prebuilt Ghostty tree. From that clone:

1. `scripts/bootstrap-engine.sh --build` fetched Ghostty commit `982fe90d941e4b4aab4905ffcbcfdea60bd83343`, verified source archive SHA-256 `0d0a3d9337fcb562bc43483b5bad97ba8fe0f08e000629502f6e7d130808b8b7`, and built the native arm64 `GhosttyKit.xcframework`. It reused Zig's shared default package cache. See `.evidence/repro-bootstrap.log` in the original workspace.
2. `scripts/build.sh --test` compiled the Swift 6 app and produced an ad-hoc signed `Knotch.app` under the clone's `.build/test-app/Build/Products/Release`. `codesign --verify --strict` passed. Bundle ID `dev.personal.Knotch`, `engine-revision.txt`, `ghostty/shell-integration`, `terminfo/78/xterm-ghostty`, and the MIT notice were verified inside the app. See `.evidence/repro-app-build.log`.
3. `scripts/test-models.sh` exited successfully with `Model tests passed`. See `.evidence/repro-model-tests.log`.

The static-library archive is **not byte-for-byte identical across checkout paths**: the original archive SHA-256 is `973da699a65b76574e95c8e3b1bff377db56dc70fdb4418b3f589d9117b520c0`, while this clone produced `bae441d614cd932d4d60eb729addb99f560523f4ef55d3faa4b88ee291e41f25`. Inspection found the clone's absolute source path embedded in archive strings, consistent with path-dependent debug information. The lock file's archive checksum therefore identifies the original local artifact, not a portable byte-for-byte build expectation. This test proves a clean checkout builds and packages the same pinned source; it does not establish binary-identical output or cold-cache dependency download behavior.

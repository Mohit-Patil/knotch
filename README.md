# Knotch

Knotch is a local macOS alpha that keeps one real Ghostty terminal session near the top of the screen. The collapsed black shape joins the MacBook camera cutout at the screen edge. Its small visible lip opens a terminal directly below the cutout; readable content stays outside the hardware. On other displays, the trigger sits near the top center. Hiding the panel leaves the shell running. Quitting or explicitly closing the session ends it.

The app is built for Apple Silicon macOS 26 or later. The qualified local toolchain is Xcode 27.0 with macOS SDK 27.0, Swift 6.4, Zig 0.16.0, and XcodeGen 2.46.0. The full Ghostty core is pinned to commit `982fe90d941e4b4aab4905ffcbcfdea60bd83343`; its internal embedder API is revision-bound.

## Build and open

From this directory:

```sh
scripts/bootstrap-engine.sh --build
scripts/build.sh
open .build/app/Build/Products/Release/Knotch.app
```

The first command fetches and builds the pinned engine. `scripts/build.sh` generates the Xcode project, builds a Release app, bundles its own Ghostty shell integration and terminfo, and signs it locally. No separate Ghostty.app is needed. The app appears in the menu bar as `>_`; choose **Open Project…** or **Open Home Shell** to start its single login shell. You can type an installed `codex`, `claude`, or another terminal command yourself. **Access & Shortcut…** lets you record a shortcut or turn hover reveal off. There is no global shortcut enabled by default.

The overlay controller passed a native test in which hover preview left another editor key; cross-app physical hover is still untested. Click the panel to type. Moving away minimises after 350 ms, postponed until 1.5 seconds after the last input. Selection, composition and dialogs hold it open. Shortcut-only opening stays open until the pointer enters and leaves. **Minimise Terminal** retains the session; a manually operated accessory-mode session kept the same shell PID after minimise and reopen. **Close Session…** asks before ending a running shell, and quitting warns that sessions do not survive app exit. A shortcut can be recorded, but global delivery has not been qualified; the menu-bar handle remains available. Normal `open` launch and direct execution of `Knotch.app/Contents/MacOS/Knotch` both work.

For the ordinary resizable engine harness and local model tests:

```sh
scripts/build.sh --test
.build/test-app/Build/Products/Release/Knotch.app/Contents/MacOS/Knotch --harness
scripts/test-models.sh
scripts/test-native.sh all
```

In the harness, use **Open Project…** or **Home Shell**. A direct fixture directory can also be passed after `--directory` using an absolute path. The test build enables bounded fixture hooks; the normal app does not. The native suite takes about 75 seconds and runs disposable local shells. Results and every unrun acceptance item are recorded in the [qualification report](docs/test-results/acceptance-matrix.md), with a separate [clean-checkout report](docs/test-results/reproducibility.md).

This alpha has one session. Tabs, command presets, automatic agent launch, and session restoration are not implemented. The manual Codex and Claude Code checks reached their trust prompts and exercised navigation and exit; no approval, authentication flow, model request, or paid action was tested. Nothing has been pushed or prepared for distribution.

The September 25 follow-up corrects the detached position and launch behavior shown in the owner screenshot. See the [notch and minimise correction](docs/decisions/0002-notch-attachment-and-minimise.md) for exact behavior and test boundaries.

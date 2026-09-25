# Knotch

Knotch is a local macOS alpha that keeps independent Ghostty terminal sessions near the top of the screen. The collapsed black shape joins the MacBook camera cutout at the screen edge. The expanded panel starts at the same screen edge, placing its title and controls beside the camera and terminal content directly below it. There is no separate handle line. On other displays, the trigger sits near the top center. Hiding the panel or switching tabs keeps the shells running. Closing a tab ends only that session; quitting ends them all.

The app is built for Apple Silicon macOS 26 or later. The qualified local toolchain is Xcode 27.0 with macOS SDK 27.0, Swift 6.4, Zig 0.16.0, and XcodeGen 2.46.0. The full Ghostty core is pinned to commit `982fe90d941e4b4aab4905ffcbcfdea60bd83343`; its internal embedder API is revision-bound.

## Build and open

From this directory:

```sh
scripts/bootstrap-engine.sh --build
scripts/build.sh
open .build/app/Build/Products/Release/Knotch.app
```

The first command fetches and builds the pinned engine. `scripts/build.sh` generates the Xcode project, builds a Release app, bundles its own Ghostty shell integration and terminfo, and signs it locally. No separate Ghostty.app is needed. The app appears in the menu bar as `>_`; choose **Open Project…** or **Open Home Shell** to start a login shell in a new tab. You can type an installed `codex`, `claude`, or another terminal command yourself. **Access & Shortcut…** lets you record a shortcut or turn hover reveal off. There is no global shortcut enabled by default.

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

### Ghostty configuration

Knotch reads Ghostty's standard personal configuration files and their `config-file` includes, using the pinned engine's own lookup and precedence. Fonts, colors, themes, padding, and terminal bindings are no longer replaced by an app-owned palette. Theme resources are bundled from that engine revision; no separate Ghostty app is required. Restart Knotch to apply configuration edits. Your configuration files are never rewritten.

The native notch controls and app shortcuts remain Knotch's. Ghostty new-tab actions are supported; splits and other unsupported window features do not become available just by loading their bindings. The clipboard adapter still rejects terminal read-confirmation requests it does not support. Transparency is composited within Knotch's black panel, so its window appearance is not identical to the standalone Ghostty window.

Knotch clears an inherited `NO_COLOR` flag before engine initialization: launching a GUI terminal from a coding tool must not force its child CLIs into monochrome. Explicit `env = NO_COLOR=…` in Ghostty configuration or a shell startup file still takes effect later. Existing processes retain their environment until restarted.

### Terminal tabs

The tab strip sits across the top of the expanded notch, below the camera-safe header. Click **+** or press **Command-T** for a new shell in the selected tab's original project directory; the folder-plus control opens a project in another tab. Click a tab or use **Command-1…9** to select it. Additional tabs scroll horizontally.

Ghostty's terminal title events name each tab, with its directory as the initial fallback. Double-click or right-click a tab to rename it; clearing the name restores automatic titles. Each tab keeps its own live process, output and scroll position when you switch or minimise. The icon and accessible label distinguish a running shell from an ended session. These are session observations, not claims that an AI task is finished; the terminal's retained output remains the work record.

Use the tab's **×** to close only that session, with confirmation while its shell is alive. Quitting warns before ending all live sessions. Tabs, custom names and scrollback currently live only for this app run; no transcript database, automatic agent completion detection, or session restoration is added.

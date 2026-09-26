# Knotch

Knotch is a local macOS alpha that keeps independent Ghostty terminal sessions near the top of the screen. When collapsed on a MacBook, only the hardware notch is visible; a small transparent hover target surrounds it without drawing an extra lip. The expanded panel starts at the same screen edge, placing its title and controls beside the camera and terminal content directly below it. There is no separate handle line. On displays without a cutout, the compact handle occupies the measured menu-bar band at the top center and the panel expands from that edge. Terminal, Clipboard, Settings, and the empty state share your chosen panel size. A compact Clipboard shelf can stay beneath the terminal. Hiding the panel or switching tabs keeps the shells running. Closing a tab ends only that session; quitting ends them all.

The app is built for Apple Silicon macOS 26 or later. The qualified local toolchain is Xcode 27.0 with macOS SDK 27.0, Swift 6.4, Zig 0.16.0, and XcodeGen 2.46.0. The full Ghostty core is pinned to commit `982fe90d941e4b4aab4905ffcbcfdea60bd83343`; its internal embedder API is revision-bound.

## Build and open

From this directory:

```sh
scripts/bootstrap-engine.sh --build
scripts/build.sh
open .build/app/Build/Products/Release/Knotch.app
```

The first command fetches and builds the pinned engine. `scripts/build.sh` generates the Xcode project, builds a Release app, bundles its own Ghostty shell integration and terminfo, and signs it locally. No separate Ghostty.app is needed. The app appears in the menu bar as `>_`; choose **Open Project…** or **Open Home Shell** to start a login shell in a new tab. You can type an installed `codex`, `claude`, or another terminal command yourself. The **Settings** tab inside the expanded panel lets you record a shortcut, turn hover reveal off, and choose the shared panel width and height. There is no global shortcut enabled by default.

The overlay controller passed a native test in which hover preview left another editor key; cross-app physical hover is still untested. Click the panel to type. Moving away minimises after 350 ms, postponed until 1.5 seconds after the last input. Selection, composition and dialogs hold it open. Shortcut-only opening stays open until the pointer enters and leaves. **Minimise Terminal** retains the session; a manually operated accessory-mode session kept the same shell PID after minimise and reopen. **Close Session…** asks before ending a running shell, and quitting warns that sessions do not survive app exit. A shortcut can be recorded, but global delivery has not been qualified; the menu-bar handle remains available. Normal `open` launch and direct execution of `Knotch.app/Contents/MacOS/Knotch` both work.

For the ordinary resizable engine harness and local model tests:

```sh
scripts/build.sh --test
.build/test-app/Build/Products/Release/Knotch.app/Contents/MacOS/Knotch --harness
scripts/test-models.sh
scripts/test-native.sh all
```

In the harness, use **Open Project…** or **Home Shell**. A direct fixture directory can also be passed after `--directory` using an absolute path. The test build enables bounded fixture hooks; the normal app does not. The native suite takes about 75 seconds and runs disposable local shells. Results and every unrun acceptance item are recorded in the [qualification report](docs/test-results/acceptance-matrix.md), with a separate [clean-checkout report](docs/test-results/reproducibility.md).

Run `scripts/test-native.sh settings` for the focused Settings/session and display-edge fixture. It uses the connected display's AppKit geometry. Model tests cover notched, plain, hidden-menu, tiny, and 3840×2160 layouts. Full physical multi-monitor switching and hover behavior still need owner-side qualification.

This alpha supports multiple live sessions, an in-panel Clipboard tab, and an in-panel Settings tab. Command presets, automatic agent launch, and session restoration are not implemented. The manual Codex and Claude Code checks reached their trust prompts and exercised navigation and exit; no approval, authentication flow, model request, or paid action was tested. Nothing has been pushed or prepared for distribution.

The September 25 follow-up corrects the detached position and launch behavior shown in the owner screenshot. See the [notch and minimise correction](docs/decisions/0002-notch-attachment-and-minimise.md) for exact behavior and test boundaries.

### Ghostty configuration

Knotch reads Ghostty's standard personal configuration files and their `config-file` includes, using the pinned engine's own lookup and precedence. Fonts, colors, themes, padding, and terminal bindings are no longer replaced by an app-owned palette. Theme resources are bundled from that engine revision; no separate Ghostty app is required. Restart Knotch to apply configuration edits. Your configuration files are never rewritten.

The native notch controls and app shortcuts remain Knotch's. Ghostty new-tab actions are supported; splits and other unsupported window features do not become available just by loading their bindings. The clipboard adapter still rejects terminal read-confirmation requests it does not support. Transparency is composited within Knotch's black panel, so its window appearance is not identical to the standalone Ghostty window.

Knotch clears an inherited `NO_COLOR` flag before engine initialization: launching a GUI terminal from a coding tool must not force its child CLIs into monochrome. Explicit `env = NO_COLOR=…` in Ghostty configuration or a shell startup file still takes effect later. Existing processes retain their environment until restarted.

### Terminal tabs

The tab strip sits across the top of the expanded notch, below the camera-safe header. Click **+** or press **Command-T** for a new shell in the selected tab's original project directory; the folder-plus control opens a project in another tab. Click a terminal tab or use **Command-1…9** to select it. Terminal tabs scroll independently; **Clipboard** and **Settings** remain in a fixed group on the right. Switching to either leaves every shell running.

Terminal, Clipboard, Settings, and the empty state all use the same 720×550-point default panel. To resize it, drag the terminal's bottom edge vertically or either lower corner diagonally. The side edges do not resize. The top remains attached to the screen edge and the panel stays centered where the display allows it. **Settings → Panel size** also has width and height sliders and **Reset to display default**. Your chosen size applies to every tab, is saved across launches, and is clamped to the usable area when the display changes.

Ghostty's terminal title events name each tab, with its directory as the initial fallback. Double-click or right-click a tab to rename it; clearing the name restores automatic titles. Each tab keeps its own live process, output and scroll position when you switch or minimise. The icon and accessible label distinguish a running shell from an ended session. These are session observations, not claims that an AI task is finished; the terminal's retained output remains the work record.

Use the tab's **×** to close only that session, with confirmation while its shell is alive. Quitting warns before ending all live sessions. Tabs, custom names and scrollback currently live only for this app run; no transcript database, automatic agent completion detection, or session restoration is added.

### Clipboard history

The **Clipboard shelf** shows recent images, text, links, and files below your live terminal. Scroll horizontally, use **Copy**, drag directly into the visible terminal, or choose **Insert** to insert into the selected running shell without Return. **History** opens the full Clipboard library. The header shelf button or shelf chevron hides it to give the terminal more room; this preference is saved. The shelf automatically yields space on short panels (below 438 points total height) and returns when there is room. Showing or hiding it resizes the same Ghostty surface; it does not restart the shell or change the outer panel size.

The **Clipboard** tab records new text, links, rich text, images, and file references copied while Knotch is running. Use the All, Images, Text, Files, and Pinned filters alongside search. Images appear as compact previews in a horizontal carousel above the text and file list. Scroll sideways with a trackpad or use the arrow buttons; drag an image preview to a terminal tab. Each tile has Copy, Pin, and Remove. **Copy** puts a previous item back on the system pasteboard; it does not paste into another app or run a terminal command. Switching to Clipboard leaves terminal processes and scrollback intact.

Drag an item's thumbnail from Clipboard onto a terminal tab. The tab highlights as a drop target; holding over it switches to that live session and focuses its terminal. If no terminal exists, drop the item on **New Tab (+)** to open a home shell and insert it there. Release over the tab or terminal to insert the item at the cursor without pressing Return. Text, links, and rich text insert plain text. File items insert escaped paths. An image, including a screenshot, is written to an owner-only temporary file and its escaped path is inserted; the file is removed when Knotch quits normally. Multiline or control text asks before insertion. Tab switches keep the panel size steady; reveal and hide use spring motion and respect macOS Reduce Motion.

You can also drag a screenshot from Finder or macOS's floating screenshot thumbnail directly onto the notch handle. The handle opens Clipboard; dropping saves the image to local history and shows it in the carousel without opening a shell or inserting a path. Drag over a terminal tab to select that session, then drop on the tab or terminal surface to insert a private temporary image path at the cursor without pressing Return. Files dropped on the handle are kept as file references in Clipboard; files dropped on a terminal insert escaped paths. File promises from floating thumbnails are supported through AppKit's native receiver; a canceled or oversized promise reports an error.

History is stored only on this Mac under Knotch's private Application Support directory and restored after quitting. Use **Pause** in Clipboard to stop collecting new items, **Clear unpinned history** or **Clear all history…** to remove them, and **Settings → Keep history after quitting Knotch** to turn disk retention off. Concealed/transient pasteboard items are skipped; other sensitive text may still be copied by apps, so clear or pause history when needed. The app keeps at most 50 entries, images up to 4 MB, and text up to 100 KB per entry; file entries retain URLs rather than reading file contents. No clipboard item is uploaded by Knotch or written to diagnostic evidence. This history does not change Ghostty's separate consent policy for terminal-program clipboard requests.

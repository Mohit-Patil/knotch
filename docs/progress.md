# Progress — September 25, 2026

The original specification under `notch_terminal_handoff/` is preserved. Knotch now has a local one-session AppKit/SwiftUI alpha using the pinned full Ghostty native core, a resizable engine harness, an attached top-screen strip/panel, a menu-bar fallback, a folder picker, a recorded shortcut option, and explicit hide/close/quit behavior. It is a local build; no remote repository, push, or distribution step has been performed.

**Build:** `scripts/bootstrap-engine.sh --build`, `scripts/build.sh`, `scripts/build.sh --test`, and `scripts/test-models.sh` passed on the recorded machine. A fresh local clone at commit `e7ce016c12ca49ae2805cd5c2b9d00aea66857ee` also built the pinned engine and test app and passed model tests; see [reproducibility](test-results/reproducibility.md). The engine is Ghostty commit `982fe90d941e4b4aab4905ffcbcfdea60bd83343` with no source patches.

**Native harness:** `.evidence/harness-results.json` reports passes for a real PTY with a clean zsh fixture and selected directory (including spaces and Japanese characters), UTF-8 accented/CJK/emoji input through the engine fixture, resize reflected in child `stty`, raw one-character input and alternate-screen restore, selection/copy, literal paste, and 60 seconds of hidden output with the same shell PID and surface. Two hundred surface occlusion cycles caused no surface recreation; they are not a performance measurement or proof of the full overlay. A controlled `exit 7` retained the final screen. The pinned macOS login wrapper reported an unreliable numeric exit code, so the app says **exit status unavailable** rather than claiming success. A missing bundled shell-integration resource produced a clear failure instead of using another Ghostty installation.

**Installed agents:** In a manually operated local fixture project, the normal shell launched Codex CLI 0.154.0 and Claude Code 2.1.281. Both rendered their trust prompts; native arrows and Return worked, and choosing **No** exited back to the shell. No trust approval, model request, paid request, diff workflow, or authentication workflow was exercised. These observations qualify basic terminal launch and interaction only.

**Native input:** Manual mouse drag selection and Command-C/Command-V passed. A dead-key sequence (Option-E, then E) entered `é`. Direct computer-control `typeText` injection lost some Unicode characters, while native dead-key input, paste, and the engine Unicode fixture succeeded; the automated-input discrepancy remains unresolved and is not evidence that every input method works. A non-Latin IME has not been tested.

**Overlay and accessory-mode checks:** The latest native overlay fixture passed (`.evidence/overlay-results.json`). Supplied tracking events below dwell left an ordinary `NSTextView` key; dwell revealed the real `NSPanel` without moving focus or input from that editor. Deliberate controller activation made the panel and terminal key. The fixture also passed exit-grace reentry, interactive pointer exit, Escape in a raw-input program, a presentation lock, disabled-hover behavior, selected-display bounds, and 200 actual panel reveal/hide calls retaining the same surface and shell PID. Those cycles are not latency or soak measurements. Separately, manual computer control clicked the shipping accessory-mode terminal and entered a shell command; after **Hide Terminal** and an accessibility click on its handle, input reached the same shell PID `87889`.

**Remaining gate:** The controller test supplies pointer events; it is not a physical cross-app hover test. A shortcut was registered successfully and later disabled, but the targeted computer-control key event did not demonstrate global hot-key delivery, so that path remains `NOT_RUN`. Physical notch/external-display behavior, focus return across apps, VoiceOver, and full performance qualification are also open. The earlier timed-out overlay run was superseded by the passing controller fixture; neither run proves those remaining interactions.

Environment: macOS 26.6.2 (25G83), arm64 MacBook Air M5 with 16 GB RAM and a built-in 2560×1664 Retina display; Xcode 27.0 (27A266a), macOS SDK 27.0, Swift 6.4, Zig 0.16.0. The selected deployment target is macOS 26.0. See [compatibility](compatibility.md) for the untested environments and behaviors.

Final validation at source checkpoint `fc1081e`: optimized shipping/test builds and ad-hoc signature verification passed; `scripts/test-models.sh` passed; `scripts/test-native.sh all` passed 11 engine and 12 native controller checks. Normal Launch Services `open` succeeded, showing the empty alpha without session replay. Full [acceptance inventory and evidence](test-results/acceptance-matrix.md) records every remaining item. The app was left open without a shell for the owner to try.

## Owner correction: notch placement and minimise

The screenshot exposed a detached pill/stacked-panel layout and launch into persistent typing mode. These are corrected: hardware-aligned black cap, terminal directly adjoining it, collapsed launch, and pointer-exit minimising even after activation, postponed by typing or interaction locks. This is the owner's explicit refinement of the original focus rule. Model tests and 17 revised native controller checks passed. See [decision and precise evidence boundaries](decisions/0002-notch-attachment-and-minimise.md).

## Owner refinement: smooth spring motion

Added display-linked spring reveal and damped retraction around a fixed-size native terminal. Motion can reverse without stale completion callbacks; Reduce Motion uses a short fade. Release/test builds and model tests pass, along with 21 native overlay checks. See [motion decision and evidence limits](decisions/0003-spring-motion.md) and [native results](test-results/overlay-motion.json). The existing shipping process has an active owner shell, so it was not restarted; the rebuilt app takes effect on the next launch.

## Interface refinement: remove redundant subtitles

At `a5720c1`, replaced the five-button toolbar and generic status sentence with a compact project-name header plus accessible settings, minimise, and close controls. Removed the empty-state tagline, instructional paragraphs, session-lifetime footer, and floating click-to-type hint. The empty state now offers direct Open Project and Home Shell actions. Close is disabled without a session; essential end-session/quit warnings and ended-session status remain.

Release and test builds passed, as did all 21 native overlay regression checks ([results](test-results/overlay-chrome.json)). Installed and signature-verified `/Applications/Knotch.app`. Native UI inspection confirmed the simplified empty state, named icon controls, Home Shell opening with the Home header, close confirmation, return to the empty state after ending only the fresh verification shell, and minimise back to the notch. No physical-hover or frame-pacing qualification was added. The installed app is running collapsed with no test shell left behind.

## Ghostty configuration and monochrome CLI correction

At `97bdcb3`, removed the app-owned appearance overrides and now load Ghostty's own standard personal config files and includes, with matching bundled theme resources. Read-only checks found the installed app inherited `NO_COLOR=1` from its coding-tool launcher; the runtime now removes that inherited flag before shell creation. Explicit user config/shell settings still apply afterward. See [decision](decisions/0004-ghostty-config-and-color.md).

Release/test builds passed, with 12 engine checks and 22 overlay checks, including a real child showing `NO_COLOR` unset, `COLORTERM=truecolor`, and `TERM=xterm-ghostty`. The native appearance probe matched the owner's configured 14 pt, Catppuccin foreground/background and 0.97 opacity. Evidence: [engine](test-results/harness-ghostty-config.json), [overlay](test-results/overlay-ghostty-config.json), [appearance](test-results/ghostty-appearance.json). Installed and signature-verified the new `/Applications/Knotch.app`; its executable hash matches the release build. The existing running process and owner's Claude session were preserved. A restart is required; post-restart Claude colors have not been manually verified and no model request was sent.

## Screen-edge alignment and handle removal

At `d53f2cc`, expanded the panel into the menu-bar band so its top aligns with the screen and camera cutout. Removed the collapsed white/gray grip, squared the expanded top corners, and constrained the header title beside the camera. Model tests, Release/test builds, and 24 native controller checks passed, including actual panel top equality with NSScreen.frame.maxY and camera-safe title/terminal frames. See [decision](decisions/0005-screen-edge-panel.md) and [results](test-results/overlay-screen-edge.json). Installed and signature-verified the updated `/Applications/Knotch.app`; the owner's running shell was preserved, so restarting is required to see the new placement.

## Multiple terminal tabs

At `ac6332d`, added a horizontal tab strip inside the expanded notch with independent reference-owned Ghostty sessions. Engine-emitted titles populate tabs; manual names override them until cleared. Plus/Command-T opens a shell in the selected tab's original project directory, folder-plus opens another project, and Command-1…9 selects a tab. Individual close targets a stable session ID and confirms before ending a live shell; quit confirms before closing every live session. Switching/minimising preserves processes, output and scrollback.

Release/test builds and model tests passed. The full native run passed 12 engine checks and 39 overlay/tab checks. Installed `/Applications/Knotch.app` is signature-verified and its executable hash matches the Release build. Manual UI checks passed creation, rename, numbered switching, Command-T, background-tab close and quit-all warning; the two verification shells were ended and the app was reopened empty/collapsed. See [decision](decisions/0006-terminal-tabs.md), [engine results](test-results/harness-tabs.json), and [tab results](test-results/overlay-tabs.json).

Work tracking currently means live titles, user names, observed shell running/ended status, and each terminal's retained output. No automatic agent completion claims or persistent transcript/history store were added. Tabs/names do not survive app exit. Physical global hover, VoiceOver, multi-display, 50-session leak and performance qualification remain open.

## In-panel Settings and external-display sizing

Settings now appears as a tab in the expanded panel, with hover and shortcut controls. The former separate settings window is removed. Switching to Settings leaves the selected Ghostty surface and shell alive; returning shows the same view and output. The tab has no close or rename action.

On a plain external display, the collapsed handle now occupies that screen's measured menu-bar band at its top edge. The expanded panel joins the same edge and grows within 960–1280 by 520–720 points on larger displays. AppKit screen frames, visible frames and auxiliary camera areas supply placement; display changes recompute it. On the connected 3840×2160, 1× monitor, the native fixture measured a 30-point menu-bar band and a 1280×720 expanded panel. Model tests and the four-check native Settings/display fixture passed. See [decision](decisions/0007-settings-tab-and-display-fit.md) and [native evidence](test-results/settings-display.json).

The Release and qualification builds passed, and the ad-hoc signed Release bundle was installed to `/Applications/Knotch.app` with an executable hash match. The current full native run passed 12 engine checks but stopped in the overlay focus fixture when its separate editor window did not become foreground; the focused four-check Settings/display fixture passed independently. See the [engine report](test-results/harness-settings-display.json) and [incomplete overlay report](test-results/overlay-settings-display-incomplete.json). The already-running Knotch process and its two owner shells were left active, so the updated UI will appear after a later restart. Physical multi-monitor moves, full-screen Spaces, cross-app hover, and manual inspection of the new UI remain unqualified.

## Native picker and alert layering

The owner screenshot showed Open Project appearing behind the status-bar-level expanded panel. App-owned pickers, alerts and tab context menus now temporarily lower both overlay windows to normal level and restore them after dismissal. Project-picker and close-confirmation cancellation return to the panel. See [decision](decisions/0008-system-dialog-layering.md). The updated [six-check fixture](test-results/settings-display-dialog.json) includes native level lowering/restoration. The Release/test builds passed, and the installed bundle's signature and executable hash matched Release. The user-authorized restart ended the previous shell; manual inspection of the new running app then confirmed that the real Open Project picker and a close-session alert both appeared above Knotch. Cancelling the picker restored the panel. A disposable Home shell was ended after checking its alert, and Knotch was left running collapsed without a shell. The direct-executable automated modal fixture could not dismiss its OS picker and is not counted as a pass.

## Compact empty-state refinement

The owner screenshot exposed a full 1280×720 panel with no terminal and an Open Project action that became hard to read while Knotch was inactive. Empty and Settings views now use 600×240 and 640×320 points respectively; terminal sessions retain responsive full size. Both empty-state actions use fixed contrast. Model tests, Release/test builds and [eight focused native checks](test-results/compact-empty-settings.json) passed. The new `/Applications/Knotch.app` signature and executable hash match Release. The app was restarted without a shell; manual inspection confirmed the compact empty and Settings layouts, and it was left running collapsed. Inactive hover-preview contrast and animation pacing across size changes remain unmeasured. See [decision](decisions/0009-compact-empty-panel.md).

## Owner refinement: resizable terminal panel

The terminal panel now accepts drags only on its bottom edge and lower corners. The bottom edge changes height; corners change centered width and height. Settings adds width/height sliders and a display-default reset. Custom dimensions persist across launches and clamp to the selected display. The top stays aligned with the notch or plain display edge. Empty and Settings panels remain compact. See [decision](decisions/0010-terminal-panel-resizing.md).

Model tests, Release/test builds, signature verification, and [ten focused native checks](test-results/resizable-panel.json) passed, including real Ghostty grid resizing with the same surface and shell. An isolated signed app visually showed slider-driven size changes from 1280×720 to about 1833×473 points, persisted across a quit/relaunch, then reset to the display default. Computer-control dragging also failed on a standard slider, so the actual pointer drag handles remain unverified. The new `/Applications/Knotch.app` bundle is signature-verified and executable-hash-identical to Release. Its existing process still has a live shell and was not restarted for this change; the new controls will appear after restart.

## Local Clipboard tab

The owner asked for an in-notch clipboard for text, images, links, and files, with history kept locally until cleared. A new Clipboard tab records ordinary pasteboard changes while Knotch runs, and provides search, previews, copy-back, pinning, removal, pause, and clear controls. Rich text is retained with a plain-text fallback. Settings controls whether the local history file remains after quit. The terminal's separate programmatic clipboard consent pathway is unchanged. See [decision](decisions/0011-local-clipboard-history.md).

The [18-check native fixture](test-results/clipboard-history.json) used a uniquely named pasteboard and synthetic data to verify timed observation, capture/restore of each supported type, concealed-item exclusion, pause, persistence and owner-only storage permissions, pin/clear, and the same real Ghostty surface across Clipboard selection. The Settings regression fixture passed 10 checks and model tests passed. Release/test builds and signature verification passed. An isolated signed app showed the Clipboard and Settings surfaces; no owner's clipboard content was inspected or logged for that UI check. The updated `/Applications/Knotch.app` executable hash matches Release. The existing canonical app process retains a live shell and was not restarted, so it still runs the previous version until the next launch.

## Clipboard drag into terminal

Clipboard thumbnails now start a private drag. Hovering over a terminal tab selects and focuses that running Ghostty session; releasing on the tab or terminal inserts text or escaped file paths without Return. Screenshot images are exported to a private temporary file and their path is inserted. The Clipboard-to-terminal panel size change uses a display-linked spring and Reduce Motion. See [decision](decisions/0012-clipboard-to-terminal-drop.md). The focused [25-check fixture](test-results/clipboard-drop.json) verifies real-engine insertion without command execution and the supporting file, path, and privacy rules. Physical drag timing and perceived smoothness remain unqualified.

## Shared panel size

The owner requested Terminal and all in-panel surfaces to match Settings. The expanded default is now 720×550 points for Terminal, Clipboard, Settings, and empty state, with the same saved custom dimensions applied across tabs. Switching tabs no longer triggers a window-size transition; notch reveal and hide keep their spring motion. The panel still clamps to the selected display. See [decision](decisions/0013-shared-panel-size.md).

The [28-check clipboard fixture](test-results/shared-panel-size.json) verifies the same real Ghostty surface through tab switches and checks that both default and custom dimensions remain shared. The focused Settings fixture passed 10 checks, and model tests passed. Physical pointer resizing and the visual transition on every display remain unqualified.

## External screenshot drop

The notch handle now recognizes screenshots dragged from Finder or the macOS floating thumbnail, in addition to private Clipboard-tab drags. An accepted drag opens the panel; dropping copies image content into local history and inserts a private image path into Ghostty without Return. Ordinary files insert escaped paths. File promises are received with AppKit's native receiver. See [decision](decisions/0014-external-screenshot-drop.md). The [34-check native fixture](test-results/external-screenshot-drop.json) covers direct image and file URL drops, reveal state, history retention, and the unchanged real Ghostty surface. File-promise recognition passed; its asynchronous delivery from a physical floating thumbnail remains unqualified.

Model tests and the 10-check Settings fixture passed. Release and test builds succeeded, and the installed app passed signature and executable-hash verification. Knotch was restarted into this build; native UI inspection showed the notch handle opening to the shared panel and minimising again. Computer-control could not deliver a cross-window Finder drag, so the actual macOS gesture still needs owner-side verification.

## Inline Clipboard image preview

The owner screenshot showed a small image thumbnail with most of the Clipboard panel unused. Image entries now render a large aspect-fit preview directly in their card, with Copy, Pin, and Remove above it. The preview remains the drag source. The repeated drag hint was removed. The test and Release builds passed, as did the 34-check clipboard fixture, 10-check Settings fixture, and model tests. The installed app was restarted and its signature and executable hash verified; native UI inspection showed the image enlarged in the panel. A physical drag starting from the enlarged preview remains unqualified.

## Compact Clipboard image carousel

The owner requested a sliding carousel instead of one image occupying the Clipboard panel. Image entries now appear as 226-point tiles in a horizontal, trackpad-scrollable strip with spring-animated previous/next controls. Text, links, rich text, and files stay in the list below. Each image still exposes Copy, Pin, Remove, and the private drag source. The test and Release builds passed, as did the 34-check Clipboard fixture, 10-check Settings fixture, and model tests. The installed signed executable matched Release and was restarted; native UI inspection confirmed the compact tile with the existing saved screenshot. Multi-image swiping and a physical drag remain untested.

## Screenshot drop destination

The owner screenshot showed a notch drop opening a shell and leaving a private PNG path at its prompt. The handle and panel background now save external images to Clipboard and select the carousel; they do not create a terminal session or insert text. Hovering over a terminal tab selects that live session, while dropping on the tab or Ghostty surface retains the explicit path-insertion flow. The 35-check native Clipboard fixture verifies the handle route leaves the existing Ghostty screen unchanged and the direct-terminal route still inserts without Return. A physical floating-thumbnail drag remains untested.

## Saved screenshot to terminal drag

Native UI automation opened a home shell, selected Clipboard, and physically dragged the saved 11:02 PM screenshot tile onto its terminal tab. The same live Ghostty terminal showed the private PNG path at the prompt without Return. The exported file existed with owner-only `0600` permissions. This verifies the carousel-to-terminal drag in the installed app. A separate drag from macOS's floating screenshot thumbnail into the notch has not been physically exercised.

## Clipboard drag refinement

Terminal tabs now highlight while a Clipboard or external item is over them. The New Tab toolbar button accepts saved Clipboard items, so a screenshot can open a home shell and insert its private path in one drop when no terminal exists. During the drop, an opaque backdrop covers the retained Clipboard drag source behind Ghostty; the source and backdrop are removed explicitly after insertion. New-tab insertion waits briefly for shell startup so the path does not echo before the prompt. The test and Release builds, 36-check Clipboard fixture, 10-check Settings fixture, and model tests passed. Native UI automation physically dropped the saved screenshot both on New Tab and on an existing terminal tab in the installed app. The final new-tab screenshot showed one private path at the prompt, no early duplicate line, and no Clipboard bleed-through. The tab-hover highlight itself was not captured mid-drag.

## Combined Terminal and Clipboard workspace — September 26

The owner asked for a unified UI accommodating both tools. Terminal mode now shows a compact mixed-content Clipboard carousel beneath the same real Ghostty surface, with separate Copy and Insert actions, direct dragging, a History action, and a saved shelf visibility preference. Short panels return the shelf's space to the terminal. Terminal tabs scroll independently of the fixed Clipboard/Settings group; the full library adds content filters and calmer controls. See [decision 0015](decisions/0015-terminal-clipboard-workspace.md).

`scripts/build.sh --test`, `scripts/build.sh`, and `scripts/test-models.sh` passed on macOS 26.6.2 / Xcode 27.0 / Swift 6.4. The final [45-check Clipboard fixture](test-results/terminal-clipboard-workspace.json) and [10-check Settings fixture](test-results/workspace-settings.json) passed. New checks verify real terminal grid resizing, the same surface/PID and focus across shelf changes, insertion without Return, shared outer size, and automatic shelf hiding on a 520×280 panel. The pinned engine is unchanged.

Native UI inspection confirmed the shared workspace, shelf hide/show, the full library's filter empty state, and corrected single-line Copy labels. Two shelf image drags and a full-library-to-tab drag inserted image paths without Return; early shelf drag attempts had no visible result and remain inconclusive. After the final rebuild/restart, a fresh shell accepted another physical shelf-to-terminal drag. The unsubmitted path was cleared, leaving a clean live home shell. No image path was executed or agent request sent.

Installed `/Applications/Knotch.app` passes signature verification and matches the Release executable SHA-256 `7048d391170c43c956cf01b16bd00de30be25232e8d596eb3285cc51d019fb71`. Floating-thumbnail-to-notch delivery, physical monitor transitions, VoiceOver, and measured animation performance remain unqualified; no broader completion claim is made.

## Idle notch without a painted extension — September 26

The owner clarified that the idle app still protruded below the notch. The collapsed trigger is now visually clear on notched displays, with no label or shadow. Its small invisible interaction margins remain; plain displays keep the visible handle. See [decision 0016](decisions/0016-transparent-idle-notch.md).

Model tests, test/Release builds, and [12 native Settings/display checks](test-results/idle-notch.json) passed. The new checks verify the clear idle appearance and a real WindowServer hit in the lower hover margin. An initial immediate hit query raced window registration; a bounded fixture-only wait fixed that test timing. Installed UI automation opened the clear target and minimised back to idle. Physical hover and external drag delivery through the transparent target remain unqualified.

The app was installed and restarted, then left collapsed with no shell. Signature verification passed and the installed executable matches Release SHA-256 `90b51acdaabff38342161748ee961ed2abc3f4658466c6f97234fd62137b1492`. Ghostty and the qualified toolchain are unchanged.

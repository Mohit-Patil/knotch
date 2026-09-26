# Qualification report — September 25, 2026

**Follow-up:** The owner reported the detached panel and requested automatic minimising even after activation, except during typing/selection/dialogs. The [notch/minimise correction](../decisions/0002-notch-attachment-and-minimise.md) supersedes the initial placement and focus-hold behavior below. See [revised native results](overlay-notch-fix.json). Physical cross-app pointer qualification remains NOT_RUN.

Native one-session alpha built at source checkpoint `fc1081e95f61ab4f74392e29df5f0055f32188f0` in Release (Swift 6 whole-module optimization), with `HARNESS_TESTS` enabled only for fixture builds. The earlier ordinary-window engine checkpoint is `e7ce016c12ca49ae2805cd5c2b9d00aea66857ee`. Original acceptance inventory and handoff documents are unchanged.

Environment: macOS 26.6.2 (25G83), Apple Silicon MacBook Air M5 (Mac17,3), 16 GB, built-in 2560×1664 Retina display. Xcode 27.0 (27A266a), macOS SDK 27.0, Swift 6.4, Zig 0.16.0, XcodeGen 2.46.0. Deployment target macOS 26, arm64 only. Clean fixtures use `/bin/zsh -f`; manual agent tests use the discovered system login shell. No provider credential files were inspected and no agent trust or paid action was approved.

Engine: full native GhosttyKit, `982fe90d941e4b4aab4905ffcbcfdea60bd83343`, no upstream patches. Source archive SHA-256 `0d0a3d9337fcb562bc43483b5bad97ba8fe0f08e000629502f6e7d130808b8b7`; local static-library SHA-256 `973da699a65b76574e95c8e3b1bff377db56dc70fdb4418b3f589d9117b520c0`. [Build lock](../../ThirdParty/dependency-lock.json), [clean-checkout result](reproducibility.md), [callback/resource/license inventory](../../ThirdParty/README.md).

Commands: `scripts/bootstrap-engine.sh --build`, `scripts/build.sh`, `scripts/build.sh --test`, `scripts/test-models.sh`, `scripts/test-native.sh all`. The engine command expands to `zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Demit-docs=false -Demit-webdata=false`. The app is ad-hoc signed for local use, not notarized or distributed.

## Engine-first gate

G0-01 through G0-08 passed for the ordinary native window before the overlay implementation: exact pin/toolchain, fresh checkout build, real PTY, full-screen fixture, Unicode, selection/copy/paste, child resize, retained hide/show, owned resources, documented notices and supported callbacks. The full internal embedder is used; no simulated terminal or substitute engine exists in the runtime. The latest [harness results](harness.json) and [native overlay controller results](overlay.json) contain only bounded fixture data.

## Limits of the evidence

The overlay fixture creates a real native editor window and real Ghostty surface in one test application, with regular activation policy so the editor can own focus. It delivers controller tracking events and AppKit key events directly. The shipping alpha uses accessory activation policy and was separately exercised via native computer control for click, input, hide and reopen with the same PID. Neither procedure proves a physical pointer crossing, another application's keyboard ownership, nor OS global-shortcut delivery. Full acceptance rows remain NOT_RUN where only a narrower subtest passed.

Initial engine download stalled; the exact process was stopped and declared dependency archives were fetched over IPv4 with bounded timeouts and verified by Zig's manifest hashes. Retry built successfully. Initial overlay focus fixture failed because its accessory-mode ordinary window could not become key; switching only the fixture to regular policy allowed it to run. The controller also had a synchronous activation assumption, now fixed to await key-window confirmation with a cancellable timeout. Launch Services `open -n -W --stdout ... --env ...` returned -10810; direct executable launches work. Final plain `open .build/app/Build/Products/Release/Knotch.app` succeeded and native UI inspection showed an empty alpha with no restored shell. Build warnings from Ghostty's static archive concern missing ImGui debug symbols; linking and signing succeed. Binary-identical cross-path builds are not established.

The numeric exit-status limitation is upstream and remains: controlled `exit 7` can be reported as 0 by the macOS login wrapper. Output remains inspectable and the app explicitly labels exit status unavailable. Cross-app physical hover/shortcut testing, IME, terminal accessibility, external displays/Spaces, and performance/soak qualification remain open. Tabs, presets, pin/enlarge and diagnostics are later MVP work; this is not a personal-MVP completion claim.

## Engine and process qualification

| ID | Result | Actual evidence / remaining scope |
| --- | --- | --- |
| ENG-01 | PASSED | Fresh local clone of harness checkpoint e7ce016 built pinned engine and app; shared Zig dependency cache reused. See reproducibility.md. Final alpha has also built locally. |
| ENG-02 | PASSED | Static engine and own bundled resource paths; executable linkage has no Ghostty.app dependency. Missing own resource fails closed instead of falling back. |
| ENG-03 | PASSED | Real zsh PTY, working directory containing spaces/Japanese, and foreground PID checked by live engine API and child output. |
| ENG-04 | NOT_RUN | Ordinary typing, Return, arrows, dead key, Command-C/V and raw Escape tested. Complete Tab/Backspace/Home/End/modifier matrix remains. |
| ENG-05 | PASSED | Real bounded alternate-screen raw-input fixture entered, read q, and restored previous screen. |
| ENG-06 | NOT_RUN | Harness resize changed engine grid 28x110 to 21x86 and child stty matched after asynchronous resize. Settings-driven panel resize now also changes a real Ghostty grid without replacing its shell. Repeated panel resize under TUI load is not qualified. |
| ENG-07 | PASSED | Bounded 65-tick child continued output while hidden for 60 seconds; same surface and shell PID after reveal. |
| ENG-08 | NOT_RUN | Tab follow-up: three independent PTYs passed selected-input isolation and retained scrollback/output. Copy works in the engine harness; selected-copy isolation across multiple tabs remains unqualified. |
| ENG-09 | NOT_RUN | Tab follow-up: closing background, selected and last fixture sessions preserved other owned shells; installed UI confirmed a named background-tab close while another tab stayed selected. A separate unrelated-terminal comparison remains unqualified. |
| ENG-10 | PASSED | Controlled exit 7 retains surface/output; numeric status unavailable because pinned macOS login wrapper reports unreliable 0. App never labels it success. |
| ENG-11 | NOT_RUN | 50-create/close orphan and memory test remains. |
| ENG-12 | PASSED | Copy of test app missing bundled zsh integration exited 2 with clear ENGINE_ERROR. No alternate engine or external resource fallback. |

## Hover, focus, and interaction

| ID | Result | Actual evidence / remaining scope |
| --- | --- | --- |
| UX-01 | NOT_RUN | Native controller sub-dwell test PASSED with an ordinary editor key window. Physical mouse crossing while typing into another app not run. |
| UX-02 | NOT_RUN | Real NSPanel preview preserved ordinary NSTextView key window and responder, with terminal state unchanged. Supplied tracking events and same-app editor are not the specified cross-app physical test. |
| UX-03 | PASSED | Native accessory-mode panel clicked using computer control, printf reached real shell. Controller activation also installed terminal first responder. |
| UX-04 | NOT_RUN | Public hotkey registration and UI enable/disable succeeded. Targeted automation key input did not prove global Carbon delivery from another app. |
| UX-05 | NOT_RUN | Owner refinement: idle pointer exit now minimises; actual terminal input postpones it for 1.5 seconds. Native controller regression passed; physical pointer exit while typing remains unqualified. |
| UX-06 | NOT_RUN | Real controller timer/reentry test PASSED. Physical mouse reentry remains. |
| UX-07 | NOT_RUN | Adjacent handle/panel geometry and supplied bridge events tested; physical bridge crossing remains. |
| UX-08 | PASSED | Raw-mode terminal fixture received byte 27 for Escape; actual panel stayed interactive. |
| UX-09 | NOT_RUN | Controller interaction-lock kept actual panel visible after losing key; native file picker and quit confirmation also exercised. Hovering during these modals not tested. |
| UX-10 | NOT_RUN | Pin UI is a later MVP feature; reducer branch only tested. |
| UX-11 | NOT_RUN | Manual Hide and handle reopen preserved accessory-mode shell PID 87889. Cross-app shortcut activation and focus restoration remain. |
| UX-12 | NOT_RUN | Stale timer cancellation covered by deterministic reducer; actual three-app focus-return scenario remains. |
| UX-13 | NOT_RUN | Lower edge/corner drag handles and Settings sliders are implemented. Slider-driven live resizing was inspected; physical pointer-drag behavior and composition timing remain unqualified. |
| UX-14 | NOT_RUN | Controller disabled-hover test PASSED; menu, handle, shortcut registration exist. Full shortcut-only physical workflow remains. |

## Display and OS integration

| ID | Result | Actual evidence / remaining scope |
| --- | --- | --- |
| DSP-01 | NOT_RUN | Built-in notched Mac, public safe-area geometry and actual panel bounds checked; physical notch interaction review still required. |
| DSP-02 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-03 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-04 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-05 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-06 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-07 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-08 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-09 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| DSP-10 | NOT_RUN | Access settings opened, registration enabled/disabled, settings closed, panel accessible. Repeated focus-loop stress not run. |

## CLI launches and agent compatibility

| ID | Result | Actual evidence / remaining scope |
| --- | --- | --- |
| CLI-01 | PASSED | Claude Code 2.1.281 manually launched in fixture login shell; real trust prompt rendered; No, exit selected with Return and shell returned. No model/auth/diff test. |
| CLI-02 | PASSED | Codex CLI 0.154.0 manually launched in fixture login shell; real trust prompt rendered; Down/Return selected No, quit and shell returned. No model/auth/diff test. |
| CLI-03 | NOT_RUN | Preset launches intentionally absent; use normal shell commands. |
| CLI-04 | NOT_RUN | Installed tools resolved in real login shell. Finder-launched app with a shell-managed PATH not qualified. |
| CLI-05 | NOT_RUN | No executable picker or installer exists; shell handles missing commands. Missing-command test not run. |
| CLI-06 | NOT_RUN | No argv/profile launcher shipped. Literal clipboard payload with dollar/semicolon/backtick/Unicode passed safe shell read fixture; this is not an argv serialization test. |
| CLI-07 | NOT_RUN | No argv/profile launcher shipped; control-character argument test remains. |
| CLI-08 | PASSED | Engine received working_directory separately; real shell pwd matched temporary folder containing spaces and Japanese characters. |
| CLI-09 | NOT_RUN | Missing directory is rejected in source before surface allocation; moved-folder UI test not run. |
| CLI-10 | NOT_RUN | One-session alpha refuses another open; no command injection into existing session. Multi-session launch not implemented. |
| CLI-11 | PASSED | Both real agent directory trust prompts were visible and explicitly cancelled through terminal UI; no approval granted. |
| CLI-12 | NOT_RUN | Agent diff/long output/scroll/copy not tested; no paid requests made. |

## International input, clipboard, and accessibility

| ID | Result | Actual evidence / remaining scope |
| --- | --- | --- |
| INP-01 | PASSED | Native Option-E then E composed one é in actual terminal output. |
| INP-02 | NOT_RUN | No real non-Latin IME candidate/commit/cancel qualification. |
| INP-03 | NOT_RUN | UTF-8 accented/CJK/emoji rendering and engine text fixture passed; wide-character resize/selection matrix remains. CUA direct typeText lost characters, while native paste/dead-key paths worked. |
| INP-04 | NOT_RUN | Single-line literal safe-capture paste passed without app-added Return. Multiline confirmation and exact delivery remain. |
| INP-05 | NOT_RUN | Actual bracketed paste fixture remains. |
| INP-06 | NOT_RUN | Reads denied by bundled config; programmatic writes ask only while active, queued consent invalidated on hide/close. OSC52 end-to-end consent/denial remains. |
| INP-07 | PASSED | Native mouse drag selected fixture text; Command-C then Command-V returned selected text at prompt. Ctrl-U cleared it without execution. Engine select-all/copy callback also passed. |
| INP-08 | BLOCKED | Named chrome exists, but native terminal does not yet expose full AX text/selection APIs. VoiceOver and complete keyboard-only navigation need work. |
| INP-09 | NOT_RUN | Alpha is opaque and unanimated by default; changing OS accessibility settings not tested. |

## Privacy, persistence, and failure handling

| ID | Result | Actual evidence / remaining scope |
| --- | --- | --- |
| SAFE-01 | NOT_RUN | Shipping code has no transcript logging, test builds log fixture data only. Fake-token persistence/log audit not run. |
| SAFE-02 | NOT_RUN | Terminal-supplied titles/PWD are not promoted to app chrome. Adversarial title fixture not run. |
| SAFE-03 | NOT_RUN | Adapter permits only deliberate key-window http/https actions; actual allowed/custom-scheme click test remains. |
| SAFE-04 | NOT_RUN | Accurate quit warning and Quit and End Session tested on owned fixtures. Keep-running and Hide Instead lifecycle branches need full UI test. |
| SAFE-05 | PASSED | Relaunch without --directory opened empty shell chooser, no process/session restored or command replayed. Only access preferences persist. |
| SAFE-06 | NOT_RUN | Malformed saved shortcut reports error without overwriting data in source; corrupt-settings UI test not run. |
| SAFE-07 | NOT_RUN | Diagnostics export deferred; fixture reports are explicit test artifacts only. |
| SAFE-08 | PASSED | Reviewed owned runtime/scripts: app loads its own config/resources, no global shell/agent setting mutation or credential-store reads. User login shell and manually launched CLIs retain their normal behavior. |
| SAFE-09 | PASSED | Native builds launched and shell input worked without app requests for Accessibility, Input Monitoring, or Screen Recording. Computer-control tool permissions are separate from Knotch. |
| SAFE-10 | NOT_RUN | Notification actions unhandled; reducer notification event cannot reveal/activate. Cross-app notification fixture not run. |

## Performance qualification

| ID | Result | Actual evidence / remaining scope |
| --- | --- | --- |
| PERF-01 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| PERF-02 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| PERF-03 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| PERF-04 | NOT_RUN | 200 surface cycles and 200 actual panel hide/reveal calls retained one identity/PID and did not crash. No warmup memory trend/retained-count instrumentation; not a performance pass. |
| PERF-05 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |
| PERF-06 | NOT_RUN | Required physical configuration or measurement not exercised in this run. |

## Spring-motion refinement

The subsequent owner-requested spring implementation passed 21 native overlay checks plus model tests and Release/test builds. [Motion evidence](overlay-motion.json) adds intermediate native-window geometry with a stable terminal grid, interrupted reopening, immediate supplied lock-event hiding, and a Reduce Motion fixture. [Decision 0003](../decisions/0003-spring-motion.md) records timings and limits. This does not change the unqualified physical-hover, performance, external-display, or accessibility acceptance statuses above.


## Multiple terminal tabs

At `ac6332d`, Release/test builds and model tests passed, with 12 engine checks and 39 overlay/tab checks. [Overlay/tab evidence](overlay-tabs.json) covers three PTYs, title events and sanitation, manual-name precedence, input isolation, retained scroll position and inactive output, plus background/neighbor/last-tab closure. [Engine evidence](harness-tabs.json) reruns real input, copy/paste, resize, alternate screen and 60-second hidden output.

Installed UI verification exercised Home Shell, plus-button creation, double-click rename, Command-1 selection, Command-T creation, named background-tab close confirmation, and quit-all confirmation. Only the fresh verification shells were ended. The app was reopened empty and collapsed. Full multi-tab copy isolation, 50-session leak qualification, VoiceOver, latency/soak and external displays remain open; running/ended labels are not agent task-completion claims.

## In-panel Settings and external-display sizing

The owner-requested Settings tab and plain-display placement update passed `scripts/test-models.sh`, Release/test builds, signature verification, and four focused native checks. The [Settings/display report](settings-display.json) records the actual 3840×2160 external screen, 30-point menu-bar band, collapsed trigger position, 1280×720 expanded panel, and a real shell preserving the same Ghostty surface, foreground PID and background output through Settings selection. No separate settings window was created. The current `scripts/test-native.sh all` run passed [12 engine checks](harness-settings-display.json), then stopped at [overlay foreground activation](overlay-settings-display-incomplete.json) before reaching the added Settings checks; this is not a full overlay pass. Installation was hash-verified while the owner's two running shells remained active; the running process still has the previous code until restart. Physical multi-monitor switching and manual UI inspection are still open.

## System dialog layering follow-up

The six-check [focused fixture](settings-display-dialog.json) now verifies that app-owned modal dialogs lower the status-bar-level panel to normal level and restore it afterward, plus the earlier display and session checks. The project picker, rename, close, quit and error paths use that helper; tab context menus use the same level change. In the restarted installed app, computer control showed the actual Open Project picker and a close-session alert above Knotch, and picker cancellation returned to the panel. The disposable shell used for the alert was closed; the app was left collapsed and empty. The attempted direct-executable automated modal fixture hung before dismissing its dialog and was removed. The owner screenshot establishes the pre-fix failure only.

## Compact empty-state follow-up

The owner screenshot showed an oversized empty panel and low-contrast inactive Open Project action. The [eight-check native report](compact-empty-settings.json) covers 600×240 empty, 640×320 Settings, full-size terminal, external-display attachment, dialog levels and retained Ghostty shell identity. Model tests cover exact external frames. Release/test builds and installed signature/hash verification passed. Manual inspection of the restarted installed app confirmed the compact empty and Settings layouts. The inactive hover-preview color itself and resizing animation timing were not independently measured.

## Terminal panel resizing follow-up

The [ten-check focused native report](resizable-panel.json) includes a real Ghostty grid resize without replacing the shell or surface, reset to the selected display's adaptive size, compact Settings, and retained session identity. Model tests cover bottom-only height changes, symmetric lower-corner changes, and screen bounds. Release/test builds and signature verification passed. In an isolated signed app, Settings sliders changed a running terminal to about 1833×473 points, those dimensions appeared after quit/relaunch, and Reset restored 1280×720. The lower-edge and lower-corner *physical drag* remains NOT_RUN: computer-control dragging did not move a standard macOS slider either. The newly installed canonical bundle matches Release by executable hash, but its existing process has a live shell and was not restarted during qualification.

## Local Clipboard history follow-up

The owner-added Clipboard feature is outside the original terminal acceptance inventory. The [18-check native report](clipboard-history.json) uses only a uniquely named pasteboard and synthetic content. It passes text, HTTP(S) link, RTF, PNG, file URL, concealed-item exclusion, pause, copy-back of text/image/RTF/files, local reload and owner-only storage permissions, pin/clear, persistence opt-out, timed observation, and real Ghostty surface retention through the Clipboard tab. The Settings fixture passed 10 checks, model tests and both builds passed, and an isolated signed app displayed the new Clipboard and Settings views. Cross-app physical copy/paste through the shipping process, clipboard content from other apps, and behavior after a real Mac restart were not exercised. The canonical installed bundle is signature-verified and hash-identical to Release; its running process was not restarted because it has an active shell.

## Clipboard drag follow-up

The [25-check native report](clipboard-drop.json) extends the isolated clipboard fixture with a private drag ID, shell path escaping, image export permissions and cleanup, unsafe-text detection, and direct insertion into a real Ghostty surface without executing the command. The Settings regression fixture passed 10 checks, model tests passed, and Release/test builds succeeded. A physical thumbnail drag across a tab into the terminal, focus behavior during that drag, and visual animation smoothness remain NOT_RUN. The running canonical process was not restarted because it retains a live shell.

## Shared panel size follow-up

Terminal, Clipboard, Settings, and the empty state now use one 720×550-point default panel. A saved custom size applies to every tab and remains bounded by the selected display. The [28-check native report](shared-panel-size.json) includes default Terminal-to-Clipboard size retention, custom dimensions across Clipboard and Settings, unchanged Ghostty surface, and terminal input after those switches. The Settings fixture passed 10 checks and model tests passed. Physical resizing and visual smoothness on all connected displays remain NOT_RUN.

## External screenshot drag follow-up

The [34-check native report](external-screenshot-drop.json) extends the isolated Clipboard fixture. It verifies external PNG detection, drag-triggered reveal, direct image and image-file capture into local history, insertion of the private image path into a real Ghostty shell without Return, and ordinary file path escaping. The same native Ghostty surface remains alive. A synthetic file promise is recognized, but an isolated named pasteboard did not fulfill it; a physical macOS floating-thumbnail drag remains NOT_RUN. Computer-control attempted a Finder-to-notch drag but its server returned `windowNotFoundAtPosition` before delivering the gesture, so it does not establish app behavior.

The 10-check Settings fixture and model tests passed. Release/test builds and signature verification passed; the installed executable hash matched Release. The installed app was restarted and its notch handle visually opened and minimised. That UI check did not perform an external drop.

## Inline Clipboard image preview follow-up

Image cards now show a large aspect-fit preview directly in the Clipboard tab; actions remain visible above it and the preview retains the private drag source. The 34-check clipboard fixture, 10-check Settings fixture, model tests, and both builds passed. The installed signed executable matched Release and was restarted. Native UI inspection of the owner-shown image confirmed the larger preview; physical dragging from that preview was NOT_RUN.

## Compact Clipboard image carousel follow-up

The full-width image card has been replaced with a horizontally scrollable shelf of compact image tiles; other Clipboard entries remain below it. Arrow navigation uses a spring animation, and the image preview remains the drag source. The test and Release builds passed, alongside the 34-check Clipboard fixture, 10-check Settings fixture, and model tests. The installed signed executable matched Release and was restarted. Native UI inspection confirmed one saved image appears in a compact tile; physical multi-image scrolling and dragging were NOT_RUN.

## Screenshot drop destination follow-up

A screenshot dropped on the notch handle or panel background now saves to local Clipboard history and selects the image carousel without inserting a terminal path. External drags over a terminal tab select that session; a drop on the tab or Ghostty surface still inserts a private image path without Return. The expanded native Clipboard fixture passed 35 checks, including a handle drop that left the live Ghostty screen unchanged and a separate direct-terminal drop that inserted the path. Physical Finder or floating-thumbnail dragging through the shipping UI is NOT_RUN.

## Saved screenshot carousel drag follow-up

PASS: Native UI automation dragged a saved image tile from Clipboard onto a live terminal tab in the installed app. The tab selected and the same Ghostty surface displayed the private PNG path at its prompt without Return. The file existed with `0600` permissions. This proves carousel-to-terminal drag for the tested image and display; physical floating-thumbnail-to-notch delivery remains NOT_RUN.

## Clipboard drag refinement follow-up

PASS: New Tab accepts a saved Clipboard item as a drop, creates a real Ghostty home shell, and inserts its path without Return. Existing terminal tabs gain a drag-hover highlight. The 36-check native Clipboard fixture passed, including a fresh-shell image drop; Settings and model checks passed and both builds succeeded. Native UI automation verified the installed final build by physically dropping a saved screenshot on New Tab and an existing tab. The new shell showed one private path at the prompt, with no duplicate pre-prompt echo or Clipboard bleed-through. The hover highlight was not captured mid-drag, and floating-thumbnail-to-notch delivery remains NOT_RUN.

## Unified workspace follow-up — September 26

PASS: Test and optimized Release builds, model tests, [45 native Clipboard/workspace checks](terminal-clipboard-workspace.json), and [10 native Settings checks](workspace-settings.json). The shelf remains beside the live Ghostty surface; hiding/showing changes actual grid rows while retaining the same surface, shell PID, focus, and outer panel frame. The 520×280 fixture automatically hides the shelf. Full Clipboard and Settings keep their shared outer size and return to the same live terminal. Explicit shelf insertion does not press Return.

PASS (installed UI): Shelf and real terminal visible together; shelf hide/show; full-library navigation; Text filter empty state; single-line card actions; Insert of an image path; physical drags from both shelf images into Ghostty; full-library-to-terminal-tab drag. Early shelf drags produced no visible result; subsequent unchanged-code drags succeeded, so the early attempts do not establish either a pass or a diagnosed defect. A fresh-shell physical drag also succeeded after the final install. Verification input was cleared without execution.

The final installed executable matches Release by SHA-256 (`7048d391170c43c956cf01b16bd00de30be25232e8d596eb3285cc51d019fb71`) and passes ad-hoc signature verification. macOS 26.6.2, Xcode 27.0, Swift 6.4; engine remains `982fe90d941e4b4aab4905ffcbcfdea60bd83343`. NOT_RUN: floating-thumbnail-to-notch delivery, exhaustive shelf drag/focus combinations, physical multi-monitor transitions, VoiceOver, and frame-pacing measurements. This follow-up does not upgrade unrelated acceptance statuses.

## Idle notch follow-up — September 26

PASS: Model tests, test/Release builds, and [12 native Settings/display checks](idle-notch.json). The idle trigger paints clear on the current notched display, has no label or shadow, and leaves the expanded panel ordered out. WindowServer resolves a mouse hit in its invisible lower margin to the trigger. The fixture waits up to two seconds for asynchronous window registration; an earlier immediate query failed before registration completed. Existing display, modal-level, resize, and same-session checks pass.

PASS (installed UI): Clicking the clear target opens the workspace; Minimise returns to idle. The Release executable was installed, signature-verified, restarted, and hash-matched (`90b51acdaabff38342161748ee961ed2abc3f4658466c6f97234fd62137b1492`). NOT_RUN: physical hover entry/exit, external screenshot drag through the transparent margin, and a live switch to an unnotched display. A native hit query is not a physical hover test, and app-window capture cannot verify the hardware notch outline.

## Full-image shelf cards follow-up — September 26

PASS: Test/Release builds and [45 native Clipboard regression checks](clipboard-image-hover.json). Installed UI inspection confirmed full-image previews using the tile height and removal of the permanent image action row; text-card actions remain visible. The image card's named accessibility Insert action inserted a path into a real Ghostty shell without Return. The disposable shell was then closed without executing it.

INCONCLUSIVE: Automated pointer entry, scrolling, dragging, and keyboard gestures produced no reliable UI response. Hover reveal, overlay button hit testing, and physical drag are not verified by this run. NOT_RUN: keyboard-navigation and VoiceOver qualification. The existing regression fixture covers clipboard/session behavior, not SwiftUI hover appearance.

The installed app was restarted and signature-verified; its executable matches Release SHA-256 `2c0d8b8fbd993126d624be79309708af01a65bdf62d5a5d40b81d5d6fe194089`. The pinned Ghostty engine and qualified toolchain remain unchanged.

## All shelf card types follow-up — September 26

PASS: Test/Release builds and [45 existing native clipboard checks](clipboard-all-card-types.json). Installed UI inspection shows text and images using full-card previews without permanent action rows, and type-specific named accessibility actions. The shared implementation also covers rich text, links, and files, preserving their original clipboard representations and terminal insertion callbacks.

NOT_RUN: Physical hover/focus/drag verification, full keyboard/VoiceOver navigation, and live visual inspection of link, rich-text, and file cards. The native fixture verifies capture/copy/insert/session behavior rather than the hover overlay. The app was rebuilt, installed, signature-verified, and restarted. Installed executable SHA-256 matches Release: `e97256f190574787b985f5c01af7253c2e6d07397dbf358de00abe9630c10115`.

## Visibility-state audit follow-up — September 26

PASS: Model tests, test/Release builds, [49 native overlay checks](visibility-overlay.json), [47 native Clipboard checks](visibility-clipboard.json), and [12 native Settings checks](visibility-settings.json). Added regression checks cover final dialog unlock, display change during pending hide/reveal, non-terminal text-field typing grace, external-drag exit/reentry with stale callbacks, drag endpoints inside/outside, and explicit hide during queued existing/new-tab Clipboard insertion. Same real Ghostty surface and shell identity are retained through overlay transitions. Model traces also cover unpin and lock-release hover recovery.

PASS (installed UI): Restarted Release opens from the idle target and minimises back to idle; no shell was created. `/Applications/Knotch.app` passes signature verification and matches the Release executable SHA-256 `eea48e3586e7143e67d6a429f0c01949708312305e6d575bd213daaa55487736`. Environment: macOS 26.6.2 (25G83), arm64, Xcode 27.0 (27A266a), SDK 27.0, Swift 6.4; unchanged Ghostty revision `982fe90d941e4b4aab4905ffcbcfdea60bd83343`.

NOT_RUN: Physical monitor changes, full-screen Spaces transitions, exhaustive cross-app pointer/drag sequences, asynchronous floating screenshot promise fulfillment, and the actual Ghostty paste/clipboard-write consent dialogs. The controller fixtures supply pointer/display/lock events; the NSTextField key is delivered through native panel dispatch. These passes do not upgrade the original physical acceptance statuses. A hypothetical lost mouse-up or composition-release lock was not reproduced and remains an audit limitation, not a confirmed defect.

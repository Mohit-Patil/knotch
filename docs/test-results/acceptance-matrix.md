# Qualification report — September 25, 2026

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
| ENG-06 | NOT_RUN | Harness resize changed engine grid 28x110 to 21x86 and child stty matched after asynchronous resize. Repeated panel resize under TUI load is not qualified; alpha uses fixed expanded bounds. |
| ENG-07 | PASSED | Bounded 65-tick child continued output while hidden for 60 seconds; same surface and shell PID after reveal. |
| ENG-08 | NOT_RUN | Alpha deliberately supports one session; multi-session isolation deferred. |
| ENG-09 | NOT_RUN | Owned fixture close ended its tracked PID. Multi-session/unrelated-terminal comparison not performed. |
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
| UX-05 | NOT_RUN | Supplied pointer-exit event left actual interactive panel key/visible. Physical pointer exit while typing remains. |
| UX-06 | NOT_RUN | Real controller timer/reentry test PASSED. Physical mouse reentry remains. |
| UX-07 | NOT_RUN | Adjacent handle/panel geometry and supplied bridge events tested; physical bridge crossing remains. |
| UX-08 | PASSED | Raw-mode terminal fixture received byte 27 for Escape; actual panel stayed interactive. |
| UX-09 | NOT_RUN | Controller interaction-lock kept actual panel visible after losing key; native file picker and quit confirmation also exercised. Hovering during these modals not tested. |
| UX-10 | NOT_RUN | Pin UI is a later MVP feature; reducer branch only tested. |
| UX-11 | NOT_RUN | Manual Hide and handle reopen preserved accessory-mode shell PID 87889. Cross-app shortcut activation and focus restoration remain. |
| UX-12 | NOT_RUN | Stale timer cancellation covered by deterministic reducer; actual three-app focus-return scenario remains. |
| UX-13 | NOT_RUN | Fixed-size alpha; no interactive resize/composition qualification. |
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

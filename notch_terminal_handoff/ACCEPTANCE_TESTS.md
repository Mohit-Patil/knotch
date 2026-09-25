# Notch Terminal — Acceptance and Qualification Plan

**Version:** 1.0 — September 25, 2026  
**Related specification:** `PRD.md`  
**Status:** Proposed tests. No result below has been executed or marked passed.

## 1. Test rules

Use `PASSED`, `FAILED`, `BLOCKED`, and `NOT_RUN`. Every result records the build, exact engine revision, OS, hardware/display configuration, and test steps. Do not turn missing hardware or an unavailable agent account into a passing test.

Run deterministic, bounded local fixtures first. Use a temporary fixture project, not private production code. Avoid unbounded output loops, global process kills, automatic installers, credential inspection, and paid model requests without the owner's explicit approval.

A fake terminal model may test reducer logic. It cannot qualify the native terminal, process lifecycle, Ghostty integration, or agent compatibility.

## 2. Environment record

| Field | Record during implementation |
|---|---|
| App revision/build mode | Exact Git revision and Debug/optimized configuration. |
| Engine | Component, upstream revision, local patches, artifact checksum if used. |
| Toolchain | Xcode, SDK, Swift compiler, Zig compiler, build command. |
| Operating system | Exact macOS version. |
| Hardware | Mac model, architecture, memory; no serial numbers required. |
| Displays | Notch/no notch, resolution, scale, external layout, menu-bar mode. |
| Shell | Executable, version where appropriate, clean/custom startup behavior. |
| Agent | CLI version, manual or preset launch, account availability. |
| Permissions | Granted/denied state relevant to the test. |

## 3. Engine and process qualification

| ID | Procedure | Required outcome |
|---|---|---|
| ENG-01 | Build from a clean project checkout using recorded dependencies. | Documented build succeeds without undeclared local files. |
| ENG-02 | Run without the separate Ghostty.app installed or referenced. | Framework and resources resolve from this app's own documented layout. |
| ENG-03 | Open a shell; inspect working directory, `tty`, and shell PID. | Real interactive PTY; expected directory; reproducible identity evidence. |
| ENG-04 | Type normal input and use arrows, Tab, Backspace, Home/End equivalents, and modifiers. | Correct terminal behavior; no duplicated or lost ordinary keys. |
| ENG-05 | Run a bounded full-screen terminal fixture or available editor. | Cursor movement, alternate screen, redraw, and terminal controls work. |
| ENG-06 | Change panel size repeatedly and inspect terminal row/column size. | Geometry follows final bounds; no zero-size resize or corrupted TUI. |
| ENG-07 | Keep a bounded timestamp/counter fixture running; hide for 60 seconds. | Output continues; same session, surface, and tracked process on return. |
| ENG-08 | Alternate two independent sessions, each showing a unique fixture ID. | Input and copy selection go only to the selected session. |
| ENG-09 | Close one active fixture session after confirmation. | Other sessions and unrelated external terminals remain running. |
| ENG-10 | Trigger a controlled nonzero process exit. | Output/status remain inspectable; no false success label. |
| ENG-11 | Open and close 50 fixture sessions. | No orphaned app-owned processes or monotonically accumulating surfaces. |
| ENG-12 | Temporarily remove a required bundled resource in a test build. | Clear diagnosable failure; no fallback into another application's resources. |

## 4. Hover, focus, and interaction

| ID | Procedure | Required outcome |
|---|---|---|
| UX-01 | Type into a different app; move pointer through the trigger for less than dwell. | No reveal, focus change, or command launch. |
| UX-02 | Keep typing in the other app; dwell until preview opens. | Keystrokes stay in the other app. Preview visibly indicates click-to-type. |
| UX-03 | Click into preview, then type into a local echo fixture. | Terminal becomes key deliberately; input reaches only that terminal. |
| UX-04 | Activate by shortcut from another app. | Correct panel/session opens and receives input; no duplicate command launch. |
| UX-05 | Move pointer outside an active terminal while continuing to type. | It stays open; typed text is not redirected elsewhere. |
| UX-06 | Leave preview then re-enter before exit grace expires. | Pending collapse is cancelled; no flicker or stale-timer dismissal. |
| UX-07 | Cross the bridge from collapsed strip to expanded terminal. | No accidental collapse caused by an activation gap. |
| UX-08 | Press Escape inside Vim/an agent menu or equivalent local fixture. | Escape reaches terminal; panel does not collapse. |
| UX-09 | Open an app-owned context menu, file picker, or confirmation. | Hover does not collapse the underlying interaction. |
| UX-10 | Pin panel, click another app, then type. | Panel remains visible but does not intercept keystrokes. |
| UX-11 | Use explicit hide after shortcut activation. | Panel hides; session survives; focus returns only when appropriate. |
| UX-12 | Activate, then click a third app before a delayed hide callback. | Old callback cannot steal focus back to an earlier app. |
| UX-13 | Resize while selecting text or composing input. | No unwanted dismissal, selection loss, or spurious input submission. |
| UX-14 | Disable hover and use only shortcut/menu access. | Complete core workflow remains available. |

## 5. Display and OS integration

| ID | Procedure | Required outcome |
|---|---|---|
| DSP-01 | Run on a physical notched Mac where available. | Readable content and controls are outside the physical cutout. |
| DSP-02 | Run on a non-notched or external display. | Top-center trigger and terminal work without notch hardware. |
| DSP-03 | Test 1× and 2× backing scale and move between them. | Crisp text, correct pointer coordinates and terminal geometry. |
| DSP-04 | Use an external display with negative origin coordinates. | Panel stays on selected display within usable bounds. |
| DSP-05 | Disconnect the selected external display while a fixture runs. | Same live session moves to a remaining display or remains accessible by menu. |
| DSP-06 | Toggle menu-bar auto-hide and available screen configurations. | Trigger placement is recomputed; no obstruction of normal menu interaction. |
| DSP-07 | Enter/exit full-screen apps and switch Spaces. | Behavior matches the documented supported mode; failures are recorded, not hidden. |
| DSP-08 | Test Stage Manager and separate-Spaces settings where available. | No invisible key window, stranded overlay, or duplicate terminal processes. |
| DSP-09 | Lock/unlock and sleep/wake. | Sensitive preview is hidden; no automatic command replay; lifecycle rechecked honestly. |
| DSP-10 | Repeatedly open settings while the panel is active. | Settings and panel focus do not form a loop or strand input. |

Physical configuration tests not available on the owner's machine remain `NOT_RUN`. Geometry fixtures support development but do not replace physical qualification.

## 6. CLI launches and agent compatibility

| ID | Procedure | Required outcome |
|---|---|---|
| CLI-01 | Type the installed `claude` command in a normal shell. | Actual Claude Code interface launches; record version and tested interactions. |
| CLI-02 | Type the installed `codex` command in a normal shell. | Actual Codex interface launches; record version and tested interactions. |
| CLI-03 | Launch each through a validated preset in a fixture project. | Correct process/project, normal authentication, no added unsafe flags. |
| CLI-04 | Use a CLI installed through a shell-managed PATH and launch app from Finder. | Works or offers a precise executable/shell fallback; no PATH guessing or home scan. |
| CLI-05 | Attempt a missing executable. | Actionable error; no automatic install or different-agent substitution. |
| CLI-06 | Test arguments containing spaces, apostrophes, dollar signs, backticks, semicolons, Unicode, and leading hyphens. | Fixture receives literal intended arguments; no unintended expansion or execution. |
| CLI-07 | Test unsupported newline/control-character arguments. | Correct literal delivery or explicit rejection; never silent reinterpretation. |
| CLI-08 | Pick a project path with spaces and non-ASCII characters. | Correct working directory; no `cd`-string injection. |
| CLI-09 | Delete/move the selected fixture directory before launch. | User must choose a valid directory; no silent fallback elsewhere. |
| CLI-10 | Attempt launch while another session has an interactive foreground program. | New dedicated session; no injected command into existing foreground input. |
| CLI-11 | Inspect an agent's permission prompt and cancel it manually. | App does not approve it, change policy, or hide it while being answered. |
| CLI-12 | Compare a long output/diff, scroll, and copy in each actual agent. | Usable native terminal behavior; missing capabilities documented by CLI version. |

A shell welcome screen alone does not prove full CLI compatibility. Start with nonmutating fixture work; any actual paid request requires explicit authorization. Do not read provider credential files to manufacture a passing authentication test.

## 7. International input, clipboard, and accessibility

| ID | Procedure | Required outcome |
|---|---|---|
| INP-01 | Enter accented characters with a dead-key layout. | Composed text appears correctly without duplicate characters. |
| INP-02 | Use one non-Latin input method, then cancel and restart composition. | Candidate window, marked text, commit, and cancellation remain usable. |
| INP-03 | Enter emoji and wide characters, then resize and select them. | Rendering/selection remain coherent. |
| INP-04 | Paste multiple lines into a safe capture fixture. | Exact intended content; no app-added Return or automatic execution. |
| INP-05 | Exercise bracketed paste in a supporting terminal fixture. | Engine's intended paste behavior is preserved. |
| INP-06 | Simulate a terminal program's clipboard read/write requests. | Conservative app policy and consent apply; denial resolves the request. |
| INP-07 | Copy using explicit Command-C. | Correct selected content, no unwanted program interrupt or blanket clipboard block. |
| INP-08 | Operate chrome using VoiceOver and keyboard only. | Named controls, discoverable tabs, usable opening/focus/hiding. |
| INP-09 | Enable Reduce Motion and Reduce Transparency. | Stable reduced animation and opaque readable presentation. |

## 8. Privacy, persistence, and failure handling

| ID | Procedure | Required outcome |
|---|---|---|
| SAFE-01 | Generate fixture text containing a clearly fake token-like marker. Inspect app settings and ordinary logs. | Marker is not automatically written as transcript, telemetry, or diagnostics. |
| SAFE-02 | Simulate a title with control characters or misleading directional text. | App chrome is bounded/sanitized; no command execution. |
| SAFE-03 | Click an `https` link and a disallowed custom-scheme fixture link deliberately. | Allowed link opens only by user action; disallowed scheme does not execute. |
| SAFE-04 | Quit with active fixture sessions. | Accurate warning; hide/keep-running options do not terminate them. |
| SAFE-05 | Restart after a normal quit or controlled crash. | Saved entries are inactive; no auto-launch, command replay, or fabricated restoration. |
| SAFE-06 | Corrupt a copy of the settings file in a test profile. | Conservative recovery, clear message, last valid data preserved. |
| SAFE-07 | Export diagnostics. | Previewable sanitized report; no hidden prompt/output/credential collection. |
| SAFE-08 | Inspect runtime dependencies/config access. | No global shell or agent config mutation; no unrelated credential reads by the app. |
| SAFE-09 | Start with broad macOS permissions denied. | Core workflow does not demand blanket Accessibility/Screen Recording/Input Monitoring access. |
| SAFE-10 | Receive a notification while another app is active. | No focus stealing, approval, or code execution. |

## 9. Performance qualification

Measure an optimized app build against a recorded hardware baseline. Exclude child-agent resource use when evaluating app overhead, and report child load separately.

| ID | Test | Record |
|---|---|---|
| PERF-01 | At least 100 warm reveals/tab switches | p50/p95 timings, explicit dwell/animation boundaries. |
| PERF-02 | Idle collapsed app with zero, one, and five idle sessions | 60-second average CPU, memory metric, rendering activity. |
| PERF-03 | Deterministic bounded output while hidden | Output completeness, responsiveness, CPU/memory vs visible baseline. |
| PERF-04 | 200 reveal/collapse cycles after warm-up | Session identity, memory trend, retained-surface count, crash results. |
| PERF-05 | Eight-hour fixture session | Periodic resource samples, session continuity, final output, sleep conditions. |
| PERF-06 | Display move and enlargement under output | Frame responsiveness, final grid correctness, absence of output loss. |

When a target fails, record the bottleneck and decision. Do not relax a threshold silently, report only the fastest run, or describe render-submission timing as physical display latency.

## 10. Release checkpoint

No personal-MVP completion claim while hide destroys sessions, hover redirects typing, launch arguments are unsafe, or a fake terminal is used in the real runtime. Other unsupported environments may be listed as limitations with explicit scope.

Required evidence report: what was built; exact build command; automated results; actual-agent results; physical display results; measured performance; unresolved defects; and known limitations. All unused tests remain visibly `NOT_RUN` rather than disappearing from the report.

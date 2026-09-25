# Notch Terminal — Personal-First macOS PRD

**Document version:** 1.0  
**Prepared:** September 25, 2026  
**Working project name:** Notch Terminal. This is a descriptive codename, not a cleared commercial brand.  
**Purpose:** A build specification for Codex, not a claim that the product is commercially validated.  
**Primary user:** The owner of this project, using existing command-line coding agents on their own Mac.  
**Preferred engine:** Ghostty's native full-terminal core, subject to the integration gate below.  
**Document status:** Researched specification; no application has been built or tested as part of this handoff.

## 0. Instructions to the implementing agent

Build the requested native macOS terminal utility. Do not reopen business ideation, invent a broader platform, or start with a marketing site. The owner has explicitly chosen to build something useful personally while commercial demand remains uncertain.

Read this document, `ACCEPTANCE_TESTS.md`, and `SOURCES.md` before implementation. Respect any existing repository instructions. `CODEX_START_HERE.md` supplies the execution brief. Source references such as [S03] resolve in `SOURCES.md`.

In this document, **MUST** is an acceptance requirement, **SHOULD** is the preferred approach, and **MAY** is optional. Numerical performance and interaction values are proposed engineering targets, not measured results. Architecture descriptions are design decisions unless explicitly marked as observed findings.

Do not invent library APIs, framework packages, supported operating systems, successful builds, benchmark numbers, or manual test results. A screenshot of simulated terminal output is not a functioning terminal. Test doubles belong in tests or explicitly labelled previews, never in the shipping runtime.

## 1. Product intent and decision boundary

### 1.1 One-sentence definition

A native Mac app that rests as a small notch-adjacent or top-center island, expands on hover into a real terminal, and lets the owner interact with existing shells, Claude Code, Codex CLI, and other installed command-line tools without keeping a large terminal window visible.

### 1.2 The complete first useful workflow

The owner opens the app, selects a project directory, opens a shell, and runs an installed coding agent. They collapse the panel while the agent continues executing, work in another app, and return to the same live terminal session by hovering or using a shortcut. They can type, scroll, select, copy, paste, resize, and deliberately end the session.

The terminal itself is the interaction surface. This is not a notification widget that opens another terminal application, not a web chat interface, and not a replacement implementation of the agents.

### 1.3 Personal and commercial decisions are separate

**Personal project:** Proceed with the bounded implementation described here. Success means the owner repeatedly chooses to use it in their actual workflow.

**Paid-product verdict:** PARK — INSUFFICIENT EVIDENCE, unchanged. The owner choosing to build does not establish willingness to pay, differentiation, acquisition, or profitability. No subscriptions, licensing server, analytics SDK, checkout, revenue forecasts, or commercial-growth experiments are required for this personal build.

A future commercial edition would need separate evidence and distribution decisions. It must not expand this scope silently.

### 1.4 User requirements versus reversible defaults

| Item | Basis | Decision |
|---|---|---|
| Mac app with a Dynamic-Island-like top interaction | Explicit request | Native macOS application. |
| Terminal appears on hover | Explicit request | Hover reveals the terminal; explicit click or shortcut gives keyboard focus. |
| Run Claude Code, Codex CLI, and other agents | Explicit request | Host installed CLIs as real terminal applications; do not recreate their APIs. |
| Explore Ghostty/libghostty | Explicit preference | Prefer the full-core native embedding route after proving it builds. |
| Build for personal use despite uncertain demand | Explicit request | No commercial validation gate before personal implementation. |
| Swift/AppKit with SwiftUI chrome | Engineering proposal | Chosen for native windowing and terminal integration. |
| Apple Silicon first; macOS 14+ provisional deployment target | Reversible scope assumption | Confirm against the selected engine and actual build machine. Do not claim compatibility before testing. |
| One visible overlay; multiple retained sessions | Engineering proposal | Start with one session, then qualify five concurrent sessions. |
| No external service operated by this app | Engineering proposal | Local settings and execution; agents retain their own network behavior. |

## 2. What must be true before choosing the engine

### 2.1 Naming and component distinction

The upstream project is **Ghostty**, and its library family is **libghostty**. The current public README distinguishes `libghostty-vt`, which provides terminal parsing/state functionality, from the larger application's implementation. It says the library API signatures remain in flux and does not claim a separately tagged stable libghostty release. [S01]

The checked `include/ghostty.h` explicitly identifies itself as the application's **internal embedder API**, intended for its macOS app rather than general external integration. It exposes native surface/runtime integration. Treat consuming it as an intentional maintenance dependency, not an officially stable public SDK. [S03]

The checked macOS build code creates a `GhosttyKit` XCFramework for linking the native core into Swift. That build artifact is not evidence of an official, stable Swift Package Manager package with the same name. [S05]

### 2.2 Preferred integration route

Use an isolated adapter around a **pinned full-core macOS embedding build**, with the associated native input/view implementation and runtime resources from the same revision. Preserve license notices when adapting upstream code.

The adapter is allowed to depend on the internal embedder interface for this personal project only after the owner-facing engineering risk is recorded in `docs/decisions/0001-terminal-engine.md`. Do not spread its types through the rest of the app.

Do not start by constructing a renderer around `libghostty-vt`. That would move GPU rendering, font layout, input handling, process plumbing, and platform integration into this project's scope. A VT-only route is a different architecture and requires a deliberate scope change.

Do not embed the external Ghostty application window, automate it through Accessibility, or launch it behind a fake terminal view. The target is an in-process native terminal surface in this app.

### 2.3 Reproducibility warning discovered during research

The fetched Ghostty build guide listed Zig 0.15.2 for its tip entry, while the fetched main-branch `build.zig.zon` declared a minimum Zig version of 0.16.0. These are different retrieved versions; neither is permission to combine arbitrary sources and toolchains. [S06, S07]

The fetched development guide also specifies Xcode 26/macOS 26 SDK requirements for main-branch development. That is a build-toolchain statement, not proof that the app must run only on macOS 26. [S08]

**Required response:** select one revision, read its own manifests and build instructions, and record the toolchain that actually builds that revision. Never copy a generic `brew install zig` recommendation and assume the resulting compiler matches.

### 2.4 Engine gate: a functioning harness before the island

Create a minimal ordinary native window with one real terminal surface before implementing notch animations.

| Gate ID | Required evidence |
|---|---|
| G0-01 | Exact upstream revision or release plus checksum recorded; no floating `main` dependency. |
| G0-02 | Matching compiler, Xcode, SDK, target architecture, build mode, framework artifact, and resources recorded. |
| G0-03 | A clean checkout can build the harness using documented commands. |
| G0-04 | The embedded shell accepts input; `tty`, working directory, and shell PID checks behave as expected. |
| G0-05 | A full-screen terminal program, Unicode, selection, copy, and paste work in the harness. |
| G0-06 | Resize changes the child terminal geometry correctly; hide/show preserves the same surface and process. |
| G0-07 | The build does not require the separate Ghostty.app to be installed or read its private resources. |
| G0-08 | Resources, notices, imported native code, and supported/unsupported callbacks are documented. |

A proposed effort cap for this investigation is 8–12 focused developer hours, not a delivery promise. If the gate fails, write the exact failure and smallest next experiment. Continue independent reducer/model tests where useful, but do not mask the failure with a text view or claim a completed terminal.

SwiftTerm is a possible explicit fallback for a separately revised architecture; it is not approved as a silent substitute. Do not ship two terminal engines simply to hedge the dependency.

## 3. Scope and release boundaries

### 3.1 Five essential capability groups

| Group | Personal MVP requirement |
|---|---|
| Top-edge access | Collapsed island, hover preview, click activation, configurable shortcut, hide, pin, and larger viewing mode. |
| Real terminal | Native full terminal input/rendering, live sessions while hidden, normal shell operation, selection and clipboard. |
| Session workflow | Project directory selection, tabs, independent sessions, plain shell plus validated agent launch profiles. |
| Native reliability | Notched and non-notched displays, focus safety, display changes, accessibility, sleep/wake behavior. |
| Local control | Local preferences, honest lifecycle labels, explicit close/quit, diagnostics without transcript logging. |

### 3.2 Smallest usable alpha

One shell on one display; hover/shortcut access; terminal input; hide without terminating; safe explicit close; one project directory; no preset automation required. The owner can type `claude` or `codex` normally. This alpha is useful before multi-session controls or visual refinement.

### 3.3 Personal MVP additions

Add tabs, project/profile selection, tested agent launching, pin/enlarge controls, multi-display repositioning, appearance preferences, truthful attention indicators where supported, and the full reliability test matrix.

### 3.4 Explicitly out of scope

No Windows or Linux UI; iOS version; remote terminal service; cloud session syncing; team accounts; model proxy; token billing; orchestration across agents; auto-approvals; hidden prompt rewriting; integrated browser; source-code editor; autonomous Git operations; plugin marketplace; automatic installation of CLIs; generated API keys; global screen reading; or paywall.

Split panes, detachable windows, persistent sessions after app exit, tmux integration, detailed cost tracking, and rich agent-specific hooks are later candidates, not MVP dependencies. The larger viewing mode stays the same panel and same session.

## 4. Core user stories and acceptance boundaries

### US-01: Quick access without losing my place

While typing in another app, I move the pointer to the island and inspect my terminal. The other app keeps keyboard focus until I click into the terminal or invoke the shortcut. The hover itself must not redirect keystrokes.

### US-02: A real coding-agent session

I choose a project, open a terminal, run an installed CLI, and interact with its own prompts and permission dialogs. Its full-screen interface, selection behavior, and control keys work. The app must not strip ANSI output and present it as ordinary text.

### US-03: Keep working while the panel is hidden

I start a bounded long-running task, hide the panel, and use another app. On return, the same terminal process and history remain. Hiding is presentation, not cancellation or suspension.

### US-04: Several independent projects

I create two or more sessions with different working directories, run different commands, and switch tabs. Input reaches only the selected session. Closing one session does not terminate another.

### US-05: No notch required

On an external display or a Mac without a camera cutout, the same workflow is available through a top-center pill and shortcut. No core capability depends on buying a notched MacBook.

### US-06: Deliberate termination and recovery

When I close an active terminal or quit the app, I see an accurate warning. After an app restart, previous workspace entries can reappear as inactive placeholders, but no process or coding-agent conversation is falsely presented as restored.

## 5. Interaction model: reveal is not focus

### 5.1 Three presentation states, with separate flags

Use a small, testable state reducer. Presentation state MUST NOT own process lifetime.

| State | Visible content | Keyboard behavior | Exit behavior |
|---|---|---|---|
| `collapsed` | Small island/handle; session count or neutral label | No terminal focus | Hover dwell reveals preview; shortcut or click opens interactively. |
| `preview` | Expanded terminal, without taking focus | Keystrokes stay with current app; preview says “Click to type” | Pointer exit collapses after grace period unless an interaction lock exists. |
| `interactive` | Expanded terminal with active controls | Terminal or app control owns focus | Pointer exit alone does not collapse; explicit hide or loss of key focus can collapse when unpinned. |

Orthogonal flags: `isPinned`, `isEnlarged`, `selectedSessionID`, `targetDisplay`, and a set of `interactionLocks`. Do not implement dozens of duplicate states such as `pinnedLargeInteractiveWithMenu`.

### 5.2 Default interaction values

These are adjustable design starting points.

| Parameter | Proposed default | Rule |
|---|---:|---|
| Hover dwell | 180 ms | Crossing the trigger briefly should not open it. |
| Preview exit grace | 350 ms | Re-entry cancels the pending collapse. |
| Reveal animation | 180–220 ms | Animate chrome/mask, not a constantly resizing terminal grid. |
| Close animation | 140–180 ms | Never free the surface at animation completion. |
| Pointer bridge allowance | Small connection between trigger and panel | Prevent a gap from causing immediate collapse while moving into the panel. |

Respect Reduce Motion; use a short fade or an immediate state transition. Do not add bounce to terminal text.

### 5.3 Transition rules

| Trigger | Result |
|---|---|
| Pointer enters the visible activation strip | Arm hover timer; do not create a process yet. |
| Timer fires and pointer still qualifies | Show preview of selected session, or a no-session start screen. |
| Pointer leaves during timer | Cancel timer. |
| Pointer enters expanded panel | Cancel pending collapse. |
| Click terminal or invoke configured shortcut | Make panel key deliberately, focus terminal, enter interactive. |
| Pointer leaves while interactive and key | Remain open. |
| Another app becomes key, panel unpinned | Collapse without forcing focus back to the previous app. |
| Another app becomes key, panel pinned | Remain visible but unfocused; keep all keystrokes with the other app. |
| Explicit hide button/shortcut | Collapse, release terminal focus, preserve sessions. |
| Pin enabled | Keep panel visible until explicitly hidden or pin disabled. |
| Menu, IME composition, selection drag, or modal sheet active | Hold presentation steady; suppress hover-driven collapse. |
| Display changes or app locks | Dismiss or reposition safely; never auto-type or auto-launch a command. |

### 5.4 Keyboard rules

A shortcut recorder is part of onboarding. Offer a suggested combination, such as Command–Option–backquote, but register it only after user confirmation and report conflicts. Keep a menu-bar fallback. KeyboardShortcuts is a verified optional dependency for recording/registering user shortcuts; pin the chosen version. [S16]

**Escape inside the terminal goes to the terminal.** It must not hide the panel while the user is exiting a Vim mode or an agent menu. Escape may dismiss an app-owned popover or close a nonfocused preview only when that app-owned UI legitimately receives the key.

Control-C and Control-D retain terminal meanings. Command-C/Command-V use native copy/paste routing. Command-1…9 may select existing tabs, with a documented reserved-shortcuts policy. Command-W invokes “Close session,” never an unconfirmed process kill. The global toggle is the primary keyboard hide action.

Do not capture global typing or install a global keyboard event logger. A global shortcut is not permission to observe other applications' input.

### 5.5 Focus restoration

Record previous frontmost application identity only for explicit activation. On explicit keyboard hide, restore focus only if this app still owns focus and the prior target remains valid. Do not restore an old application after the user has already clicked a different one. Never activate on a terminal notification.

## 6. Visual specification

### 6.1 Design direction

The app should feel like a compact native tool, not a cyberpunk dashboard. Use a dark neutral surface that visually connects to the notch, restrained separators, clear text, and one modest accent for selection or attention. The terminal content remains the dominant element.

Do not copy another app's artwork, logos, or complete interface. Provider names are text labels for installed tools; original provider branding is unnecessary for the personal build.

Use the system interface font for chrome and a system or user-installed monospace font for the terminal. Do not bundle proprietary font files. A font picker can select fonts already present on the Mac.

### 6.2 Anatomy

```text
                  hardware camera cutout, if present
                       [not a drawable screen area]
                       ┌──────────────────────┐
Collapsed              │ >_    3 sessions     │   visible strip below it
                       └──────────────────────┘

Expanded   ┌───────────────────────────────────────────────────────────┐
           │ project-name   /short/path        [Pin] [Size] [Hide] [⋯] │
           │ Shell 1  │ Claude · project-a │ Codex · project-b │ [+]  │
           ├───────────────────────────────────────────────────────────┤
           │                                                           │
           │       REAL NATIVE TERMINAL SURFACE                        │
           │       No second prompt box. No recreated chat UI.         │
           │                                                           │
           ├───────────────────────────────────────────────────────────┤
           │ Session running                 Click to type / Focused   │
           └───────────────────────────────────────────────────────────┘
```

This is a structural wireframe, not a supplied visual mockup or pixel-perfect reference.

### 6.3 Layout defaults

Start with an expanded panel near 960 × 520 points when the display permits it. A smaller mode may be approximately 760 × 400 points, and an enlarged mode should use a configurable fraction of the available screen rather than a hard-coded enormous window. Clamp dimensions to usable display geometry; a proposed minimum is 640 × 320 points where feasible.

Use a roughly 36-point title/toolbar row, 30-point tab row, and a small optional status row. Hide secondary chrome before reducing the terminal below usable dimensions. Terminal font begins around 13–14 points and is adjustable. Avoid scaling a rasterized terminal to make it fit.

The collapsed shape uses measured notch geometry where available, with all visible text and controls outside the camera cutout. On non-notched displays, use a compact pill centered below the menu bar. Do not draw a fake camera cutout or cover menu items to make it look authentic.

Rounded corners and a subtle shadow belong to the panel chrome. Start with an opaque terminal background; translucent GPU layers are optional only after readability and performance testing. Reduce Transparency uses an opaque surface.

### 6.4 Empty and error states

No session: “Open a terminal in a project” with a directory picker and “Open home shell.” No provider account signup.

Missing CLI: show the attempted tool name, chosen shell/profile, and a manual executable-path option. Offer the official installation documentation, but do not run an installer automatically.

Exited command: keep output visible and show “Session ended” with the known exit status, plus “New shell here,” “Run again,” and “Close.” Run again is a fresh, explicit launch, not resurrection of the old process.

Unavailable engine: show a diagnostic failure and retry/build guidance, not animated fake terminal output.

## 7. Screen geometry and native window behavior

### 7.1 Public APIs, not hard-coded notch dimensions

Use current `NSScreen` geometry and public safe-area/auxiliary-area APIs. Apple documents auxiliary areas and `visibleFrame`; these values describe geometry, not a guarantee that every desired overlay behavior will work on every macOS configuration. [S10]

Treat geometry as a service with test inputs. Observe display-configuration and backing-scale changes. Do not rely permanently on `NSScreen.main`, because the desired display and the main/key-window display can differ.

For a notched display, infer the excluded top region from the documented screen geometry. Place the readable terminal below that region. For a non-notched display, place the trigger below the menu bar. Physical pixels and AppKit points must be converted explicitly; external display origins may be negative.

### 7.2 One visible panel, one selected display

Default to the built-in notched display when present, otherwise the main display. Let the owner select a different display. Do not make the panel chase the pointer across monitors by default.

On disconnect, move the same panel/session to a remaining display; do not create a replacement process. Recalculate dimensions before showing. On reconnect, the previous display preference can become available again without moving an actively edited terminal unexpectedly.

### 7.3 Panel architecture

Use an AppKit `NSPanel` or a documented equivalent proven in the focus spike. A nonactivating panel can reveal without activating the app; the terminal must still become key on deliberate interaction. [S11]

Create the panel with its intended style rather than repeatedly mutating activation semantics. Verify text entry, cursor updates, app-owned dialogs, and accessibility on the actual target OS. Keep settings in a normal settings window where that is simpler.

Use the lowest window level that works. Never place the panel above lock screens, security prompts, or system-critical surfaces. Do not use private window-server APIs or request broad permissions to force the visual effect.

### 7.4 Spaces, full-screen apps, and Stage Manager

Provide a documented behavior choice: show on normal desktops, with full-screen overlay behavior enabled only for combinations proven in testing. Public collection-behavior flags are investigation points, not a blanket promise. [S12]

A safe fallback is to keep the shortcut/menu entry available and explain an unsupported full-screen configuration. Never fabricate success because it works on one display. Test menu-bar auto-hide, Stage Manager, Mission Control transitions, and “Displays have separate Spaces” configurations available on the test machine.

### 7.5 Hover implementation

Use an owned visible activation view with tracking areas and a debounced reducer. Apple documents `NSTrackingArea` for pointer entry/exit and cursor events. [S13]

Do not install a permanently busy global mouse poller. The activation area must not occupy a giant invisible rectangle that intercepts unrelated clicks. Tracking-area refreshes and animations must not themselves create uncontrolled enter/exit loops.

## 8. Terminal runtime and ownership

### 8.1 Ownership model

```text
Application lifetime
  └─ SessionStore
      ├─ Session A ── retained terminal surface ── owned PTY/child lifecycle
      ├─ Session B ── retained terminal surface ── owned PTY/child lifecycle
      └─ Session C ── retained terminal surface ── owned PTY/child lifecycle

OverlayController ── presents selected Session's retained native view
Settings/SwiftUI ── observe metadata; do not own terminal lifetime
```

The selected full-core adapter owns the integration with its process/PTY machinery. Do not independently spawn a second shell with Foundation `Process` and try to connect it to a surface that already owns a child process. Confirm the chosen engine's ownership contract during G0.

### 8.2 Collapse and tab switching invariants

A hide, tab change, or ordinary display move MUST NOT free a surface, close its PTY, send a termination signal, clear its scrollback, restart a shell, or replay input.

Do not create terminal surfaces in the body of a SwiftUI view, or destroy them through `if isExpanded` conditional view lifetime. A stable reference-type session store owns them. Presentation wrappers may be recreated without recreating runtime state.

Hidden surfaces must continue draining output and updating terminal state while their rendering is appropriately occluded. Reducing rendering is not permission to stop reading the PTY or block a writing process.

### 8.3 Animation and resize

Maintain the last valid terminal grid while collapsed. Animate the container's clipping/reveal or chrome, not a terminal that shrinks to one row on every hide. Do not send a zero-size terminal geometry.

Commit the final size before showing or after a size transition, as appropriate to the adapter. Coalesce interactive resize updates. Ensure rows/columns and backing-pixel size agree at 1× and 2× scale. Terminal applications must receive the resulting resize notification through the engine's normal path.

### 8.4 Native input completeness

The adapter must support key presses and releases, modifiers, text insertion, composed text, marked-text input, keyboard-layout changes, pointer movement, clicks, wheel/trackpad scrolling, selection, and native copy/paste. Implement or preserve the native text-input-client contract rather than converting every key to a character. [S14]

The owner must be able to enter Unicode and use dead keys. International input is an acceptance requirement, not a later decorative feature. Follow the native upstream integration at the chosen revision and test it; do not assume a minimal C call demonstrates complete input handling.

### 8.5 Engine adapter contract

Keep the interface small. The following is **project-owned design pseudocode**, not a claim about upstream function names:

```swift
@MainActor
protocol TerminalEngineAdapter: AnyObject {
    var capabilities: TerminalCapabilities { get }
    func createSession(_ launch: LaunchSpec) throws -> TerminalSessionHandle
    func retainedView(for session: SessionID) -> NSView
    func setPresented(_ presented: Bool, for session: SessionID)
    func setKeyboardFocused(_ focused: Bool, for session: SessionID)
    func resize(_ geometry: TerminalGeometry, for session: SessionID)
    func requestClose(_ session: SessionID, userConfirmed: Bool)
    func shutdownAfterConfirmation()
}
```

Input forwarding belongs in the native terminal view. The outer SwiftUI app should not become a second terminal parser. Engine events are typed and delivered through a narrow callback/delegate channel.

Record supported capabilities rather than pretending every backend has arbitrary output-stream access, exact agent-state detection, or durable restoration. Implement only the selected backend. Test doubles use a separate test target.

### 8.6 Memory and callback correctness

Document ownership of C strings, borrowed structures, callback context pointers, app/runtime objects, and surfaces. Copy callback data before moving work to another queue when its lifetime is not guaranteed. Prevent callbacks from dereferencing a destroyed session. Pair every retained context with a single release.

AppKit UI mutation occurs on the main thread. Use the runtime's documented wakeup/event integration; do not add a 60 Hz polling timer to call all APIs regardless of activity. Avoid accidentally binding process or renderer threads to a SwiftUI render pass.

## 9. Shells, launch profiles, and environment

### 9.1 Shell-first support

A plain interactive shell is the baseline. The user can type any installed command, including `claude` and `codex`, without a dedicated integration. Official documentation describes both products as terminal workflows. [S17, S18]

Do not advertise “all agents supported” as a tested claim. Publish a versioned compatibility matrix: tested, partially tested, not installed/not tested. Generic terminal compatibility is a design goal, not a verified list of every CLI.

### 9.2 Profile model

A profile contains a user-visible label, launch kind, executable or command identifier, argument array, default working directory, optional nonsecret environment overrides, and preferred shell behavior. Built-in profiles are Shell, Claude Code, and Codex; custom profiles support other installed tools.

Launching a preset creates a new, dedicated session. It must not type into an existing terminal whose foreground program is unknown.

A preset launch is an explicit user action. No launch occurs on app startup, hover, tab selection, workspace restoration, or receipt of a notification.

### 9.3 Process-launch safety

Represent executable, arguments, directory, and environment as separate typed fields in application logic. Never concatenate a project path or argument into an unescaped shell command. Never use `eval` on profile text.

The engine's configuration can have command-string and shell-expansion semantics. Those semantics must be verified at the pinned version; an app-level argument array does not magically mean the backend consumes argv. [S09]

Preferred implementation: a version-tested launch mapping that runs the selected shell/command with literal arguments. A fixed shell wrapper with positional parameters may be used where necessary, but only with explicit tests for spaces, apostrophes, dollar signs, backticks, semicolons, Unicode, leading hyphens, and newline-containing inputs. Reject unsupported representations with a clear error rather than guessing.

Do not implement command launch by waiting an arbitrary 500 ms and injecting text into a presumed ready prompt. If automatic presets cannot be made reliable, ship shell-first behavior and mark those presets unavailable until the launch gate passes.

### 9.4 Working directories and trust

Use a folder picker and store the selected path/bookmark. Confirm a path still exists and is a directory before launch. Pass working directory through the backend's explicit mechanism, not through `cd <string>` injection.

Do not create missing project directories automatically. Offer to choose another folder. Display a short, readable project path; use the full path only in details.

The application must not scan arbitrary folders for projects or inspect source files to infer which agent to run. Opening a project is a user choice. Repository-specific agent permissions remain the responsibility of the installed CLI.

### 9.5 PATH and shell startup

Do not assume a Finder-launched app inherits the same environment as an existing interactive terminal. Validate the actual shell path and its startup behavior.

First prefer the user's selected interactive/login-shell behavior, tested with the supported shells. If an executable cannot be found, provide an explicit executable picker and readable diagnostics. An optional environment-discovery action may run the user's shell with a bounded timeout, but it must not dump the complete environment into logs or save secrets to settings.

Shell startup files are user code. Do not edit `.zshrc`, `.zprofile`, `.bashrc`, `.bash_profile`, or global PATH automatically. Do not invent PATH entries by scanning the user's home directory. Changes to environment overrides affect new sessions only and are visible to the user.

### 9.6 Agent authentication and safety modes

Users authenticate through the agents' normal mechanisms. The app does not collect or store provider passwords, API keys, or refresh tokens. The installed CLI may access its own configuration and credentials in its normal operation; that is distinct from the app reading and copying them.

Do not insert flags that bypass agent approvals or sandboxing. Do not auto-answer permission prompts. Network access, model selection, tool access, and billing remain agent settings.

If a login flow opens a browser or requires interaction, let the agent's standard flow operate. Report errors accurately. No embedded imitation provider login screen.

## 10. Sessions, termination, and persistence

### 10.1 Session lifecycle

Use separate lifecycle and presentation models.

```text
unstarted → starting → running → exited
                   ↘ failed
running → closing → exited/closed
```

`running` means the session's tracked process is alive, not that an AI model is thinking. `exited` means an observed process exit. An exit code of zero is not proof that the user's coding task was completed correctly.

Differentiate the tracked shell process from its foreground command. A shell can remain alive after an agent exits. Only a direct-launch profile or a verified shell-integration event can support a more specific label.

### 10.2 Closing and quitting

Hide is always nondestructive. Close is explicit. For the personal MVP, conservatively ask for confirmation before closing any session with a live tracked process, unless a tested engine signal establishes that confirmation is unnecessary and the owner opts into that behavior.

Use the engine's close lifecycle first. Any additional process termination must be restricted to processes/process groups demonstrably owned by that session. Never kill every process named `claude`, `codex`, or `zsh`; never trust an old PID without checking identity. Force termination is a separately labelled final action after the graceful path fails.

Quit with live sessions offers “Keep app running,” “Hide instead,” and “Quit and end sessions.” Do not imply sessions survive application exit.

### 10.3 Exit output

Keep ended-session output inspectable until the user closes or replaces it. Do not assume an engine's wait-after-command setting has exactly this behavior; verify it and intercept lifecycle requests as needed. A later keypress must not unexpectedly erase the only useful failure message.

A new shell after exit is a new session or a clearly marked replacement, never the old process. Preserve the ability to copy visible failure output.

### 10.4 What is persisted

Persist preferences, chosen display identity, sizes, profile definitions, selected project paths/bookmarks, tab order, and inactive workspace descriptors. Use atomic local writes and a versioned schema.

Do not persist terminal transcripts, scrollback, prompts, outputs, or raw environment variables by default. The engine may hold scrollback in memory; that is separate from a transcript database.

After a crash or restart, show saved entries as “Not running — start a new session.” Do not replay previous commands automatically, reconstruct unsent terminal input, or claim to resume an agent conversation. A later explicit agent resume feature must use that CLI's documented mechanism and separate user confirmation.

### 10.5 Sleep, lock, and app exit boundaries

Hiding the panel does not stop processes. Normal sleep can pause execution and affect network connections; the MVP does not prevent sleep or guarantee progress during sleep. On wake, refresh presentation and recheck known session state without relaunching commands.

On screen lock, dismiss previews and suppress sensitive notification content. App crashes and force quits are not durable-session boundaries. Users may manually run tmux inside their shell, but the app must not silently depend on or configure it.

## 11. Attention and agent status: no fabricated intelligence

### 11.1 MVP signals

The collapsed island may display a session count, selected profile label, observed terminal bell, or explicitly received progress/notification indication. Show only signals the adapter actually exposes.

Do not scrape screen text with regular expressions to guess “thinking,” “waiting for approval,” or “done.” Silence, output volume, and CPU activity are not sufficient evidence of those states. A raw terminal title is untrusted metadata, not an authoritative job-status channel.

If only session liveness is known, say “Session running.” If no event integration is available, omit attention indicators rather than simulate them.

### 11.2 Optional later hook integrations

Claude Code documents hooks and notification events, including permission-related notifications. This supports investigating a later opt-in integration; it does not mean the MVP should edit global agent settings. [S19]

A future hook component must be separately approved, locally authenticated, session-scoped, bounded in message size, removable, and unable to execute arbitrary commands from received text. Merge only app-owned entries into user configuration after showing a diff and preserving a backup. Never remove unrelated hooks.

Research Codex's current documented mechanism independently when implementing it. Do not assume Anthropic hook fields, lifecycle events, or authentication semantics are portable to other tools.

Notifications are advisory. They must never auto-focus the terminal, approve an action, or expose prompt text on a locked screen.

## 12. Settings and onboarding

### 12.1 First-run path

Launch to a short explanation and a live preview of the trigger's location. Let the user choose a global shortcut, a display, and a project directory, then open a real shell. They can skip shortcut setup because the menu item remains available.

No signup, survey, payment, analytics consent wall, or required provider login. Explain in plain language: “This app runs your own terminal tools. Hiding the panel keeps them running; quitting can end them.”

### 12.2 Settings groups

| Group | MVP controls |
|---|---|
| Access | Shortcut recorder, hover enabled, hover delay, preview exit delay, selected display. |
| Appearance | Font and size, dark/system chrome preference, compact/enlarged panel size, reduced-motion behavior. |
| Sessions | Default shell, default project, profiles, conservative close confirmation. |
| Privacy | Notification previews off by default, local diagnostics controls, explicit export. |
| About | App version, engine revision, notices, known limitations. |

Launch at login is optional and off by default; implement only with a documented platform mechanism after the core works. It must not automatically launch an agent.

Avoid exposing the entire Ghostty configuration surface. Use app-owned configuration, not an automatic import of the user's complete Ghostty setup. A later appearance-only import should be explicit and use an allowlist.

## 13. Security, privacy, and permissions

### 13.1 Authority model

This is a terminal application. Its child tools can act with the logged-in user's authority, subject to macOS protections and the tools' own restrictions. A small floating panel does not make shell commands harmless.

The MVP does not add a separate app sandbox around arbitrary shells. This is a direct-run personal macOS application, not a promise of Mac App Store acceptance. Preserve the agents' independent sandbox/approval settings. Do not request administrator privileges or bypass security controls to get the overlay working.

Do not request Accessibility, Screen Recording, Input Monitoring, or Full Disk Access on first launch. Core hover, owned-view input, and a registered shortcut must be attempted without those broad capabilities. If a chosen implementation unexpectedly requires one, treat it as a design problem to document and resolve, not an automatic permission prompt.

### 13.2 Terminal output is untrusted input

Terminal applications can emit control sequences, titles, URLs, and notification text. Feed terminal content to the engine, but treat anything lifted into app chrome as untrusted data.

Sanitize control characters in titles, bound title/notification length, prevent bidirectional text spoofing in labels, and avoid interpreting output as markup. A title or OSC notification must never become a shell command. Keep filename and metadata handling separate from command execution.

User-initiated link opening may allow `https` and `http`. Block arbitrary executable or custom URL schemes by default. Do not run a command from a clicked terminal hyperlink. Add local-file opening only as a separately considered, confirmed action.

### 13.3 Clipboard policy

Explicit Command-C and Command-V are normal user actions. Programmatic clipboard reads requested by terminal escape sequences are a different operation and should be denied by default or require narrowly scoped consent. Programmatic writes should require consent in this product's conservative default configuration.

Use the engine's clipboard and paste-protection pathways. Ghostty documents controls for programmatic clipboard operations and unsafe paste confirmation; map the app's policy to the pinned implementation rather than bypassing that behavior. [S09]

Preserve bracketed paste and original newlines. Never append Return to a user's paste. Warn before suspicious multiline/control-character paste where supported; bracketed paste is not a guarantee that text is safe.

A clipboard permission dialog is an interaction lock so the panel cannot disappear beneath it. Denial must complete the pending engine request correctly, not leave an unresolved callback.

### 13.4 Data storage policy

All app preferences remain local. No telemetry, third-party analytics, automatic crash uploads, or prompt/response collection in the personal MVP. App-origin network requests are not needed for ordinary operation. This does not prevent user-run CLIs from connecting to their providers.

Do not store credentials in profile JSON. Nonsecret environment overrides are labelled accordingly. If secret management is requested later, it needs a separate Keychain design; do not silently add plaintext secret fields now.

Use user-private application-support storage. Store only necessary paths/settings, write atomically, and handle unreadable or corrupt files without automatically deleting the user's last valid data.

### 13.5 Diagnostics

Default diagnostic entries may contain app/engine versions, sanitized error categories, timestamps, session UUIDs, display dimensions, timings, and resource-path failures. They must not contain terminal bodies, full prompts, full environment dumps, clipboard contents, or provider credentials.

Paths can be sensitive. Shorten/redact them in exported reports unless the user chooses otherwise. User-triggered export shows what will be saved and uses a save dialog. Developer-mode logging is explicit and never silently enabled in a release build.

## 14. Architecture and module responsibilities

Keep one native app and a small number of independently testable modules. Do not introduce a network service, database server, daemon, React frontend, or Electron runtime.

| Component | Responsibility | Must not own |
|---|---|---|
| AppCoordinator | App startup, status menu, shutdown, settings window | Terminal parsing or provider authentication. |
| OverlayController | AppKit panel, state transitions, pin/enlarge, focus | Child lifetime or shell parsing. |
| DisplayGeometryService | Selected screen, safe placement, scale and display changes | Terminal content. |
| SessionStore | Stable session references, selection, ordered tabs | Marketing/provider service accounts. |
| TerminalEngineAdapter | Native runtime, surfaces, input integration, lifecycle events | Business logic or SwiftUI panel appearance. |
| LaunchService | Validated launch specs, working directory, safe profile mapping | Arbitrary global configuration mutation. |
| PreferencesStore | Versioned local settings and inactive workspace descriptors | Transcripts or secrets. |
| AttentionStore | Typed, bounded observed attention events | Guessed agent reasoning/status. |
| Diagnostics | Opt-in export and privacy-aware local measurements | Automatic user-content uploads. |

### 14.1 Suggested repository layout

```text
NotchTerminal/
  App/
    AppCoordinator.swift
    StatusMenuController.swift
  Overlay/
    OverlayController.swift
    OverlayPanel.swift
    OverlayState.swift
    DisplayGeometryService.swift
    Views/
  Sessions/
    SessionStore.swift
    SessionDescriptor.swift
    LaunchSpec.swift
    LaunchService.swift
    AgentProfile.swift
  Terminal/
    TerminalEngineAdapter.swift
    GhosttyAdapter/
      GhosttyRuntime.swift
      GhosttySession.swift
      GhosttyNativeView.swift
      GhosttyCallbacks.swift
      Resources/
  Settings/
  Persistence/
  Diagnostics/
  Resources/
  Tests/
    Unit/
    Integration/
    Fixtures/
  UITests/
  ThirdParty/
    README.md
    dependency-lock.json
    Notices/
  scripts/
  docs/
    PRD.md
    ACCEPTANCE_TESTS.md
    SOURCES.md
    decisions/
    progress.md
    compatibility.md
    test-results/
```

These paths are proposed project structure, not upstream Ghostty filenames. Locate actual upstream view/runtime files at the selected revision rather than guessing their names from this layout.

Avoid producing a very large abstraction layer before the first terminal works. The adapter exists to contain an unstable dependency, not to design an engine marketplace.

### 14.2 Dependency boundaries

Only the Ghostty adapter imports its C module. Build scripts and metadata identify how the framework and matching resources are generated. Swift packages such as KeyboardShortcuts have explicit versions/revisions.

Use a checked-in Xcode project or a reproducible project-generation configuration. Document which route is used. A GUI-only project setup with missing generated files is not a reproducible handoff.

Do not fetch opaque binary frameworks from unverified personal release accounts. Prefer reproducibly built upstream sources. If a binary artifact is used, record provenance, license, architecture, revision, and checksum.

### 14.3 Resource packaging

The framework alone is not enough to assume a complete installation. Validate fonts/symbol fallback, terminfo, shell integration, and any required runtime resources. Ghostty's shell-integration documentation describes resource-location and supported-shell dependencies. [S20]

Resources must be bundled or otherwise resolved through a documented self-contained app layout. Do not rely on another user's source checkout or `/Applications/Ghostty.app` being present. Do not write into the user's Ghostty config to fix missing application resources.

The upstream build explicitly treats resources separately from its library artifacts; use the pinned build's packaging behavior as the source of truth. [S04, S05]

## 15. Data model and persistence format

The following is a proposed application data model, not an upstream schema.

| Model | Key fields |
|---|---|
| AppPreferences | schemaVersion, hoverEnabled, hoverDwellMs, exitGraceMs, shortcut preference, selectedDisplay, panel sizing, font preference, close-confirmation policy. |
| AgentProfile | id, label, kind, executableIdentifier/path, arguments, shell mode, default directory, nonsecret overrides. |
| WorkspaceDescriptor | id, displayName, directory bookmark/path, ordered saved session descriptors. |
| SessionDescriptor | id, profileID, userTitle, initialDirectory, createdAt, lastSelectedAt. This does not contain a running PID to restore. |
| LiveSession | descriptor, runtimeHandle, lifecycle, lastKnownDirectory, observedExit, attention state. Memory-only. |
| AttentionEvent | eventID, sessionID, category, bounded display text, observedAt, source, acknowledged. |
| DependencyRecord | upstream URL, revision, checksum where applicable, compiler/SDK/build mode, artifact path, verification date. |

Store stable IDs, not array indices, as session identity. Selected tab removal must select a valid remaining session or the empty state. Guard delayed callbacks with generation/session identity so an event from a destroyed session cannot update a new tab at the same position.

### 15.1 Persistence rules

Writes are atomic and debounced. A corrupt latest settings file does not authorize deleting all saved profiles. Retain a last-known-valid backup or recover only the affected section. Display an understandable recovery notice.

Never persist live C pointers or assume saved PIDs refer to the same process after restart. A stored directory may disappear or move; ask the user to choose it again. Respect the selected direct-distribution/file-access model rather than pretending all path bookmarks are interchangeable with sandbox security-scoped bookmarks.

### 15.2 Local-state example

```json
{
  "schemaVersion": 1,
  "hoverEnabled": true,
  "hoverDwellMs": 180,
  "previewExitGraceMs": 350,
  "selectedDisplayPolicy": "preferBuiltInThenMain",
  "restoreInactiveWorkspaceEntries": true,
  "autoLaunchAgentsOnStartup": false,
  "persistTerminalTranscripts": false,
  "sendTelemetry": false
}
```

This example is an app-owned proposal. Exact storage keys can change during implementation if the migration and behavior remain explicit.

## 16. Performance and reliability targets

These are **unmeasured starting budgets** for an optimized build on a recorded Apple Silicon test machine. Measure terminal-app overhead separately from shell startup, agent execution, provider latency, and network activity.

| Metric | Initial engineering target | Measurement boundary |
|---|---|---|
| Warm reveal response | First visual response within 100 ms at p95 after the deliberate hover delay | Do not include the configured dwell as accidental latency. |
| Completed reveal | Within 250 ms after the accepted trigger | Include animation; Reduced Motion measured separately. |
| Local input responsiveness | Event-to-render-submission p95 at or below 50 ms in a local echo fixture | Do not label this a photon latency or cloud-agent latency measurement. |
| Warm tab switch | At or below 100 ms at p95 | Existing sessions, no process launch. |
| Hidden idle CPU | Below 1% of one CPU core averaged over 60 seconds | App process, five idle terminals, no child workloads. |
| Warm one-session app footprint | Initial investigation budget of 250 MiB | Excludes child agents; measure actual memory metric consistently. |
| Five-session app footprint | Initial investigation budget of 450 MiB | Includes bounded scrollback; no unlimited retention. |
| Repeated collapse/expand | No crash or monotonic resource leak across 200 cycles | Same process and surface identity throughout. |
| Long-running qualification | Eight-hour local fixture run with bounded output | No agent API charges required. |

Budgets can be revised only with recorded measurements and an explicit trade-off. Do not promise the numbers before benchmarking. If the engine baseline itself exceeds a target, record that honestly before adding UI overhead.

Use bounded scrollback and image storage, with clear per-session limits appropriate to the pinned engine. A proposed starting scrollback allocation is 16 MiB per session. This is a product choice, not a statement that a line-count setting and a byte-count setting are equivalent.

Terminal throughput must not be throttled so severely that children block merely because the panel is collapsed. Throttle cosmetic badges and redraws, not essential output consumption. No continuous decorative animation while hidden or idle.

## 17. Accessibility and keyboard-only operation

All app-owned controls need accessible names and roles: open, hide, pin, enlarge, new session, close session, settings, and tab selection. Status cannot be communicated only by color.

A keyboard-only user can open the panel, select a session, enter the terminal, leave an app-owned dialog, and hide the panel without a pointer. No dependence on hover alone.

Preserve upstream terminal accessibility functionality where possible, and test the embedded result rather than assuming it survived extraction. Verify VoiceOver for chrome and a small terminal reading task. Record limitations instead of declaring full accessibility solely because SwiftUI was used.

Text input includes composed text, emoji, dead keys, and a tested non-Latin input method. Test a multiline paste while an input method is composing. Accessibility font choices may require a larger panel rather than clipping characters.

## 18. Error handling and recoverability

| Failure | Required response | Forbidden response |
|---|---|---|
| Engine build/runtime fails | Show actionable diagnostic; preserve preferences; record failing gate | Replace with fake terminal text. |
| Framework/resources mismatch | Detect early; explain which resource or version is missing | Load random resources from another installed app. |
| Missing shell/CLI | Allow executable selection or plain shell; link official instructions | Auto-install or silently substitute another agent. |
| Shell startup hangs | Offer safe close and startup diagnostics; preserve current state | Infinite spinner or repeated shell spawning. |
| Working directory unavailable | Ask for a replacement location | Execute in an unrelated directory without notice. |
| Child exits | Keep readable output and observed status | Claim task success because output stopped. |
| Renderer unhealthy | Show an explicit problem, preserve session if feasible, offer controlled recovery | Automatically destroy all sessions. |
| Display removed | Reposition the same session or use menu-bar access | Leave an invisible focused terminal stealing input. |
| Global shortcut conflict | Show conflict and provide recorder/menu fallback | Capture an unrelated application's shortcut silently. |
| Settings corrupted | Recover conservatively; keep backup | Erase all configuration without explanation. |
| Update or app quit | Warn about live sessions and require an explicit choice | Kill working agents for an automatic update. |

## 19. Test strategy and definition of done

Use three layers: pure unit tests, real terminal integration tests, and macOS manual/UI qualification. Detailed cases are in `ACCEPTANCE_TESTS.md`.

### 19.1 Unit coverage

The overlay reducer must have deterministic-clock tests for hover cancellation, stale timers, exit grace, focus transitions, pinning, modal locks, display changes, and notification events. Include randomized event sequences with invariant checks.

The launch serializer/adapter must prove literal argument handling. Geometry tests include negative screen origins, 1×/2× scale, notch and no-notch inputs, auto-hidden menu bar changes, and very small usable areas. Persistence tests include migration, partial corruption, and no secret/transcript fields.

### 19.2 Real integration coverage

Test actual terminal I/O, full-screen redraw, resize, selected-session input routing, copy/paste, Unicode, process exit, and output while hidden. Use bounded deterministic fixtures before real agents.

Each real-agent result records macOS, engine revision, shell, CLI name and version, launch method, tested scenarios, and result. If authentication or the CLI is unavailable, mark the test `BLOCKED` or `NOT_RUN`. A fixture is not proof that Claude Code or Codex was tested.

### 19.3 Evidence format

Record `PASSED`, `FAILED`, `BLOCKED`, or `NOT_RUN`, plus build ID, environment, steps, evidence path, and defect reference. Do not convert an untested hardware setup into a pass because the geometry unit tests passed.

Screenshots must use a clean fixture workspace without tokens, personal paths, or real private output. Store logs and screenshots locally in an ignored evidence directory unless the owner deliberately chooses to commit safe examples.

### 19.4 Personal-MVP completion criteria

The MVP is complete only when the preferred terminal integration is built and documented; the complete core workflow works; both target CLIs have been manually qualified or explicitly identified as outstanding; hide/show preserves sessions; focus safety passes; termination is deliberate; and the known-platform matrix is honest.

An alpha can be handed over earlier with clear limitations. Commercial release readiness is not implied by personal-MVP completion.

## 20. Build, license, and distribution

### 20.1 Local-first build path

Keep an unsigned/local-development route that the owner can run through Xcode or a documented build script. Do not require a paid service to try the prototype. Do not claim an unsigned artifact is suitable for other people's Macs without the normal platform distribution considerations.

Scripts must fail clearly on the wrong OS, absent toolchain, incompatible revision, or missing resources. Verify before mutating. Avoid mandatory global package changes; prefer a documented project-local toolchain where practical. Ask for authorization before any privileged install or machine-wide setting change.

### 20.2 Open-source obligations

Ghostty's checked top-level license is MIT and permits reuse/distribution subject to its notice requirements. This does not waive the licenses of bundled dependencies, fonts, themes, or copied third-party code. [S02]

Create a third-party inventory and preserve applicable notices. Do not rename copied upstream source to imply original authorship. Review license requirements again at the exact pinned revision before distribution. Do not assume Ghostty branding rights accompany source-code permission.

### 20.3 External distribution is a later gate

If the owner chooses to share the app publicly, create a separate release path for Developer ID signing, Hardened Runtime configuration, notarization, and validation appropriate to the final bundle. Apple provides a notarization workflow for software distributed outside the App Store. [S15]

Do not copy development-only security exceptions into a public release without an explicit documented requirement. Do not tell users to globally disable Gatekeeper, remove all quarantine protections, or weaken the OS to run the app.

App Sandbox and Hardened Runtime are separate concerns. The personal direct-run scope does not constitute an App Store-policy assessment. Automatic updates are out of scope initially; a later updater must never replace the running app while live sessions are active without consent.

## 21. Implementation sequence and checkpoints

This is an effort-planning structure, not a promise about completion dates. Assume one developer comfortable with Swift/macOS plus coding assistance. A rough personal-beta planning allowance is 80–140 focused hours after the initial engine investigation; input and windowing problems may make that insufficient. Cut optional polish before compromising session safety.

| Stage | Build focus | Exit checkpoint |
|---|---|---|
| 0 — Technical proof | Pin and build engine; ordinary-window terminal harness | G0 passes with real input, resize, and retained-session evidence. |
| 1 — Personal alpha | One session; panel; hover preview; explicit focus; shortcut; safe hide/close | Owner can launch a tool manually, hide it, and return to the same session. |
| 2 — Everyday workflow | Tabs, projects, validated profiles, larger view, pin, basic preferences | Independent sessions run; launch and termination tests pass. |
| 3 — Hardening | Displays, Spaces qualification, international input, accessibility, diagnostics, soak tests | Supported configurations are documented; no unresolved destructive lifecycle defects. |
| 4 — Optional refinement | Appearance refinements and measured convenience improvements | Changes do not regress the previous checkpoints. |

Do not add features from Stage 4 to avoid solving an engine, input, or lifecycle failure in Stage 0/1.

### 21.1 Work order for Codex

Inspect the supplied workspace and applicable instructions. Create a concise implementation plan and engine decision record. Verify dependency/toolchain facts. Build the ordinary-window harness. Add one-session overlay behavior. Add the smallest tested session workflow. Harden and document.

At each meaningful checkpoint, summarize files changed, commands run, test results, remaining defects, and the next bounded task. Where repository practice permits, make small local commits of project-owned work. Do not push, publish, create a remote repository, or alter unrelated projects without the owner's request.

### 21.2 Scope changes requiring an explicit decision

Changing terminal engines; building a custom renderer; introducing a daemon for app-exit persistence; reading agent credential stores; adding cloud infrastructure; automatically editing global shell/agent config; replacing the panel with a web UI; or implementing billing are not ordinary implementation details.

Record why the change is needed, what original requirement it changes, alternatives considered, and new risks. Continue safe independent work rather than pretending the scope change was already approved.

## 22. Risks and mitigations

| Risk | Consequence | Mitigation/stop condition |
|---|---|---|
| Internal Ghostty API changes | Build breakage or behavioral regressions | Pin revision, isolate adapter, upgrade deliberately with tests. |
| Wrong toolchain | Time spent fixing errors unrelated to product logic | Use revision-specific manifests and clean build evidence. |
| Incomplete native input | Broken agent TUI, international typing, or selection | Preserve mature native integration and qualify actual interactions. |
| View lifecycle kills session | Lost work | SessionStore owns surfaces; hide/show invariants and repeated-cycle tests. |
| Hover steals focus | Commands or secrets typed into wrong app | Preview is nonfocused; click/shortcut grants focus; dedicated focus tests. |
| Incorrect command quoting | Unintended execution or wrong project | Typed launch specs, backend-specific serializer tests, no delayed injection. |
| Session status overclaims | Misleading completion/approval UX | Only typed observed events; unknown remains unknown. |
| CPU/GPU stays busy while hidden | Battery/resource waste | Occlude rendering, keep I/O alive, measure idle and output separately. |
| Third-party code/license mismatch | Unclear distribution rights | Pinned inventory, notices, no unverified binary shortcuts. |
| Commercial enthusiasm expands scope | Personal tool never becomes usable | Preserve personal-first release boundary; business verdict remains separate. |

## 23. Future candidates, explicitly deferred

After the owner has used the personal MVP, consider a detachable larger terminal window, one split, an explicit tmux-backed persistence mode, trustworthy opt-in agent hooks, accessibility improvements, or appearance import. Each needs evidence from actual use.

Do not add token-spend estimates derived from terminal text, generic “AI productivity scores,” automatic prompt routing, an agent marketplace, or a subscription solely to make the project look like a business.

For any future commercial assessment, evaluate the same proposal under the owner's standing decision framework. Personal use, visual appeal, and technical completion do not change the paid-business verdict on their own.

## 24. Final handoff checklist

| Deliverable | Required state |
|---|---|
| Native app source and reproducible project configuration | Present and builds for the recorded environment. |
| Terminal dependency record | Exact revision/toolchain/resources and build evidence. |
| Readme | Local setup, launch, supported configurations, and known limitations. |
| Engine decision record | Preferred integration, acknowledged instability, fallback decision if any. |
| Tests | Unit/integration results and honest manual compatibility matrix. |
| Safety behaviors | No focus theft on hover; no session loss on hide; no silent approvals or command replay. |
| Privacy | No automatic transcript storage, secret copying, or analytics. |
| Licenses | Applicable notices and third-party inventory. |
| Progress report | What works, what failed, what was not tested, and next action. |

**The defining outcome:** the owner can hover to inspect, deliberately focus to interact, and hide the terminal without losing the running work. A beautiful collapsed island without that complete behavior is not the product.

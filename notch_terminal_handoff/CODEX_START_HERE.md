# Codex implementation brief: Notch Terminal

Use this prompt with the accompanying `PRD.md`, `ACCEPTANCE_TESTS.md`, and `SOURCES.md` in the selected project workspace. This is a documentation handoff; no application code is supplied.

---

Implement the native personal-first macOS application described in `PRD.md`.

The app sits at the top of the screen as a small notch-adjacent island or a top-center pill on non-notched displays. Hover reveals a real terminal. Clicking or using the selected global shortcut activates keyboard input. Hiding the panel keeps the same terminal session and running tools alive. It must run my installed Claude Code, Codex CLI, and other terminal programs rather than replacing them with a custom chat interface.

I have chosen to build this for my own use. Do not spend this implementation task on market validation, branding, SaaS infrastructure, or pricing. The commercial business is still unvalidated.

## First inspect, then implement

Read all attached handoff documents and existing repository instructions. Preserve unrelated files and current work. Determine the available OS, architecture, Xcode/SDK, Swift, and Zig versions through ordinary read-only checks. Work only in the selected project workspace and explicitly necessary dependency/cache locations.

Do not inspect unrelated private files, provider credential stores, or my other projects. Do not install system-wide tools, change the active Xcode selection with privileged commands, publish anything, create remote repositories, or alter global shell/agent settings without explicit authorization.

If this environment is not macOS, state that fact. You may prepare source and portable tests, but do not claim native builds, window behavior, or GPU/input tests passed.

## The first technical objective

Prove a real embedded Ghostty terminal in a small ordinary native window before implementing the notch UI.

The preferred path uses the full native Ghostty core behind an isolated adapter. Distinguish it from `libghostty-vt`, which is not a drop-in complete native terminal view. The currently checked `include/ghostty.h` is an internal embedder interface; do not describe it as a stable public SDK. Acknowledge the maintenance risk in an architecture decision record.

Select and pin an exact upstream revision. Inspect that revision's own build files, native integration, resources, and toolchain requirements. Do not assume the latest installed Zig compiler matches. The source research found a mismatch between the generic build guide and current main manifest; the selected revision and a successful local build must settle the actual configuration.

Do not guess a Swift package URL or API because its name sounds plausible. Build or obtain an artifact with verified provenance. Keep native wrapper code and resources aligned with the same revision and preserve notices. Do not depend on the separate Ghostty.app being installed.

Implement the G0 harness and record actual commands and test results. If blocked, report the exact error, evidence, and next bounded fix. Do not silently replace Ghostty with SwiftTerm, a webview, a text view, or an external terminal window. A fallback is a separate documented decision.

## Then implement the smallest usable alpha

Use Swift, AppKit windowing, and SwiftUI for appropriate chrome/settings. Keep runtime sessions in a stable reference-owned store outside transient view lifecycles.

Implement one real shell with a user-selected directory, a non-destructive hide/reveal loop, hover preview without focus theft, click/shortcut activation, deliberate close confirmation, and a menu-bar fallback. Plain shell usage is sufficient initially: I can type `claude` or `codex` myself.

The panel should look clean and native: dark neutral chrome, restrained animation, clear text, rounded panel edges, and a comfortably sized terminal. A small visual flourish must not take priority over correct terminal input or process lifetime.

Respect the interaction rules:

- Hover alone never redirects keyboard input from another app.
- Pointer exit never collapses a terminal while it owns keyboard focus or has an active interaction lock.
- Escape inside a terminal goes to the terminal.
- Collapse/tab change never terminates or restarts a process, clears scrollback, or replays input.
- A hidden terminal still drains output; rendering can be occluded without blocking its child.
- Sessions do not pretend to survive app exit or crash.
- Never auto-approve agent actions, inject unsafe flags, or install agents.

Once that vertical slice passes its tests, add the personal-MVP features in the PRD: tabs and projects, validated launch profiles, pin/enlarge, local settings, display handling, accessibility, and diagnostics.

## Launching commands safely

Keep executable, arguments, environment, and working directory separate in application logic. Verify how the selected backend consumes them. Test literal arguments and paths containing spaces, quotes, special characters, and Unicode.

Do not launch by sleeping for a guessed duration and typing into an unknown shell prompt. Do not insert a command into an already-running interactive session. Create a new dedicated session for a profile launch. If preset launching is not yet reliable, retain the honest shell-first alpha instead of pretending it works.

Respect existing CLI authentication and approval settings. Do not read and copy their tokens. Real-agent network requests and paid tests require appropriate authorization; use bounded local fixtures for most qualification.

## Tests and progress

Use `ACCEPTANCE_TESTS.md` as the test inventory. Record `PASSED`, `FAILED`, `BLOCKED`, and `NOT_RUN`; include actual versions and environments. A screenshot or fixture does not prove that a real agent was tested.

Maintain `docs/progress.md`, a dependency lock record, `docs/compatibility.md`, and concise architecture decisions. Capture sanitized evidence only. Never log real terminal prompts, output, environment secrets, or clipboard data by default.

Make small local commits of completed project-owned checkpoints where the repository setup permits it. Use explicit paths and inspect staged files so secrets or unrelated user files are not committed. Do not push or publish without a request.

Do not stop at an architectural essay when implementation tools are available. Work through the next functioning checkpoint. At each handoff, report the actual build result, what runs, tests performed, remaining blockers, and the next bounded task. Never claim planned features have been implemented.

## Required initial deliverable

A reproducible native terminal harness plus its dependency/toolchain evidence, followed by the one-session hover-terminal alpha when the harness passes. Do not start with a full settings dashboard, billing, agent orchestration, or a visually convincing fake terminal.

---

**Owner's central acceptance test:** I can open an installed agent in a real terminal, hide the panel, do other work, hover to inspect it without losing keyboard focus, click to interact, and return to exactly the same live session.

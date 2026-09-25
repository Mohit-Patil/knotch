# Compatibility and qualification scope

Current qualification is on one arm64 MacBook Air M5 (16 GB, built-in 2560×1664 Retina display) running macOS 26.6.2 (25G83). The project targets macOS 26.0 and was built with Xcode 27.0 (27A266a), macOS SDK 27.0, Swift 6.4, Zig 0.16.0, and XcodeGen 2.46.0. The full native Ghostty core is pinned to `982fe90d941e4b4aab4905ffcbcfdea60bd83343` (`1.3.2-dev`); its embedder header is internal rather than a stable SDK.

| Area | Result | Boundary |
| --- | --- | --- |
| Engine build and real PTY harness | PASSED | Fresh local clone, native shell, Unicode fixture, alternate screen, resize, copy/paste, and retained hidden output. See [progress](progress.md). |
| Codex CLI 0.154.0 | PASSED for launch/cancel only | Installed CLI opened in a real Knotch shell, rendered trust prompt, handled arrows/Return, and exited with **No**. No approval, model request, diff, or authentication test. |
| Claude Code 2.1.281 | PASSED for launch/cancel only | Same manual shell interaction and trust-prompt boundary as Codex. |
| Native overlay controller and panel | PASSED within fixture scope | Supplied tracking events preserved another editor's key focus during dwell; deliberate activation focused a real terminal. Escape, reentry, locks, disabled hover, and 200 panel cycles passed. |
| Shipping accessory-mode interaction | PASSED for tested path | Manual click and input reached a real shell; Hide and handle click reopened the same PID `87889`. |
| Physical cross-app hover and global shortcut | NOT_RUN | No physical pointer hover across apps has been qualified. Registration succeeded, but targeted computer-control key input did not prove global delivery; shortcut was disabled afterward. |
| Native mouse selection and clipboard | PASSED for tested path | Drag selection and Command-C/Command-V worked. Multiline confirmation is implemented but unqualified. The native clipboard adapter rejects unsupported terminal read-confirmation requests. |
| Dead-key input | PASSED for tested path | Option-E followed by E entered `é`. Direct computer-control `typeText` lost some Unicode characters; native paste and the engine Unicode fixture succeeded. |
| Non-Latin IME and VoiceOver | NOT_RUN | AppKit text-input and chrome labels exist; full terminal AX text/selection support is missing. A real IME and VoiceOver flow still need work. |
| Intel Mac, macOS before 26 | NOT_RUN | Current build scripts intentionally produce native arm64 and require the macOS 27 SDK. |
| External display, 1× scale, negative origin | NOT_RUN | Geometry model tests pass; physical display tests remain. |
| Spaces, full-screen, Stage Manager, lock, sleep/wake | NOT_RUN | Window and process behavior in these modes remains unqualified. |
| Performance targets | NOT_RUN | Two hundred surface and panel cycles retained identity but supplied no reveal latency, CPU, memory, or long-run measurements. |

The camera cutout contains black hardware pixels, so no app can draw readable text inside it. Knotch now joins a black cap to the measured camera region at the screen edge, with the readable terminal immediately below the safe-area boundary; plain displays use a top-center pill. That placement is implemented; physical notch/display qualification remains open.

The alpha uses the system login shell in a selected directory. A surface `command` string in this Ghostty pin is interpreted by a shell, so arbitrary literal-argument command presets and automatic agent launches are deferred. Only one session exists at a time; tabs and session restoration are absent. Hiding retains the process while the app lives; quitting ends it. The pinned macOS login wrapper can report `0` after a controlled `exit 7`, so the app retains output and labels the exit status unavailable. No real-agent paid requests, credential inspection, global shell changes, or broad permission grants were part of qualification. The shipping app does not log terminal contents by default.

The owner-requested [attachment and auto-minimise correction](decisions/0002-notch-attachment-and-minimise.md) has 17 passing native controller checks. Physical pointer and cross-app tests remain unqualified.

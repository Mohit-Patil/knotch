# Progress

Stage 0 in progress. The original handoff under `notch_terminal_handoff/` is preserved.

1. Inspect tools and pin Ghostty's full native core.
2. Build an ordinary AppKit window with the embedded engine; qualify real PTY, native input, clipboard, Unicode, resize and retained hide/show.
3. Only after that gate: one retained session, nonactivating hover preview, deliberate activation, menu/shortcut, folder selection and confirmed termination.
4. Record each acceptance item honestly; defer multi-session MVP and physical configurations not tested.

Initial environment: macOS 26.6.2 (25G83), arm64 MacBook Air M5, 16 GB, built-in 2560×1664 Retina display. Xcode 27.0 (27A266a), macOS SDK 27.0, Swift 6.4, installed Zig 0.16.0. Claude Code 2.1.281 and Codex CLI 0.154.0 are installed; interactive compatibility is not yet tested.

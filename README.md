# Knotch

A native terminal at the top of your Mac. Powered by Ghostty, with local tabs, SSH connections, and clipboard history.

**Apple Silicon · macOS 26 or later**

## Install

Download **Knotch.zip** from [Releases](https://github.com/Mohit-Patil/knotch/releases/latest), unzip it, and move Knotch to `/Applications` before opening it. Published builds check for updates automatically; **Knotch → Check for Updates…** checks immediately.

## Use

- Click the notch to open; minimise to hide without stopping your terminals. Configure a global shortcut in Settings.
- Use **+** for a local terminal or **Connect to Server…** for SSH. SSH uses macOS's `ssh`, your SSH config, keys, and agent.
- Clipboard history stays on your Mac. Pause capture, pin entries, or clear history from Clipboard. Turn off **Keep history after quitting Knotch** for memory-only history.
- Drag clipboard items into local terminals to insert text or file paths. Dropping does not press Return.

**Know the limits:** quitting ends local sessions and disconnects SSH clients. Tabs do not survive a restart; use `tmux` on remote hosts for persistent work. Local file/image paths cannot be dropped into SSH sessions. Clipboard history is not encrypted—do not use it as a secret store. Updates require restarting Knotch, so finish active work first.

## Build

Requires Xcode 27 with the macOS 27 SDK, Zig 0.16.0, and XcodeGen 2.46 or later.

```sh
./scripts/bootstrap-engine.sh --build
./scripts/build.sh
open .build/app/Build/Products/Release/Knotch.app
```

Source builds do not check the public update feed. Run `scripts/test-models.sh`, `scripts/test-ssh.sh`, and `scripts/test-clipboard-storage.sh` for focused checks; `scripts/build.sh --test` builds the native fixtures. [Release maintenance](docs/releasing.md).

[MIT](LICENSE). Ghostty, Sparkle, bundled fonts, and other dependencies retain their [own licenses](ThirdParty/README.md).

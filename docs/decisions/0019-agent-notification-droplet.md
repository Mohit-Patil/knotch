# Agent notifications beside the notch

The owner asked for an agent-completion indicator that emerges from either side of the notch and stays there. Knotch now handles the pinned Ghostty engine's desktop-notification callback, including OSC 9 and OSC 777 notifications. A nonactivating native panel shows a small black capsule, expanding from the edge facing the notch with a damped SwiftUI spring. Reduce Motion substitutes an opacity fade. The default side is right; Settings provides left/right, enabled, and Preview motion controls.

Notifications remain until clicked, dismissed, their terminal is selected, or that terminal is closed. Clicking opens the originating session through the existing coordinator; it does not launch a new shell. One pending event per terminal is retained, with a count for other pending terminals and a maximum of 20 entries. Repeated identical callbacks are suppressed for two seconds; Ghostty also imposes its own rate limits. Event text is bounded and stripped of controls/bidi formatting, displayed as plain text, and never executed. Notices live only for the current app run.

The indicator is anchored outside the screen's reported camera cutout and clamped to the display bounds. Displays without a notch use the existing top-centre handle as the anchor. Screen-parameter changes reposition it. Arrival does not reveal the main workspace, activate Knotch, or change the first responder. Native dialog presentation temporarily hides it while retaining pending events.

## Detecting agent completion

This implementation uses explicit notification signals, not inactivity, terminal bells, title changes, shell exit or keyword matching. A notification is an agent/program report, not independent verification that its work succeeded. Other terminal programs may emit the same standard notifications.

[Codex's OSC 9 backend](https://github.com/openai/codex/blob/main/codex-rs/tui/src/notifications/osc9.rs) emits through the terminal, and its [backend selection](https://github.com/openai/codex/blob/main/codex-rs/tui/src/notifications/mod.rs) supports Ghostty. Settings can copy a launch command enabling `agent-turn-complete` notifications and selecting OSC 9. Codex's own focus policy still determines when it emits an event.

[Claude Code's Stop hook and terminalSequence output](https://code.claude.com/docs/en/hooks#emit-terminal-notifications) provide a response-end signal. Settings copies `claude --settings …` with a Stop hook that returns an OSC 777 notification in JSON. This is a launch-scoped addition; Knotch does not edit global Claude/Codex settings or overwrite existing hooks. The installed Claude binary contains terminalSequence support. Paste the copied command into a Knotch terminal to start an agent with these settings. Already-running agents cannot gain new launch flags retroactively. Existing agent policies, hook overrides or Ghostty `desktop-notifications = false` may suppress events.

## Qualification

The native Settings suite tests real shell output through Ghostty's OSC 777 and OSC 9 parser to the indicator, source-session mapping, no focus theft, retained shell/surface, click routing, duplicate coalescing, modal suspension, side geometry, sanitization, closed-session pruning and the disabled preference. A plain BEL fixture must not produce a completion event. These fixtures emit known notifications; they do not run a paid agent turn.

`scripts/test-notifications.sh` executes only the generated constant Claude hook and verifies its JSON/escape output and both launch commands' shell quoting. It does not invoke Claude or Codex. The installed UI must additionally be inspected for layout and preview; a screenshot alone does not qualify spring frame pacing. Actual authenticated agent-turn delivery, Reduce Motion on a changed OS setting, physical multiple-monitor rearrangement, VoiceOver and motion performance are not claimed as verified.

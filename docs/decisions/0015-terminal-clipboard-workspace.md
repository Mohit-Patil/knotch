# 0015 — Terminal and Clipboard in one workspace

The owner requested a cohesive interface accommodating both Clipboard and the real terminal. The former exclusive tabs required a mode switch before each saved-item drag.

The terminal now shares its panel with a 174-point bottom Clipboard shelf. Mixed-content cards expose separate Copy and Insert actions and the existing private drag source. Insert targets the selected running session, reuses path escaping and unsafe-paste confirmation, and never adds Return. A small History action opens the complete library; the shelf can be hidden, with that preference saved locally. Short panels hide the shelf automatically so the terminal remains usable. The outer panel size stays the same across all modes.

Scrollable terminal tabs occupy the leading navigation area. Clipboard and Settings remain fixed on the trailing side, with their existing full-panel behavior. Duplicate utility buttons were removed from the header. The full Clipboard library adds counted content filters and uses the same neutral charcoal styling as the shelf. Existing Ghostty configuration continues to control terminal appearance.

`TerminalWorkspaceView` owns layout only. `AppCoordinator.container` remains the same terminal host, and the session store continues to own every surface/process. Shelf visibility changes native bounds once, allowing Ghostty to resize its grid. A brief shelf fade honors Reduce Motion. The shelf source stays mounted during dragging; the existing full-library source retention and opaque backdrop remain in place for cross-tab drags.

Apple's [macOS design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/) informed the configurable workspace, and [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout/) informed yielding secondary content when space is limited. These are design references, not a claim of comprehensive platform or accessibility qualification.

No terminal engine, shell configuration, clipboard retention policy, or agent-launch behavior changed. See the dated workspace follow-up in the acceptance matrix for actual build/test/UI evidence and remaining limitations.

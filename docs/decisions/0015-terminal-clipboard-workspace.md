# 0015 — Terminal and Clipboard in one workspace

The owner requested a cohesive interface accommodating both Clipboard and the real terminal. The former exclusive tabs required a mode switch before each saved-item drag.

The terminal now shares its panel with a 174-point bottom Clipboard shelf. Mixed-content cards expose separate Copy and Insert actions and the existing private drag source. Insert targets the selected running session, reuses path escaping and unsafe-paste confirmation, and never adds Return. A small History action opens the complete library; the shelf can be hidden, with that preference saved locally. Short panels hide the shelf automatically so the terminal remains usable. The outer panel size stays the same across all modes.

Scrollable terminal tabs occupy the leading navigation area. Clipboard and Settings remain fixed on the trailing side, with their existing full-panel behavior. Duplicate utility buttons were removed from the header. The full Clipboard library adds counted content filters and uses the same neutral charcoal styling as the shelf. Existing Ghostty configuration continues to control terminal appearance.

`TerminalWorkspaceView` owns layout only. `AppCoordinator.container` remains the same terminal host, and the session store continues to own every surface/process. Shelf visibility changes native bounds once, allowing Ghostty to resize its grid. A brief shelf fade honors Reduce Motion. The shelf source stays mounted during dragging; the existing full-library source retention and opaque backdrop remain in place for cross-tab drags.

Apple's [macOS design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/) informed the configurable workspace, and [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout/) informed yielding secondary content when space is limited. These are design references, not a claim of comprehensive platform or accessibility qualification.

No terminal engine, shell configuration, clipboard retention policy, or agent-launch behavior changed. See the dated workspace follow-up in the acceptance matrix for actual build/test/UI evidence and remaining limitations.

## Full-image shelf cards — September 26

The owner requested complete photo previews with Copy appearing on hover. Image cards now devote 166×102 points to an aspect-fit image within the existing 174×110-point tile, replacing the former 158×62-point preview and permanent action row. Copy and the conditional Insert action fade over the lower-right corner on hover or keyboard focus without changing card geometry. Non-image cards retain their labelled preview and action row. The native drag view stays mounted beneath the controls and reports hover using a bounded AppKit tracking area. Reduce Motion disables the fade.

Image cards expose named Copy/Insert accessibility actions, plus button-style keyboard focus and Space to copy the focused card. The latter follows Apple's [activation focus interaction](https://developer.apple.com/documentation/swiftui/focusinteractions/activate) and does not automatically move keyboard focus into the shelf on launch. The full Clipboard library is unchanged.

Both builds and 45 existing native Clipboard regression checks passed. Installed UI inspection confirmed larger full-image previews, no permanent image action row, and unchanged text cards. The named accessibility Insert action inserted an image path into Ghostty without Return. Automated pointer gestures and keyboard input did not produce reliable results, so hover reveal, button hit testing, keyboard navigation, and physical drag remain unqualified for this change. Those attempts are not evidence of either a working hover interaction or a diagnosed native tracking failure. The disposable shell was closed without executing the inserted path.

## Shared shelf treatment for every type — September 26

At the owner's request, text, rich text, links, and files now use the same full-card preview and hover/focus action overlay as images. One shared wrapper owns tracking, drag suppression, Copy/Insert, focus, pin badges, and accessibility actions for all types. Text previews use a bounded excerpt and up to four lines; file previews list up to three filenames and a remaining count without opening the files. RTF copy-back, plain-text terminal insertion, file URL copy-back, and escaped terminal paths retain their existing callbacks. The full Clipboard library remains separate.

Both builds and [45 native clipboard checks](../test-results/clipboard-all-card-types.json) passed. Installed UI inspection verified text and image cards without permanent action rows and type-specific accessibility actions. Hover/focus gesture qualification and live link/rich-text/file-card visual checks remain unqualified; the fixture verifies data and session behavior rather than every card's rendered appearance.

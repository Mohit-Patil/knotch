# Technical sources and verification boundaries

**Research date:** September 25, 2026.

These sources support the technical findings in `PRD.md`. The product requirements, numerical budgets, interaction rules, test cases, and proposed module structure are original engineering specifications—not claims made by these sources.

No local macOS application, dependency build, terminal session, or agent was executed during preparation. Main-branch source URLs are research references, not reproducible build pins. Codex must replace a selected dependency with an exact revision in its build record.

## Source index

| ID | Primary reference | What it supports |
|---|---|---|
| S01 | Ghostty repository: `https://github.com/ghostty-org/ghostty` | Current public README distinguishes library scope and notes evolving API signatures. |
| S02 | Ghostty license: `https://raw.githubusercontent.com/ghostty-org/ghostty/main/LICENSE` | Checked top-level MIT license and notice condition. |
| S03 | Native embedder header: `https://raw.githubusercontent.com/ghostty-org/ghostty/main/include/ghostty.h` | Explicit internal-API warning and native runtime/surface interface. |
| S04 | Build entry: `https://raw.githubusercontent.com/ghostty-org/ghostty/main/build.zig` | Separate native-core, VT-library, framework, and resource build paths. |
| S05 | Framework builder: `https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/build/GhosttyXCFramework.zig` | `GhosttyKit` framework construction, matching headers, and native/universal choices. |
| S06 | Build guide: `https://ghostty.org/docs/install/build` | Source build prerequisites and published version/toolchain table. |
| S07 | Build manifest: `https://raw.githubusercontent.com/ghostty-org/ghostty/main/build.zig.zon` | Retrieved main-branch version and compiler requirement. |
| S08 | Development guide: `https://raw.githubusercontent.com/ghostty-org/ghostty/main/HACKING.md` | Revision-sensitive macOS development requirements and input-testing considerations. |
| S09 | Configuration reference: `https://ghostty.org/docs/config/reference` | Command-expansion semantics, clipboard controls, wait-after-command, and scrollback configuration. |
| S10 | Apple screen APIs: `https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets`; `https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea-gr2n`; `https://developer.apple.com/documentation/AppKit/NSScreen/visibleFrame` | Public screen-geometry entry points; indexed auxiliary-area/visible-frame descriptions. |
| S11 | Apple panel APIs: `https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel`; `https://developer.apple.com/documentation/appkit/nswindow/canbecomekey`; `https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate` | Public panel/focus integration points to verify in the target SDK. |
| S12 | Apple collection behavior: `https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces`; `https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary` | Public API entry points for investigating Spaces/full-screen behavior. |
| S13 | Apple tracking-area guide: `https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html` | Tracking areas, pointer entry/exit, cursor events, and geometry updates. |
| S14 | Apple text input: `https://developer.apple.com/documentation/appkit/nstextinputclient` | Native text-input-client contract to inspect in the SDK. |
| S15 | Apple notarization: `https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution` | Official external-distribution notarization workflow entry point. |
| S16 | KeyboardShortcuts: `https://github.com/sindresorhus/KeyboardShortcuts` | Maintainer-documented configurable shortcut recording and registration. |
| S17 | Codex CLI: `https://developers.openai.com/codex/cli/` | Official interactive CLI workflow. The requested URL redirected to OpenAI's ChatGPT Learn documentation during research. |
| S18 | Claude Code: `https://code.claude.com/docs/en/overview` | Official command-line agent workflow and installation entry points. |
| S19 | Claude Code hooks: `https://code.claude.com/docs/en/hooks` | Documented hook/notification mechanism; relevant only to a later integration. |
| S20 | Ghostty shell integration: `https://ghostty.org/docs/features/shell-integration` | Shell-specific integration and resource-path dependencies. |

## Important distinctions

**Current code versus historical roadmap.** Mitchell Hashimoto's September 22, 2025 article, `https://mitchellh.com/writing/libghostty-is-coming`, explains the original direction. It is historical context, not the source of truth for September 2026 API availability. The PRD relies on the currently fetched repository and header for the embedding distinction.

**Toolchain mismatch.** The fetched web guide's tip row said Zig 0.15.2. The fetched main manifest said 0.16.0. Codex must inspect the selected revision's requirements rather than reconcile these by guessing. This also illustrates why a source URL containing `main` is not a build lock.

**Apple documentation retrieval.** Several modern Apple pages returned a JavaScript wrapper with a Markdown link that this research tool could not parse. API identifiers and available indexed summaries were checked; complete signatures, availability, and runtime behavior must be verified in the local SDK and integration tests. The archived tracking-area guide was readable. No full-screen or multi-monitor behavior is asserted as tested.

**License scope.** The top-level Ghostty license does not establish the license of every transitive dependency or asset. Inventory the exact bundled material before distribution.

**Official examples are not our benchmark results.** None of the sources proves this app meets its proposed latency, memory, CPU, international-input, or agent-compatibility targets.

## Dependency record Codex must create

For each actual dependency, record repository/source URL, exact revision or release, archive/artifact checksum where applicable, verified license, build toolchain, target architecture/deployment version, imported source files, resource paths, local changes, and successful build command.

For Ghostty, also record which component is being embedded. “Uses libghostty” is not precise enough; distinguish the full native application's internal embedder from `libghostty-vt`.

# Notch Terminal — Codex handoff

Prepared September 25, 2026.

This package contains a researched, personal-first product/build specification. It does not contain a compiled application or claim successful macOS tests.

## Files

| File | Purpose |
|---|---|
| `PRD.md` | Full product requirements, interaction rules, architecture, lifecycle/security constraints, engineering gates, and implementation sequence. |
| `CODEX_START_HERE.md` | Pasteable implementation brief for Codex. |
| `ACCEPTANCE_TESTS.md` | Test inventory and evidence requirements for the native terminal, focus, sessions, displays, CLIs, privacy, and performance. |
| `SOURCES.md` | Primary technical references, research limitations, and dependency-verification requirements. |

## Use

Copy these files into the chosen project workspace or attach them to Codex. Ask Codex to follow `CODEX_START_HERE.md`. If the repository already has `AGENTS.md` or other instructions, preserve them; this handoff does not replace them.

Start with the engine harness, not the animated island. Ghostty's internal full-core embedder and its public VT library are different integration paths. The exact dependency revision and working toolchain must be verified on the build machine.

The owner's personal-use decision is explicit. Commercial willingness to pay remains unresolved; there is no paywall, model proxy, or cloud service in the MVP.

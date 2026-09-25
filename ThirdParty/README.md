# Native terminal components and notices

This inventory is for the macOS full-core `GhosttyKit` build at Ghostty commit
`982fe90d941e4b4aab4905ffcbcfdea60bd83343` (Zig 0.16.0). The immutable
build inputs and archive checksum are in `ThirdParty/dependency-lock.json`; the manifests
in `.build/ghostty/**/build.zig.zon` supply the package identities below.
`Notices/` contains copied license files and extracted source-header license
blocks from that pinned checkout and its fetched `zig-pkg` dependency trees.
`Notices/Ghostty-LICENSE` was already present
and has not been changed. These notices do not mean every bundled component's
external distribution review is complete.

## What the current app contains

`scripts/build.sh` links the macOS arm64
`GhosttyKit.xcframework/macos-arm64/libghostty-internal.a` into Knotch. This is
Ghostty's full native core, not `libghostty-vt`. The archive includes object
files for FreeType, HarfBuzz, libpng, zlib, Oniguruma, glslang, SPIRV-Cross,
Sentry/Breakpad, simdutf, Highway, gettext/libintl, Dear ImGui/dear_bindings,
stb image, and Wuffs, alongside Ghostty's Zig code. `ar -t` on the pinned
archive confirms the C/C++ object groups. Zig modules such as uucode, libxev,
and zig-objc are build inputs; their use in the final linked app still needs a
link-map audit. macOS frameworks come from the SDK.

The binary embeds JetBrains Mono 2.304 and Nerd Fonts Symbols Only 3.4.0 font
data via `src/build/SharedDeps.zig` and `src/font/embedded.zig`. The app loads the same personal configuration files as Ghostty, falling back to
the pinned engine defaults. Ghostty's other
`src/font/res` fonts are described upstream as test fixtures; this inventory
does not assume all those test fonts survive into the production binary.

The app bundle copies `zig-out/share/ghostty/shell-integration/` and `themes/` from
Ghostty's resource tree, plus `zig-out/share/terminfo/` (including
`xterm-ghostty`), the app's `terminal.conf`, `engine-revision.txt`, this README,
and the available `Notices/` directory. The upstream theme files are bundled from the pinned
`iterm2_themes` dependency (`N-V-__8AAEFmBABuDGOKxAI6VMg41b9euMZ-z7HS9EcUdaor`).
Its MIT notice is copied from iTerm2-Color-Schemes revision `752a9c0` at
https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/752a9c0/LICENSE
to `Notices/iTerm2-Color-Schemes-LICENSE`.

## Notice provenance

| Component or source | Manifest package hash, where applicable | Notice copied here |
| --- | --- | --- |
| Ghostty core, shell integration, terminfo, adapted Swift view | Git commit above | `Ghostty-LICENSE` |
| JetBrains Mono 2.304 | `N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x` | `JetBrainsMono-OFL.txt` |
| Nerd Fonts Symbols Only 3.4.0 | `N-V-__8AAMVLTABmYkLqhZPLXnMl-KyN38R8UVYqGrxqO26s` | `NerdFontsSymbolsOnly-LICENSE`, `NerdFonts-Aggregate-LICENSE` |
| Ghostty font resources (including Noto Emoji fallback and test fixtures) | pinned source `src/font/res` | `GhosttyEmbeddedFonts-README.md`, `GhosttyEmbeddedFonts-OFL.txt`, `GhosttyEmbeddedFonts-MIT.txt`, `GhosttyEmbeddedFonts-BSD-2-Clause.txt` |
| FreeType | `N-V-__8AAKLKpwC4H27Ps_0iL3bPkQb-z6ZVSrB-x_3EEkub` | `FreeType-LICENSE.TXT`, `FreeType-FTL.TXT`, `FreeType-BDF-README`, `FreeType-PCF-README` |
| HarfBuzz | `N-V-__8AAG02ugUcWec-Ndp-i7JTsJ0dgF8nnJRUInkGLG7G` | `HarfBuzz-COPYING` |
| libpng | `N-V-__8AAJrvXQCqAT8Mg9o_tk6m0yf5Fz-gCNEOKLyTSerD` | `libpng-LICENSE` |
| zlib | `N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o` | `zlib-LICENSE` |
| Oniguruma | `N-V-__8AAHjwMQDBXnLq3Q2QhaivE0kE2aD138vtX2Bq1g7c` | `Oniguruma-COPYING` |
| glslang | `N-V-__8AABzkUgISeKGgXAzgtutgJsZc0-kkeqBBscJgMkvy` | `glslang-LICENSE.txt` |
| SPIRV-Cross | `N-V-__8AANb6pwD7O1WG6L5nvD_rNMvnSc9Cpg1ijSlTYywv` | `SPIRVCross-LICENSE`, `SPIRVCross-KhronosFreeUse.txt` |
| Sentry | `N-V-__8AAPlZGwBEa-gxrcypGBZ2R8Bse4JYSfo_ul8i2jlG` | `Sentry-LICENSE` |
| Breakpad | `N-V-__8AALw2uwF_03u4JRkZwRLc3Y9hakkYV7NKRR9-RIZJ` | `Breakpad-LICENSE` |
| Highway | `N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE` | `Highway-LICENSE`, `Highway-LICENSE-BSD3` |
| gettext/libintl | `N-V-__8AADcZkgn4cMhTUpIz6mShCKyqqB-NBtf_S2bHaTC-` | `Gettext-libintl-COPYING.LIB` |
| Dear ImGui | `N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI` | `DearImGui-LICENSE.txt` |
| Wuffs | `N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI` | `Wuffs-LICENSE`, `Wuffs-LICENSE-APACHE`, `Wuffs-LICENSE-MIT` |
| stb image and resize headers | pinned source `src/stb` | `stb-image-and-resize-LICENSE.txt` (license sections copied from both headers) |
| uucode | `uucode-0.2.0-ZZjBPuuFVgC8YZ8eld4fOKsZANLIhTFMzULQxhkLi1C7` | `uucode-LICENSE.md` |
| libxev | `libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F` | `libxev-LICENSE` |
| zig-objc | `zig_objc-0.0.0-Ir_Sp9gsAQCPAJc0oF5xoWePHWP6Y6tCphDeyNUThJoi` | `zig-objc-LICENSE` |

## Adapter support at this revision

`GhosttyRuntime` provides the runtime wakeup/tick, app focus and keyboard-layout
notifications, surface actions, process-close callback, and text/plain system
clipboard callbacks. `GhosttySession` retains the native surface across hide,
handles explicit close and child exit, and owns the surface until confirmed
destruction. `GhosttyNativeView` forwards key press/release/modifiers, AppKit
text composition and preedit, mouse/selection/scroll, focus, scale, display ID,
and copy/paste binding actions. The full-core API is Ghostty's internal
embedder API, so this adapter is revision-bound.

The alpha does not implement selection clipboard, MIME listing, non-text
clipboard contents, non-paste clipboard confirmations, tab/split creation,
inspector, or notification UI. The runtime rejects or declines those requests.
Some metadata actions are acknowledged without lifting them into the
alpha UI. Clipboard reads initiated by terminal programs are denied by the
app-owned configuration; user paste uses the separate text/plain path.

## Before external distribution

1. Inspect the signed bundle's final Resources tree to verify the copied
   `Notices/` inventory and confirm that theme files remain excluded.
2. If themes are bundled later, resolve the `iterm2_themes` archive
   (`N-V-__8AAEFmBABuDGOKxAI6VMg41b9euMZ-z7HS9EcUdaor`): its fetched tree
   contains no license file. Establish applicable notices before distribution.
3. Verify the exact license and reserved-name terms for the embedded Nerd Fonts
   Symbols Only binary. Its archive carries an MIT `LICENSE`, while the pinned
   Nerd Fonts aggregate notice distinguishes font assets from source code and
   describes OFL terms for many fonts. Both original notices are preserved here;
   the relationship to this binary is not resolved by assuming one applies.
4. Complete a source/link-map audit for simdutf's generated vendored source,
   dear_bindings (`N-V-__8AANT61wB--nJ95Gj_ctmzAtcjloZ__hRqNw5lC1Kr`, whose
   fetched archive has no license file), glslang/HarfBuzz file-specific notices,
   and the static gettext/libintl component. The notices above preserve the
   available upstream files but do not settle those component-specific terms
   or distribution steps.

No dependency archives or cache directories are redistributed from this
`ThirdParty/` directory; only the explicitly copied notice texts are present.

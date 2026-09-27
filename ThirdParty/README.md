# Third-party components

Knotch's MIT license covers its own code. The terminal engine, fonts, themes,
and updater retain the licenses in [Notices](Notices/). Those notices are copied
into every app bundle.

The full native GhosttyKit core is pinned in [dependency-lock.json](dependency-lock.json).
`scripts/bootstrap-engine.sh` fetches and verifies that revision and its build
inputs. Source releases include the application, engine source and downloaded
dependency archives so the native core can be rebuilt and relinked.

Sparkle 2.10.0 is distributed under the notices in `Notices/Sparkle-LICENSE`;
`scripts/bootstrap-sparkle.sh` verifies the upstream archive's SHA-256 before use.
Bundled themes come from iTerm2-Color-Schemes revision `752a9c0` and retain its MIT notice.

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

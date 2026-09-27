# Releases

Stable `vX.Y.Z` tags (or publishing a stable GitHub Release) run the release workflow. It builds an Apple Silicon app, signs with Developer ID, notarizes and staples it, uploads the ZIP and rebuildable dependency sources, then advances the signed Sparkle feed on the `updates` branch. Ordinary source pushes and GitHub Packages do not ship app updates.

## One-time setup

Use GitHub Actions secrets in the **release** environment (not repository-wide secrets). The environment accepts only `v*` tags and requires maintainer approval before a job receives credentials:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | Base64-encoded Developer ID Application certificate **and private key** exported as `.p12` |
| `DEVELOPER_ID_PASSWORD` | Password protecting that export |
| `APPLE_API_KEY_ID` | App Store Connect API key ID with notarization access |
| `APPLE_API_ISSUER_ID` | API issuer ID |
| `APPLE_API_PRIVATE_KEY` | Contents of the API key's `.p8` file |
| `SPARKLE_PRIVATE_KEY` | Exported Sparkle Ed25519 private key |

Set repository variable `APPLE_TEAM_ID` to your Apple Developer team ID. Never commit any of these secrets. The workflow uses the `xcode-27` Apple Silicon runner; builds require its macOS 27 SDK.

The existing Sparkle public key is in `project.yml`. Its private counterpart was generated in the maintainer's login Keychain under account `dev.personal.Knotch.updates`. Export it with `.build/sparkle/bin/generate_keys --account dev.personal.Knotch.updates -x <private-file>` and upload the file using `gh secret set SPARKLE_PRIVATE_KEY --env release < <private-file>`. Keep a secure backup, then delete the temporary export. Do not generate a replacement key for each release; installed apps trust this key.

For forks, generate your own Sparkle key, replace `SPARKLE_PUBLIC_KEY`, and change the repository/feed URLs in `project.yml`, `README.md`, and `scripts/release.sh`.

## Ship

Commit the release tree, then push a new version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Approve the release environment deployment in Actions after reviewing the tagged source. The workflow creates a GitHub Release if needed. Never replace an existing version's binaries. The publisher refuses existing assets and equal/older feed versions; if publication fails after asset upload, inspect the artifacts and finish feed publication manually, or ship a new version. Do not rerun blindly or delete valid downloads to bypass these checks.

For a local build, set `APPLE_TEAM_ID`, `NOTARY_PROFILE` (a `notarytool` Keychain profile), and `ZIG_GLOBAL_CACHE_DIR="$PWD/.build/zig-cache"`. Run `scripts/bootstrap-engine.sh --build`, then `scripts/release.sh X.Y.Z`. `--archive-only` verifies a signed export without notarizing or publishing it.

Before the first public release, validate installation on another Mac. For the second release, test **Check for Updates…** from the first installed build, including an active terminal: the update must prompt and quitting must respect session confirmation. A successful build or signature check does not verify the complete installation flow.

Source builds leave the updater disabled. Published builds check automatically but never silently install updates. [Sparkle documentation](https://sparkle-project.org/documentation/).

Signing runs on an ephemeral GitHub-hosted runner. Private files live outside the checkout, are excluded from artifacts, and are removed in an always-run cleanup step. Credential commands suppress output and shell tracing is disabled. GitHub masks configured secrets; maintainers who can change and approve workflows must still be trusted. Never enable secret-bearing diagnostic output.

CI reuses GhosttyKit, its runtime resources, and dependency sources when the pinned inputs and actual Xcode/SDK/Zig versions match. Only a cache miss rebuilds Ghostty or installs Metal tools. App sources always build; superseded checks are canceled automatically. Signing material is never cached.

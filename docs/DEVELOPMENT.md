# Development

## Build

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Zig (the version in `vendor/ghostty/build.zig.zon` → `minimum_zig_version`).

```bash
git clone --recursive https://github.com/CassianFlorin/Waitlight.git
cd Waitlight
scripts/build-ghosttykit.sh      # builds vendor/GhosttyKit.xcframework (~5 min first time)
scripts/fetch-sparkle.sh         # downloads the Sparkle updater framework
xcodegen
open Waitlight.xcodeproj
```

On Xcode 26 and later, the Metal compiler is a separate component. Install it once:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Troubleshooting:

- **Zig's fetch fails.** You might see `400 Bad Request` behind an HTTP proxy, or `hash mismatch` / `DirNotEmpty` on some macOS versions. Prefetch the dependencies with curl (which respects `https_proxy`), then build without Zig's own network access:

  ```bash
  scripts/prefetch-zig-deps.sh
  ZIG_SYSTEM_DIR=vendor/zig-deps/pkg scripts/build-ghosttykit.sh
  ```

- **`hash mismatch` after an interrupted build.** Run `CLEAN=1 scripts/build-ghosttykit.sh`.

## Releasing

- **CI** (`.github/workflows/ci.yml`) builds pull requests (and runs by hand from the Actions tab). Pushes to main are not built, since a release tag runs a full Release build. GhosttyKit is cached by submodule commit and Zig version.
- **Release** (`.github/workflows/release.yml`) runs on a `v*` tag. It builds, signs with Developer ID, notarizes and staples the app and the DMG, then publishes a GitHub Release with the DMG, a ZIP, SHA-256 checksums and `appcast.xml`. The appcast is the in-app update feed, and both it and the ZIP are EdDSA-signed. The version comes from the tag, so `project.yml` doesn't need a bump:

  ```bash
  scripts/package.sh --check 0.5.0      # validates the number, builds nothing
  git tag v0.5.0 origin/main && git push origin v0.5.0
  ```

- **Homebrew cask.** After the GitHub Release is published, the same workflow bumps `version` and `sha256` in `Casks/waitlight.rb` in [CassianFlorin/homebrew-tap](https://github.com/CassianFlorin/homebrew-tap) and pushes `Update waitlight to vX.Y.Z` to its default branch, so `brew install --cask cassianflorin/tap/waitlight` installs the new version. Installed copies update through Sparkle (the cask declares `auto_updates true`). Only the `version` and `sha256` lines are rewritten, so other edits to the cask stay. This needs the `HOMEBREW_TAP_TOKEN` secret. Without it the step prints a notice and is skipped, the release still succeeds, and the cask has to be bumped by hand.
- One-time setup: `scripts/setup-ci-secrets.sh` stores the Developer ID `.p12` and the App Store Connect API key as repository secrets. It prompts for the p12 password and the Issuer ID. `scripts/setup-update-key.sh` creates the update-signing key in your Keychain, stores it as the `SPARKLE_ED_PRIVATE_KEY` secret and writes the public half into `project.yml`. Back that key up: installed copies only accept updates signed with it.
- One-time setup for the cask: create a fine-grained personal access token at GitHub → Settings → Developer settings → Fine-grained tokens. Set **Repository access** to *Only select repositories* → `CassianFlorin/homebrew-tap`, and under **Repository permissions** set **Contents** to *Read and write* (Metadata: read is added automatically). Give it an expiry you will remember to renew. Then store it in this repository with `gh secret set HOMEBREW_TAP_TOKEN --repo CassianFlorin/Waitlight`, which prompts for the value. skill-hub's release uses a secret with the same name and scope, so you can paste the same token if you still have it. Secrets are per repository, so it still has to be set here. `scripts/setup-ci-secrets.sh` lists it too.
- Local release: `NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… scripts/package.sh 0.1.0` puts its output in `build/dist`. Without the notary variables you get signed but `-unnotarized` artifacts, which aren't meant for distribution.

### Version numbers

Versions are `X.Y.Z` (semantic versioning, still in 0.x):

| Change | Bump | Example |
| --- | --- | --- |
| New feature or user-visible behavior change | minor, patch back to 0 | 0.4.0 → 0.5.0 |
| Bug fixes and small tweaks only | patch | 0.4.0 → 0.4.1 |
| Incompatible change to saved workspace/settings, or declaring it stable | major (the first one is 1.0.0) | 0.9.0 → 1.0.0 |

Sparkle decides whether to offer an update by `CFBundleVersion`, which `scripts/package.sh` derives from the version as `X×10000 + Y×100 + Z` (0.4.0 → 400). That makes a few rules hard requirements, and the script refuses versions that break them (the Release workflow checks this before building):

- **Only ever go up.** A version must be newer than every existing `v*` tag, or installed copies never see it.
- **Minor and patch stay below 100.** 0.1.100 would collide with 0.2.0.
- **No suffixes** (`-beta`, `-rc.1`). The suffix is dropped from the build number, so anyone on 0.5.0-beta would never be offered 0.5.0. Ship a test build as a normal patch release instead.

Also:

- Tag only commits that are on `main` (normally the merge commit of the PR).
- Never move or re-create a published tag. If a release is broken, fix it and release the next patch version: the appcast may already have been fetched.

## Claude Code tip

Waitlight already gets Claude Code's status from hooks. If you also want a terminal bell when Claude waits for you (useful outside Waitlight too), run:

```bash
claude config set --global preferredNotifChannel terminal_bell
```

# Development

## Build

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Zig (the version in `vendor/ghostty/build.zig.zon` → `minimum_zig_version`).

```bash
git clone --recursive https://github.com/CassianFlorin/AgentDeck.git
cd AgentDeck
scripts/build-ghosttykit.sh      # builds vendor/GhosttyKit.xcframework (~5 min first time)
scripts/fetch-sparkle.sh         # downloads the Sparkle updater framework
xcodegen
open AgentDeck.xcodeproj
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
  git tag v0.2.0 && git push origin v0.2.0
  ```

- One-time setup: `scripts/setup-ci-secrets.sh` stores the Developer ID `.p12` and the App Store Connect API key as repository secrets. It prompts for the p12 password and the Issuer ID. `scripts/setup-update-key.sh` creates the update-signing key in your Keychain, stores it as the `SPARKLE_ED_PRIVATE_KEY` secret and writes the public half into `project.yml`. Back that key up: installed copies only accept updates signed with it.
- Local release: `NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… scripts/package.sh 0.1.0` puts its output in `build/dist`. Without the notary variables you get signed but `-unnotarized` artifacts, which aren't meant for distribution.

## Claude Code tip

AgentDeck already gets Claude Code's status from hooks. If you also want a terminal bell when Claude waits for you (useful outside AgentDeck too), run:

```bash
claude config set --global preferredNotifChannel terminal_bell
```

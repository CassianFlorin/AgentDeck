#!/usr/bin/env bash
# Download Sparkle (the in-app updater) into vendor/Sparkle:
#   vendor/Sparkle/Sparkle.framework   linked and embedded by project.yml
#   vendor/Sparkle/bin/                generate_keys, sign_update (release tooling)
# curl respects https_proxy. The archive is checked against a pinned sha256
# (GitHub's published asset digest).
set -euo pipefail
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/Sparkle"
if [[ "$(cat "$DEST/.version" 2>/dev/null)" == "$VERSION" ]]; then exit 0; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "==> Downloading Sparkle $VERSION"
curl -fsSL --retry 3 -o "$TMP/sparkle.tar.xz" "$URL"
echo "$SHA256  $TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null \
  || { echo "error: Sparkle archive checksum mismatch"; exit 1; }

mkdir "$TMP/x"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP/x"
rm -rf "$DEST"; mkdir -p "$DEST"
# ditto keeps the framework's symlinks and signatures intact.
ditto "$TMP/x/Sparkle.framework" "$DEST/Sparkle.framework"
ditto "$TMP/x/bin" "$DEST/bin"
echo "$VERSION" > "$DEST/.version"
echo "Sparkle $VERSION -> vendor/Sparkle"

#!/usr/bin/env bash
# Build GhosttyKit.xcframework (libghostty) from the vendor/ghostty submodule
# and stage the runtime resources AgentDeck bundles.
#
#   scripts/build-ghosttykit.sh            # uses `zig` on PATH
#   ZIG=/path/to/zig scripts/build-ghosttykit.sh
#
# Needs Zig >= the `minimum_zig_version` in vendor/ghostty/build.zig.zon.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
ZIG="${ZIG:-zig}"

if [ ! -f "$GHOSTTY/build.zig" ]; then
  git -C "$ROOT" submodule update --init --depth 1 vendor/ghostty
fi

echo "==> zig $("$ZIG" version), ghostty $(git -C "$GHOSTTY" rev-parse --short HEAD)"

# If a previous build was interrupted, zig-pkg/ can hold half-extracted
# packages that then fail with "hash mismatch". Pass CLEAN=1 to wipe it.
if [ "${CLEAN:-0}" = "1" ]; then rm -rf "$GHOSTTY/zig-pkg" "$GHOSTTY/.zig-cache"; fi

# ZIG_SYSTEM_DIR: directory of pre-extracted packages named by their hash
# (see scripts/prefetch-zig-deps.sh). Builds with no network access at all.
SYSTEM_ARGS=()
if [ -n "${ZIG_SYSTEM_DIR:-}" ]; then SYSTEM_ARGS=(--system "$ZIG_SYSTEM_DIR"); fi

(cd "$GHOSTTY" && "$ZIG" build ${SYSTEM_ARGS[@]+"${SYSTEM_ARGS[@]}"} \
  -Demit-docs=false \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  -Doptimize=ReleaseFast)

rm -rf "$ROOT/vendor/GhosttyKit.xcframework" "$ROOT/vendor/ghostty-resources"
cp -R "$GHOSTTY/macos/GhosttyKit.xcframework" "$ROOT/vendor/GhosttyKit.xcframework"
mkdir -p "$ROOT/vendor/ghostty-resources"
cp -R "$GHOSTTY/zig-out/share/ghostty" "$ROOT/vendor/ghostty-resources/ghostty"
cp -R "$GHOSTTY/zig-out/share/terminfo" "$ROOT/vendor/ghostty-resources/terminfo"

echo "==> done: vendor/GhosttyKit.xcframework, vendor/ghostty-resources"

#!/usr/bin/env bash
# Download Ghostty's Zig dependencies with curl and extract them into a
# directory usable by `zig build --system <dir>`.
#
# Why: Zig's built-in fetcher fails behind some HTTP proxies (400 Bad Request),
# and on some macOS versions it mis-extracts packages ("hash mismatch").
# curl respects http(s)_proxy, so all traffic stays on your proxy.
#
#   scripts/prefetch-zig-deps.sh [out-dir]       # default: vendor/zig-deps
#   ZIG_SYSTEM_DIR=vendor/zig-deps/pkg scripts/build-ghosttykit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
OUT="${1:-$ROOT/vendor/zig-deps}"
mkdir -p "$OUT/tarballs" "$OUT/pkg"

grep -ho 'https://deps.files.ghostty.org/[^"]*' "$GHOSTTY/build.zig.zon" "$GHOSTTY"/pkg/*/build.zig.zon \
  | sort -u | while read -r url; do
    f="$OUT/tarballs/$(basename "$url")"
    [ -s "$f" ] || curl -fsSL --retry 3 -o "$f" "$url"
  done

python3 -I - "$GHOSTTY" "$OUT/tarballs" "$OUT/pkg" <<'EOF'
import glob, os, re, shutil, subprocess, sys, tempfile
ghostty, deps, out = sys.argv[1:4]
pairs = {}
for zon in [os.path.join(ghostty, "build.zig.zon")] + glob.glob(os.path.join(ghostty, "pkg/*/build.zig.zon")):
    for m in re.finditer(r'\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"', open(zon).read()):
        pairs[m.group(2)] = m.group(1)
fail = 0
for h, url in sorted(pairs.items()):
    dest = os.path.join(out, h)
    if os.path.isdir(dest):
        continue
    f = os.path.join(deps, os.path.basename(url))
    if not os.path.exists(f):
        print("missing", url); fail += 1; continue
    tmp = tempfile.mkdtemp(dir=out, prefix=".x-")
    if subprocess.run(["tar", "-xf", f, "-C", tmp]).returncode:
        shutil.rmtree(tmp); fail += 1; continue
    entries = os.listdir(tmp)
    single = len(entries) == 1 and os.path.isdir(os.path.join(tmp, entries[0]))
    os.rename(os.path.join(tmp, entries[0]) if single else tmp, dest)
    if single:
        shutil.rmtree(tmp)
print(f"{len(pairs) - fail}/{len(pairs)} packages ready in {out}")
sys.exit(1 if fail else 0)
EOF

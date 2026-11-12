#!/usr/bin/env bash
# Archive → Developer ID sign → notarize → staple → ZIP + DMG.
# The same script runs locally and in CI (.github/workflows/release.yml).
#
#   scripts/package.sh 0.1.0
#   scripts/package.sh --check 0.1.0   # only validate the version number
#
# Needs a "Developer ID Application" identity (with private key) in the keychain.
# Notarization runs when these are set (App Store Connect API key — an Apple ID
# + app-specific password gets stuck on 2FA in CI):
#   NOTARY_KEY_PATH   path to AuthKey_XXXXXXXXXX.p8
#   NOTARY_KEY_ID     the key id
#   NOTARY_ISSUER_ID  the issuer id
# Without them you get signed-but-unnotarized artifacts marked "-unnotarized".
#
# The in-app updater feed (appcast.xml) is written when this is set:
#   SPARKLE_KEY_PATH  EdDSA private key file (scripts/setup-update-key.sh)
# Overrides (forks, and testing updates without touching the real app):
#   SPARKLE_PUBLIC_ED_KEY  instead of project.yml's
#   BUNDLE_ID              instead of com.cassianflorin.agentdeck
#   GITHUB_REPOSITORY      owner/name used for the download URLs in appcast.xml
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
VERSION="${1:?usage: scripts/package.sh [--check] <version>}"

# CFBundleVersion is what Sparkle compares, so it must grow with every
# release and match between local and CI builds: 1.2.3 -> 10203.
# See "Version numbers" in docs/DEVELOPMENT.md for the rules enforced here.
die() { echo "error: $*" >&2; exit 1; }
if [[ "$VERSION" == *-* ]]; then
  die "no pre-release suffixes (got '$VERSION'): the suffix is dropped from the" \
      "build number, so users on the pre-release would never be offered the final release."
fi
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]] \
  || die "version must be X.Y.Z without a leading v, Y and Z in 0-99 (got '$VERSION')."
V_MAJ=${BASH_REMATCH[1]} V_MIN=${BASH_REMATCH[2]} V_PAT=${BASH_REMATCH[3]}
BUILD_NUM=$(( V_MAJ * 10000 + V_MIN * 100 + V_PAT ))

# Must be newer than every other release tag, or installed copies won't update.
# (The tag being built may already exist; it is skipped.)
build_num_of() { local a b c; IFS=. read -r a b c <<< "${1%%-*}"; echo $(( 10#${a:-0} * 10000 + 10#${b:-0} * 100 + 10#${c:-0} )); }
HIGHEST="" HIGHEST_NUM=0
while read -r tag; do
  [ -n "$tag" ] && [ "$tag" != "v$VERSION" ] || continue
  n=$(build_num_of "${tag#v}")
  if [ "$n" -ge "$HIGHEST_NUM" ]; then HIGHEST="$tag" HIGHEST_NUM=$n; fi
done < <(git -C "$(dirname "$0")/.." tag -l 'v[0-9]*' 2>/dev/null)
if [ -n "$HIGHEST" ] && [ "$BUILD_NUM" -le "$HIGHEST_NUM" ]; then
  die "$VERSION (build $BUILD_NUM) is not newer than $HIGHEST (build $HIGHEST_NUM)."
fi
if [ "$CHECK_ONLY" = 1 ]; then
  echo "ok: $VERSION -> build $BUILD_NUM${HIGHEST:+ (latest tag $HIGHEST)}"
  exit 0
fi
TEAM_ID=HU729D6ML5
APP=AgentDeck
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/build/dist"
ARCHIVE="$ROOT/build/$APP.xcarchive"
rm -rf "$OUT" "$ARCHIVE"
mkdir -p "$OUT"

security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)" \
  || { echo "error: no 'Developer ID Application ($TEAM_ID)' identity with a private key in the keychain"; exit 1; }

scripts/fetch-sparkle.sh

if [[ ! -d vendor/GhosttyKit.xcframework || ! -d vendor/ghostty-resources ]]; then
  echo "==> Building GhosttyKit"
  scripts/build-ghosttykit.sh
fi

echo "==> Generating project"
xcodegen generate --quiet

echo "==> Archiving v$VERSION ($BUILD_NUM)"
if ! xcodebuild archive \
  -project "$APP.xcodeproj" -scheme "$APP" -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$ROOT/build/DerivedData-release" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  ${SPARKLE_PUBLIC_ED_KEY:+SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"} \
  ${BUNDLE_ID:+PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"} \
  > "$ROOT/build/archive.log" 2>&1; then
  echo "archive failed; tail of build/archive.log:"; tail -n 40 "$ROOT/build/archive.log"; exit 1
fi

echo "==> Exporting (developer-id)"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" -exportPath "$OUT" \
  > "$ROOT/build/export.log" 2>&1; then
  echo "export failed; tail of build/export.log:"; tail -n 40 "$ROOT/build/export.log"; exit 1
fi

echo "==> Checking signature"
SIG="$(codesign -d --verbose=2 "$OUT/$APP.app" 2>&1)"
echo "$SIG" | grep -E "Authority=Developer ID Application|TeamIdentifier|flags="
# flags only appear with --verbose=2.
echo "$SIG" | grep -q "flags=.*runtime" || { echo "error: hardened runtime not enabled (notarization would fail)"; exit 1; }
echo "$SIG" | grep -q "Authority=Developer ID Application" || { echo "error: not Developer ID signed"; exit 1; }
codesign --verify --deep --strict --verbose=1 "$OUT/$APP.app"
# The ghostty CLI entry point must survive export as a symlink to ourselves.
[[ "$(readlink "$OUT/$APP.app/Contents/MacOS/ghostty")" == "$APP" ]] \
  || { echo "error: Contents/MacOS/ghostty symlink missing"; exit 1; }

NOTARIZE=1
if [[ -z "${NOTARY_KEY_PATH:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARIZE=0
  echo "!! No notarization credentials: artifacts are signed but NOT notarized."
  echo "!! Gatekeeper will block them on other Macs. Don't publish these."
fi
notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait --timeout 60m
}

if [[ "$NOTARIZE" == 1 ]]; then
  # Notarize and staple the .app itself, so it also opens offline after
  # being dragged out of the DMG.
  echo "==> Notarizing app"
  ditto -c -k --keepParent "$OUT/$APP.app" "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm -f "$OUT/notarize.zip"
  xcrun stapler staple "$OUT/$APP.app"
fi

SUFFIX=""; [[ "$NOTARIZE" == 1 ]] || SUFFIX="-unnotarized"

echo "==> ZIP"
ditto -c -k --keepParent "$OUT/$APP.app" "$OUT/$APP-$VERSION$SUFFIX.zip"

if [[ -n "${SPARKLE_KEY_PATH:-}" ]]; then
  echo "==> appcast.xml (Sparkle)"
  [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$OUT/$APP.app/Contents/Info.plist" 2>/dev/null)" ]] \
    || { echo "error: SPARKLE_PUBLIC_ED_KEY is empty in project.yml (run scripts/setup-update-key.sh)"; exit 1; }
  ZIP="$APP-$VERSION$SUFFIX.zip"
  # Prints: sparkle:edSignature="…" length="…"
  ED_SIG="$(vendor/Sparkle/bin/sign_update --ed-key-file "$SPARKLE_KEY_PATH" "$OUT/$ZIP")"
  [[ "$ED_SIG" == *edSignature=* ]] || { echo "error: sign_update failed"; exit 1; }
  PREV_TAG="$(git describe --tags --abbrev=0 --match 'v*' HEAD^ 2>/dev/null || true)"
  CHANGES="$(git log --no-merges --format=%s ${PREV_TAG:+"$PREV_TAG..HEAD"} | head -n 30)"
  REPO_URL="https://github.com/${GITHUB_REPOSITORY:-CassianFlorin/AgentDeck}"
  VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" ED_SIG="$ED_SIG" CHANGES="$CHANGES" \
  REPO_URL="$REPO_URL" ZIP="$ZIP" python3 - > "$OUT/appcast.xml" <<'PY'
import os, html
from email.utils import formatdate
e = os.environ
v, repo = e["VERSION"], e["REPO_URL"]
items = "".join(f"<li>{html.escape(l)}</li>" for l in e["CHANGES"].splitlines() if l.strip())
notes = f"<h3>AgentDeck {v}</h3><ul>{items}</ul>" \
        f'<p><a href="{repo}/releases/tag/v{v}">完整更新说明</a></p>'
print(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AgentDeck</title>
    <item>
      <title>AgentDeck {v}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{e["BUILD_NUM"]}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{repo}/releases/tag/v{v}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{repo}/releases/download/v{v}/{e["ZIP"]}" type="application/octet-stream" {e["ED_SIG"]}/>
    </item>
  </channel>
</rss>''')
PY
  xmllint --noout "$OUT/appcast.xml"
  # Embeds a signature in the feed itself (Info.plist SURequireSignedFeed).
  vendor/Sparkle/bin/sign_update --ed-key-file "$SPARKLE_KEY_PATH" "$OUT/appcast.xml"
  vendor/Sparkle/bin/sign_update --ed-key-file "$SPARKLE_KEY_PATH" --verify "$OUT/appcast.xml" >/dev/null
fi

echo "==> DMG"
STAGE="$OUT/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$OUT/$APP.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$APP-$VERSION$SUFFIX.dmg"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
IDENTITY="$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: [^\"]*($TEAM_ID)\"" | head -1 | tr -d '"')"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ "$NOTARIZE" == 1 ]]; then
  echo "==> Notarizing DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "==> Gatekeeper check"
  spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | tail -3
  spctl -a -vvv -t execute "$OUT/$APP.app" 2>&1 | tail -3
  # validate talks to Apple; flaky networks in CI shouldn't fail an otherwise good release.
  for i in 1 2 3; do xcrun stapler validate "$DMG" && break; [[ $i == 3 ]] && exit 1; sleep 10; done
fi

(cd "$OUT" && shasum -a 256 "$APP-$VERSION$SUFFIX".{dmg,zip} > "$APP-$VERSION$SUFFIX.sha256")
echo
echo "Artifacts in build/dist:"
/bin/ls -1 "$OUT" | grep -v "^$APP.app$" | sed 's/^/  /'

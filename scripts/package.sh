#!/usr/bin/env bash
# Archive → Developer ID sign → notarize → staple → ZIP + DMG.
# The same script runs locally and in CI (.github/workflows/release.yml).
#
#   scripts/package.sh 0.1.0
#
# Needs a "Developer ID Application" identity (with private key) in the keychain.
# Notarization runs when these are set (App Store Connect API key — an Apple ID
# + app-specific password gets stuck on 2FA in CI):
#   NOTARY_KEY_PATH   path to AuthKey_XXXXXXXXXX.p8
#   NOTARY_KEY_ID     the key id
#   NOTARY_ISSUER_ID  the issuer id
# Without them you get signed-but-unnotarized artifacts marked "-unnotarized".
set -euo pipefail

VERSION="${1:?usage: scripts/package.sh <version>}"
BUILD_NUM="${GITHUB_RUN_NUMBER:-$(date +%y%m%d%H%M)}"
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

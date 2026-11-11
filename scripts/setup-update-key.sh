#!/usr/bin/env bash
# One-time: create the EdDSA key that signs in-app updates (Sparkle).
#
#   scripts/setup-update-key.sh
#
# - The private key is created in (or reused from) your login Keychain under
#   the account "agentdeck", then stored as the SPARKLE_ED_PRIVATE_KEY repo
#   secret. The temporary export is deleted.
# - The public key is written into project.yml (SPARKLE_PUBLIC_ED_KEY); commit it.
#
# Keep the Keychain item (or a backup of it): installed copies only accept
# updates signed by this key. Losing it means everyone has to download the
# next version by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "need gh: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login"; exit 1; }
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Repository: $REPO"

scripts/fetch-sparkle.sh
BIN=vendor/Sparkle/bin
ACCOUNT=agentdeck

CURRENT="$(sed -n 's/^ *SPARKLE_PUBLIC_ED_KEY: *"\(.*\)"/\1/p' project.yml)"

echo "Creating or reusing the key in your Keychain (allow access if macOS asks)…"
"$BIN/generate_keys" --account "$ACCOUNT" >/dev/null
PUB="$("$BIN/generate_keys" --account "$ACCOUNT" -p)"
[[ -n "$PUB" ]] || { echo "could not read the public key"; exit 1; }

if [[ -n "$CURRENT" && "$CURRENT" != "$PUB" ]]; then
  echo "project.yml already has a different public key:"
  echo "  $CURRENT"
  echo "Replacing it would stop installed copies from accepting updates. Aborting."
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$BIN/generate_keys" --account "$ACCOUNT" -x "$TMP/key" >/dev/null
gh secret set SPARKLE_ED_PRIVATE_KEY --repo "$REPO" < "$TMP/key"

sed -i '' "s|^\( *SPARKLE_PUBLIC_ED_KEY:\) *\".*\"|\1 \"$PUB\"|" project.yml
grep -q "SPARKLE_PUBLIC_ED_KEY: \"$PUB\"" project.yml || { echo "failed to update project.yml"; exit 1; }

echo
echo "Public key (now in project.yml): $PUB"
echo "Secret SPARKLE_ED_PRIVATE_KEY set on $REPO."
echo "Back up the Keychain item \"$ACCOUNT\" (Keychain Access → search 'Private key for signing Sparkle updates')."

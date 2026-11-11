#!/usr/bin/env bash
# One-time: store the release signing / notarization secrets in the GitHub repo.
# Run it yourself in a terminal — it asks for the p12 password and the Issuer ID.
#
#   scripts/setup-ci-secrets.sh [path/to/DeveloperID.p12] [path/to/AuthKey_XXXXXXXXXX.p8]
#
# Secrets written (used by .github/workflows/release.yml):
#   CERT_P12_BASE64, CERT_P12_PASSWORD     Developer ID Application cert + private key
#   NOTARY_KEY_P8, NOTARY_KEY_ID, NOTARY_ISSUER_ID   App Store Connect API key
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "need gh: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login"; exit 1; }
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Repository: $REPO"

P12="${1:-$HOME/.developer-id/DeveloperID.p12}"
[[ -f "$P12" ]] || { echo "p12 not found: $P12"; exit 1; }
P8="${2:-$(/bin/ls "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1)}"
[[ -f "$P8" ]] || { echo "App Store Connect key (.p8) not found; pass its path as the 2nd argument"; exit 1; }
KEY_ID="$(basename "$P8" .p8)"; KEY_ID="${KEY_ID#AuthKey_}"

read -rsp "Password of $(basename "$P12"): " P12_PASS; echo
# Fail early on a wrong password instead of in CI.
export P12_PASS   # read by openssl via env:, never on the command line
openssl pkcs12 -in "$P12" -passin env:P12_PASS -nokeys -legacy >/dev/null 2>&1 \
  || openssl pkcs12 -in "$P12" -passin env:P12_PASS -nokeys >/dev/null 2>&1 \
  || { echo "wrong password (or not a p12)"; exit 1; }
read -rp "App Store Connect Issuer ID (UUID, Users and Access → Integrations): " ISSUER
[[ "$ISSUER" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "that doesn't look like an Issuer ID"; exit 1; }

echo "Checking the API key with Apple (notarytool history)…"
xcrun notarytool history --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER" >/dev/null \
  || { echo "Apple rejected the key / key id / issuer combination"; exit 1; }

base64 -i "$P12" | gh secret set CERT_P12_BASE64 --repo "$REPO"
printf '%s' "$P12_PASS" | gh secret set CERT_P12_PASSWORD --repo "$REPO"
gh secret set NOTARY_KEY_P8 --repo "$REPO" < "$P8"
printf '%s' "$KEY_ID" | gh secret set NOTARY_KEY_ID --repo "$REPO"
printf '%s' "$ISSUER" | gh secret set NOTARY_ISSUER_ID --repo "$REPO"
unset P12_PASS

echo; gh secret list --repo "$REPO"
echo "Done. Release with: git tag v0.1.0 && git push origin v0.1.0"

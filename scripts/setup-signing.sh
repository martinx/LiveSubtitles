#!/bin/bash
#
# One-command signing setup: asks Apple for a Developer ID certificate, then installs
# everything GitHub Actions and this Mac need to sign and notarise releases.
#
#   scripts/setup-signing.sh AuthKey_XXXXXXXXXX.p8
#
# The only manual step is creating the API key:
#   appstoreconnect.apple.com -> Users and Access -> Integrations ->
#   App Store Connect API -> "+"   (role: Admin, or App Manager)
# Download the .p8 (Apple only offers it once) and note the Key ID; the Issuer ID is
# shown above the key list. Then run this and answer the three prompts.
#
# What it does:
#   1. generates the private key and CSR locally
#   2. asks Apple to issue a "Developer ID Application" certificate for that CSR
#   3. builds a .p12 and imports it into your login keychain, so local builds sign too
#   4. uploads the GitHub Actions secrets
#   5. optionally signs, notarises and staples a build right here to prove it works
#
set -euo pipefail
cd "$(dirname "$0")/.."

P8="${1:-}"
REPO="${REPO:-martinx/LiveSubtitles}"
WORK="build/signing"
P12_PASSWORD="${P12_PASSWORD:-}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\033[1m==>\033[0m %s\n' "$*"; }

[ -n "$P8" ] && [ -f "$P8" ] || die "usage: $0 AuthKey_XXXXXXXXXX.p8"
command -v openssl >/dev/null || die "openssl not found"
command -v gh >/dev/null || die "gh not found on PATH"

read -r -p "App Store Connect Key ID (10 characters): " KEY_ID
read -r -p "App Store Connect Issuer ID (a UUID): "     ISSUER_ID
[ -n "$KEY_ID" ]    || die "a Key ID is required"
[ -n "$ISSUER_ID" ] || die "an Issuer ID is required"

if [ -z "$P12_PASSWORD" ]; then
  printf 'Choose a password for the generated .p12 (stored as a GitHub secret): '
  read -r -s P12_PASSWORD; printf '\n'
fi
[ -n "$P12_PASSWORD" ] || die "an empty password is not supported"

rm -rf "$WORK"; mkdir -p "$WORK"

note "generating the private key and CSR"
openssl ecparam -genkey -name prime256v1 -noout -out "$WORK/key.pem" 2>/dev/null
openssl req -new -key "$WORK/key.pem" -out "$WORK/csr.pem" \
  -subj "/CN=Live Subtitles Developer ID/O=LiveSubtitles" 2>/dev/null

note "minting an API token"
JWT="$(python3 scripts/appstore-jwt.py "$P8" "$KEY_ID" "$ISSUER_ID")" || die "could not sign the API token"

note "asking Apple for a Developer ID Application certificate"
python3 - "$WORK/csr.pem" > "$WORK/request.json" <<'PY'
import json, sys
csr = open(sys.argv[1]).read()
print(json.dumps({"data": {"type": "certificates", "attributes": {
    "certificateType": "DEVELOPER_ID_APPLICATION",
    "csrContent": csr,
}}}))
PY

HTTP_BODY="$WORK/response.json"
CODE="$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
  -X POST "https://api.appstoreconnect.apple.com/v1/certificates" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  --data-binary "@$WORK/request.json")"

if [ "$CODE" != "201" ]; then
  echo "Apple refused the request (HTTP $CODE):"
  python3 -c "import json,sys;d=json.load(open('$HTTP_BODY'));[print('  ', e.get('title'), '-', e.get('detail')) for e in d.get('errors',[])]" 2>/dev/null \
    || cat "$HTTP_BODY"
  cat >&2 <<'MSG'

If this says the API key is not allowed, the key needs the Admin or App Manager role.
If a Developer ID certificate already exists and you still hold its private key, you do
not need this script: export that identity from Keychain Access and use
scripts/make-signing-secrets.sh instead.
MSG
  exit 1
fi

note "assembling the identity"
python3 -c "
import json, base64, sys
d = json.load(open('$HTTP_BODY'))['data']
print('    certificate:', d['attributes'].get('displayName', d['id']))
open('$WORK/cert.der','wb').write(base64.b64decode(d['attributes']['certificateContent']))
"
openssl x509 -inform DER -in "$WORK/cert.der" -out "$WORK/cert.pem"
TEAM_ID="$(openssl x509 -in "$WORK/cert.pem" -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
[ -n "$TEAM_ID" ] || die "could not read the Team ID from the issued certificate"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "Developer ID Application" -out "$WORK/DeveloperID.p12" \
  -passout "pass:$P12_PASSWORD"
echo "    team id: $TEAM_ID"

note "importing into your login keychain (so local builds sign with it too)"
security import "$WORK/DeveloperID.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null || \
  echo "    (import skipped - you can do it later by double-clicking the .p12)"

note "uploading GitHub secrets to $REPO"
openssl base64 -A -in "$WORK/DeveloperID.p12" | gh secret set APPLE_CERTIFICATE_BASE64 --repo "$REPO"
gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$REPO" --body "$P12_PASSWORD"
openssl base64 -A -in "$P8"                | gh secret set APPLE_API_KEY_P8 --repo "$REPO"
gh secret set APPLE_API_KEY_ID      --repo "$REPO" --body "$KEY_ID"
gh secret set APPLE_API_ISSUER_ID   --repo "$REPO" --body "$ISSUER_ID"
gh secret set APPLE_TEAM_ID         --repo "$REPO" --body "$TEAM_ID"
gh secret list --repo "$REPO" | sed 's/^/    /'

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || die "the certificate was issued but is not usable yet; open Keychain Access and check it"

cat <<MSG

Set up. Local identity: $IDENTITY

Two ways to prove the whole chain works before releasing:

  # here, on this Mac
  CODESIGN_IDENTITY="$IDENTITY" make build && make package
  xcrun notarytool submit build/LiveSubtitles.zip --key "$P8" --key-id "$KEY_ID" \\
      --issuer "$ISSUER_ID" --wait
  xcrun stapler staple build/LiveSubtitles.app

  # or in CI, without publishing anything
  gh workflow run release.yml -f tag=v0.1.2 -f dry_run=true
MSG

#!/bin/bash
#
# Installs the GitHub Actions secrets that make releases signed and notarised.
#
#   scripts/make-signing-secrets.sh DeveloperID.p12 AuthKey_XXXXXXXXXX.p8
#
# Prerequisites
# -------------
# 1. A "Developer ID Application" certificate in your login keychain:
#      Xcode -> Settings -> Accounts -> your team -> Manage Certificates -> "+" ->
#      Developer ID Application
#    then export it with its private key:
#      Keychain Access -> login -> My Certificates -> right-click the
#      "Developer ID Application: ..." row -> Export... -> .p12, and set a password.
#
# 2. An App Store Connect API key allowed to notarise:
#      appstoreconnect.apple.com -> Users and Access -> Integrations ->
#      App Store Connect API -> "+".  Role "Developer" or higher.
#    Download the .p8 (Apple only lets you download it once) and note the Key ID.
#    The Issuer ID is shown above the key list.
#
set -euo pipefail

P12="${1:-}"
P8="${2:-}"
REPO="${REPO:-martinx/LiveSubtitles}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -n "$P12" ] && [ -n "$P8" ] || die "usage: $0 <DeveloperID.p12> <AuthKey_XXXXXXXXXX.p8>"
[ -f "$P12" ] || die "no such file: $P12"
[ -f "$P8" ]  || die "no such file: $P8"
command -v gh >/dev/null || die "gh is not on PATH"
command -v openssl >/dev/null || die "openssl is not on PATH"

printf 'Password for the .p12 export: '
read -r -s P12_PASSWORD
printf '\n'
[ -n "$P12_PASSWORD" ] || die "an empty password is not supported"

echo "==> reading the certificate"
SUBJECT="$(openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nokeys -clcerts 2>/dev/null \
           | openssl x509 -noout -subject 2>/dev/null || true)"
[ -n "$SUBJECT" ] || die "could not open the .p12 - wrong password?"
echo "    $SUBJECT"

case "$SUBJECT" in
  *"Developer ID Application"*) ;;
  *) die "not a 'Developer ID Application' certificate; notarisation would be rejected" ;;
esac

TEAM_ID="$(printf '%s' "$SUBJECT" | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
[ -n "$TEAM_ID" ] || die "could not read the Team ID out of the certificate subject"
echo "    team id: $TEAM_ID"

read -r -p "App Store Connect Key ID (10 characters): " KEY_ID
read -r -p "App Store Connect Issuer ID (a UUID): "     ISSUER_ID
[ -n "$KEY_ID" ]    || die "a Key ID is required"
[ -n "$ISSUER_ID" ] || die "an Issuer ID is required"

echo
echo "==> uploading five secrets to $REPO"
openssl base64 -A -in "$P12" | gh secret set APPLE_CERTIFICATE_BASE64 --repo "$REPO"
gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$REPO" --body "$P12_PASSWORD"
openssl base64 -A -in "$P8"  | gh secret set APPLE_API_KEY_P8 --repo "$REPO"
gh secret set APPLE_API_KEY_ID        --repo "$REPO" --body "$KEY_ID"
gh secret set APPLE_API_ISSUER_ID     --repo "$REPO" --body "$ISSUER_ID"
gh secret set APPLE_TEAM_ID           --repo "$REPO" --body "$TEAM_ID"

echo
echo "==> secrets in place:"
gh secret list --repo "$REPO"
echo
echo "Next: try the signing path without publishing anything:"
echo "    gh workflow run release.yml --repo $REPO -f tag=v0.1.2 -f dry_run=true"

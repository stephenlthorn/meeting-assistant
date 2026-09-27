#!/bin/bash
# Stores the Developer ID signing and notarization secrets that the release
# workflow uses in this repository's GitHub Actions secrets.
#
# Usage: scripts/setup-release-signing.sh path/to/DeveloperID.p12
#
# Export the .p12 from Keychain Access (My Certificates > "Developer ID
# Application: ..." > Export). Create the app-specific password at
# appleid.apple.com under Sign-In and Security.
set -euo pipefail

P12="${1:?Usage: $0 path/to/DeveloperID.p12}"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }
[ -f "$P12" ] || { echo "No such file: $P12" >&2; exit 1; }

read -rsp "Password for $P12: " P12_PASSWORD; echo
read -rp "Signing identity (e.g. Developer ID Application: Your Name (TEAMID)): " IDENTITY
read -rp "Apple ID email (for notarization): " APPLE_ID
read -rp "Team ID: " TEAM_ID
read -rsp "App-specific password: " APP_PASSWORD; echo

base64 -i "$P12" | gh secret set MACOS_CERTIFICATE_P12
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PASSWORD
printf '%s' "$IDENTITY" | gh secret set MACOS_SIGNING_IDENTITY
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID
printf '%s' "$TEAM_ID" | gh secret set APPLE_TEAM_ID
printf '%s' "$APP_PASSWORD" | gh secret set APPLE_APP_PASSWORD

echo "Done. Bump VERSION on main to publish a signed, notarized release."

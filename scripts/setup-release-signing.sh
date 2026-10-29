#!/bin/bash
# Stores the Developer ID signing and notarization secrets that the release
# workflow uses in the "release" environment of this project's GitHub repository.
#
# Usage: scripts/setup-release-signing.sh [--repo OWNER/NAME] path/to/DeveloperID.p12
#
# The target repository comes from the origin remote of the checkout this script
# lives in (not from the directory you run it in), or from --repo. It is shown and
# must be confirmed before anything is written, so the secrets cannot land in the
# wrong repository. Secrets go into the "release" environment so that only the
# release job can read them; restrict that environment to the main branch in
# Settings > Environments.
#
# Export the .p12 from Keychain Access (My Certificates > "Developer ID
# Application: ..." > Export). Create the app-specific password at
# appleid.apple.com under Sign-In and Security. Never commit the .p12.
set -euo pipefail

usage() { echo "Usage: $0 [--repo OWNER/NAME] path/to/DeveloperID.p12" >&2; exit 1; }

REPO=""
P12=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$P12" ] || usage; P12="$1"; shift ;;
  esac
done
[ -n "$P12" ] || usage

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }
[ -f "$P12" ] || { echo "No such file: $P12" >&2; exit 1; }
P12="$(cd "$(dirname "$P12")" && pwd)/$(basename "$P12")"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -z "$REPO" ]; then
  ORIGIN="$(git remote get-url origin 2>/dev/null)" || { echo "This checkout has no origin remote; pass --repo OWNER/NAME" >&2; exit 1; }
  REPO="$(printf '%s' "${ORIGIN%.git}" | sed -nE 's#^(https://([^/@]+@)?github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+/[^/]+)/?$#\3#p')"
  [ -n "$REPO" ] || { echo "origin ($ORIGIN) is not a github.com repository; pass --repo OWNER/NAME" >&2; exit 1; }
fi
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || { echo "--repo must look like OWNER/NAME" >&2; exit 1; }

echo "Target repository: $REPO (environment: release)"
read -rp "Write the signing secrets to $REPO? [y/N] " CONFIRM || CONFIRM=""
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "Aborted. Nothing was written." >&2; exit 1 ;;
esac

read -rsp "Password for $P12: " P12_PASSWORD; echo
read -rp "Signing identity (e.g. Developer ID Application: Your Name (TEAMID)): " IDENTITY
read -rp "Apple ID email (for notarization): " APPLE_ID
read -rp "Team ID: " TEAM_ID
read -rsp "App-specific password: " APP_PASSWORD; echo

# Only creates the environment when it is missing: updating an existing one could
# reset the protection rules you configured on it.
gh api "repos/$REPO/environments/release" >/dev/null 2>&1 \
  || gh api --method PUT "repos/$REPO/environments/release" >/dev/null

base64 -i "$P12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPO" --env release
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO" --env release
printf '%s' "$IDENTITY" | gh secret set MACOS_SIGNING_IDENTITY --repo "$REPO" --env release
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID --repo "$REPO" --env release
printf '%s' "$TEAM_ID" | gh secret set APPLE_TEAM_ID --repo "$REPO" --env release
printf '%s' "$APP_PASSWORD" | gh secret set APPLE_APP_PASSWORD --repo "$REPO" --env release

echo "Done. Bump VERSION on main to publish a signed, notarized release."
echo "Next: in $REPO > Settings > Environments > release, limit deployment branches to main."

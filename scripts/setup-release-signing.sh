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
# release job can read them. The environment's branch policy, not the workflow, is what
# keeps a build of another branch from reading them: a missing environment is created
# limited to main, and an existing one is left exactly as configured.
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

# The environment is checked before anything is typed, so a GitHub hiccup wastes no
# answers. Only a genuine 404 creates it: updating one that exists would reset the
# reviewers and branch policy configured on it, and an error such as a 502 says nothing
# about whether it exists. Created, it accepts deployments from main only, and that
# policy is in place before any secret is.
ENV_URL="repos/$REPO/environments/release"
LOOKUP_STATUS=0
LOOKUP_ERROR="$(gh api "$ENV_URL" 2>&1 >/dev/null)" || LOOKUP_STATUS=$?
if [ "$LOOKUP_STATUS" -eq 0 ]; then
  CREATED=false
elif printf '%s\n' "$LOOKUP_ERROR" | grep -Eq '\(HTTP 404\)[[:space:]]*$'; then
  gh api --method PUT "$ENV_URL" \
    -F 'deployment_branch_policy[protected_branches]=false' \
    -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null
  gh api --method POST "$ENV_URL/deployment-branch-policies" -f name=main -f type=branch >/dev/null \
    || { echo "Created the release environment but could not limit it to main. No secret was written; add the main branch policy in Settings > Environments > release, then run this again." >&2; exit 1; }
  CREATED=true
else
  echo "Could not check whether the release environment exists, so nothing was written: ${LOOKUP_ERROR:-gh exited with status $LOOKUP_STATUS}" >&2
  exit 1
fi

read -rsp "Password for $P12: " P12_PASSWORD; echo
read -rp "Signing identity (e.g. Developer ID Application: Your Name (TEAMID)): " IDENTITY
read -rp "Apple ID email (for notarization): " APPLE_ID
read -rp "Team ID: " TEAM_ID
read -rsp "App-specific password: " APP_PASSWORD; echo

base64 -i "$P12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPO" --env release
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO" --env release
printf '%s' "$IDENTITY" | gh secret set MACOS_SIGNING_IDENTITY --repo "$REPO" --env release
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID --repo "$REPO" --env release
printf '%s' "$TEAM_ID" | gh secret set APPLE_TEAM_ID --repo "$REPO" --env release
printf '%s' "$APP_PASSWORD" | gh secret set APPLE_APP_PASSWORD --repo "$REPO" --env release

if [ "$CREATED" = true ]; then
  echo "Done. The release environment only accepts deployments from main. Bump VERSION on main to publish a signed, notarized release."
else
  echo "Done. The release environment already existed, so its protection rules were left as they are."
  echo "Next: in $REPO > Settings > Environments > release, check that deployment branches are limited to main."
fi

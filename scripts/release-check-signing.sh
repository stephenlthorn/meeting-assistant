#!/usr/bin/env bash
# Decides how the release is signed from which secrets are configured.
#
# Usage: HAVE_<SECRET>=true|false ... scripts/release-check-signing.sh
#
# The workflow passes only whether each secret is set (never its value), so this step
# cannot leak them. Signing is all or nothing: every Developer ID and notarization
# secret present means sign and notarize, none means ad-hoc, and anything in between
# fails now rather than after a long build with a release that quietly skipped
# notarization. Writes mode=developer-id|ad-hoc to $GITHUB_OUTPUT (stdout when unset).
set -euo pipefail

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
SECRETS="MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_SIGNING_IDENTITY APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD"

present=0
missing=""
for name in $SECRETS; do
  flag="HAVE_$name"
  if [ "${!flag:-false}" = "true" ]; then
    present=$((present + 1))
  else
    missing="$missing $name"
  fi
done

if [ -z "$missing" ]; then
  echo "mode=developer-id" >> "$OUT"
elif [ "$present" -eq 0 ]; then
  echo "mode=ad-hoc" >> "$OUT"
else
  echo "::error::Release signing is only partly configured. Missing:${missing}. Set all six secrets (scripts/setup-release-signing.sh) for a signed and notarized release, or remove them all for an ad-hoc one."
  exit 1
fi

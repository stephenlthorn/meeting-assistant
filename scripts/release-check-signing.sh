#!/usr/bin/env bash
# Decides how the release is signed from which secrets are configured.
#
# Usage: HAVE_<SECRET>=true|false ... scripts/release-check-signing.sh
#
# The workflow passes only whether each secret is set (never its value), so this step
# cannot leak them. There are three valid configurations, each all-or-nothing:
#   ad-hoc     no secrets
#   signed     MACOS_CERTIFICATE_P12, MACOS_CERTIFICATE_PASSWORD, MACOS_SIGNING_IDENTITY
#              (a stable certificate, such as a self-signed one: permissions survive
#              updates, Gatekeeper still asks on first launch)
#   notarized  all six, the three above plus APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
# Anything else fails now rather than after a long build with a release that quietly
# skipped signing or notarization. Writes mode=ad-hoc|signed|notarized to $GITHUB_OUTPUT
# (stdout when unset).
set -euo pipefail

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
SIGNING="MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_SIGNING_IDENTITY"
NOTARIZATION="APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD"

# Prints the names in $1 that are not set.
missing_from() {
  local name flag
  for name in $1; do
    flag="HAVE_$name"
    [ "${!flag:-false}" = "true" ] || printf ' %s' "$name"
  done
}

missing_signing="$(missing_from "$SIGNING")"
missing_notarization="$(missing_from "$NOTARIZATION")"
signing_count=$(( $(wc -w <<< "$SIGNING") - $(wc -w <<< "$missing_signing") ))
notarization_count=$(( $(wc -w <<< "$NOTARIZATION") - $(wc -w <<< "$missing_notarization") ))

if [ "$signing_count" -eq 0 ] && [ "$notarization_count" -eq 0 ]; then
  echo "mode=ad-hoc" >> "$OUT"
elif [ -z "$missing_signing" ] && [ "$notarization_count" -eq 0 ]; then
  echo "mode=signed" >> "$OUT"
elif [ -z "$missing_signing" ] && [ -z "$missing_notarization" ]; then
  echo "mode=notarized" >> "$OUT"
elif [ "$notarization_count" -gt 0 ]; then
  echo "::error::Release signing is only partly configured. Missing:${missing_signing}${missing_notarization}. Notarization needs all six secrets (scripts/setup-release-signing.sh). For a signed build without notarization set only the three certificate secrets, or remove them all for an ad-hoc one."
  exit 1
else
  echo "::error::Release signing is only partly configured. Missing:${missing_signing}. Set the three certificate secrets for a signed build (scripts/setup-release-signing.sh --signed), all six to notarize as well, or remove them all for an ad-hoc one."
  exit 1
fi

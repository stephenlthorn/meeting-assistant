#!/usr/bin/env bash
# Installs a pinned XcodeGen, so a new XcodeGen release cannot change how the project is
# generated (or what a release ships) without a reviewed change to this file.
#
# Usage: scripts/install-xcodegen.sh [install-dir]
#
# Downloads the release zip over HTTPS, checks it against the SHA-256 below before it is
# unpacked, confirms the binary reports the pinned version, and puts its bin directory on
# $GITHUB_PATH (stdout when unset) for the steps that follow.
#
# To bump XcodeGen: take the version from github.com/yonaskolb/XcodeGen/releases and the
# digest GitHub shows next to xcodegen.zip, change both lines below, and let CI regenerate
# the project with it.
set -euo pipefail

VERSION="2.45.3"
SHA256="0c90f4d28ca57335f9fa78cf5bf6dabfe20a232036dabe36de2eef79cb7c0878"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"

DESTINATION="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodegen-$VERSION}"
PATH_FILE="${GITHUB_PATH:-/dev/stdout}"

fail() { echo "::error::$*"; exit 1; }

mkdir -p "$DESTINATION"
ARCHIVE="$DESTINATION/xcodegen.zip"

curl --fail --silent --show-error --location --retry 3 --output "$ARCHIVE" "$URL" \
  || fail "Could not download XcodeGen $VERSION from $URL"

ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
  rm -f "$ARCHIVE"
  fail "XcodeGen $VERSION does not match its pinned checksum (expected $SHA256, got $ACTUAL). Not unpacking it."
fi

unzip -q "$ARCHIVE" -d "$DESTINATION"
BIN="$DESTINATION/xcodegen/bin"

REPORTED="$("$BIN/xcodegen" --version 2>&1)" || fail "The downloaded xcodegen did not run: $REPORTED"
case "$REPORTED" in
  *"$VERSION"*) ;;
  *) fail "Expected XcodeGen $VERSION but the binary reports: $REPORTED" ;;
esac

echo "$BIN" >> "$PATH_FILE"

#!/usr/bin/env bash
# Resolves the release tag and the version numbers the app is built with.
#
# Usage: scripts/release-resolve-version.sh [path/to/VERSION]
#
# VERSION is the single source of truth. INPUT_TAG is the optional workflow_dispatch
# input; when set it must equal VERSION, so the tag, the release and the version the app
# reports cannot disagree. Writes tag=, marketing= and build= to $GITHUB_OUTPUT (stdout
# when unset) and fails with a ::error:: annotation otherwise.
#
# The build number is major * 1,000,000 + minor * 1,000 + patch, so it rises with every
# release and the same tag always produces the same number. That is why minor and patch
# stop at 999.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${1:-$ROOT/VERSION}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
TAG_PATTERN='^v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'

fail() { echo "::error::$*"; exit 1; }

FILE_TAG="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$FILE_TAG" =~ $TAG_PATTERN ]] || fail "VERSION must look like v1.2.3 (up to 999 per part), found '$FILE_TAG'"

TAG="${INPUT_TAG:-$FILE_TAG}"
[[ "$TAG" =~ $TAG_PATTERN ]] || fail "Tag must look like v1.2.3 (up to 999 per part), found '$TAG'"
[ "$TAG" = "$FILE_TAG" ] || fail "Tag $TAG does not match VERSION ($FILE_TAG). Bump VERSION on main first, or leave the tag input empty."

{
  echo "tag=$TAG"
  echo "marketing=${TAG#v}"
  echo "build=$(( BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 1000 + BASH_REMATCH[3] ))"
} >> "$OUT"

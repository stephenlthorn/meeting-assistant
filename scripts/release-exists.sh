#!/usr/bin/env bash
# Decides whether the release for a tag already exists, so the workflow never rebuilds a
# published release and never attaches a new build to an old tag.
#
# Usage: GH_REPO=OWNER/NAME GH_TOKEN=... scripts/release-exists.sh v1.2.3
#
# Only an explicit "not found" from GitHub means something is absent. A server error, a
# rate limit or an expired token says nothing about the release, so each of those fails
# the job instead of reading as "no release" and rebuilding over a published one. A tag
# that exists without a release (a draft, an interrupted publish) fails too: publishing
# would put this commit's build under an old tag.
#
# Writes exists=true|false to $GITHUB_OUTPUT (stdout when unset). It only reads from GitHub.
set -euo pipefail

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
TAG="${1:-}"
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
TAG_PATTERN='^v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'

fail() { echo "::error::$*"; exit 1; }

[[ "$TAG" =~ $TAG_PATTERN ]] || fail "Expected a release tag like v1.2.3, found '$TAG'"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Set GH_REPO to OWNER/NAME, found '$REPO'"

# Succeeds when GitHub has the thing, returns 1 when GitHub says it is not found, and fails
# the job for any other answer. Only stderr is read: on an error gh also prints the response
# body on stdout, which must not be able to pass for the status line.
lookup() {
  local path="$1" what="$2" error status=0
  error="$(gh api "$path" 2>&1 >/dev/null)" || status=$?
  [ "$status" -ne 0 ] || return 0
  if printf '%s\n' "$error" | grep -Eq '\(HTTP 404\)[[:space:]]*$'; then
    return 1
  fi
  fail "Could not look up $what ($(printf '%s' "${error:-gh exited with status $status}" | tr '\n' ' ')). Not assuming it is missing; re-run the job."
}

if lookup "repos/$REPO/releases/tags/$TAG" "the release for $TAG"; then
  echo "exists=true" >> "$OUT"
  echo "::notice::Release $TAG already exists. Bump VERSION to publish a new one."
  exit 0
fi

if lookup "repos/$REPO/git/ref/tags/$TAG" "the tag $TAG"; then
  fail "Tag $TAG already exists but has no published release (a draft, or an interrupted publish). Publishing now would attach this build to an old tag. Delete the tag or finish its release, or bump VERSION."
fi

echo "exists=false" >> "$OUT"

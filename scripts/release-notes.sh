#!/usr/bin/env bash
# Prints the GitHub release notes for the signing mode and notarization outcome that
# were actually used, so users get the right launch instructions and know what an
# update will and will not ask of them.
#
# Usage: scripts/release-notes.sh <ad-hoc|signed|notarized> <true|false|empty>
#
# The second argument is whether notarization succeeded (the workflow passes the
# notarize step's output, which is empty when the step did not run). Only a
# notarized build may claim it.
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
set -euo pipefail

MODE="${1:?Usage: $0 <ad-hoc|signed|notarized> <notarized>}"
NOTARIZED="${2:-}"

GATEKEEPER_STEPS='Download `MeetingAssistant.app.zip`, then before first launch:

```bash
unzip MeetingAssistant.app.zip
xattr -dr com.apple.quarantine MeetingAssistant.app
open MeetingAssistant.app
```'

case "$MODE:$NOTARIZED" in
  notarized:true)
    echo 'Signed and notarized macOS build of Meeting Assistant. Unzip `MeetingAssistant.app.zip` and open the app. The signature stays the same across releases, so your permissions carry over when you update.'
    ;;
  notarized:*)
    echo "A notarized build must report that notarization succeeded" >&2
    exit 1
    ;;
  signed:true)
    echo "A signed-only build cannot be notarized" >&2
    exit 1
    ;;
  signed:*)
    echo 'Signed macOS build of Meeting Assistant (not notarized).'
    echo
    echo "$GATEKEEPER_STEPS"
    echo
    echo 'macOS Gatekeeper still asks once on first launch, because the app is not notarized. This build is signed with a certificate that stays the same from release to release, so macOS keeps your Screen Recording and Microphone permissions and the Keychain access to your API key when you update. If you are updating from an earlier ad-hoc release, macOS asks one last time.'
    ;;
  ad-hoc:true)
    echo "An ad-hoc signed build cannot be notarized" >&2
    exit 1
    ;;
  ad-hoc:*)
    echo 'Ad-hoc signed macOS build of Meeting Assistant (not notarized).'
    echo
    echo "$GATEKEEPER_STEPS"
    echo
    echo 'macOS asks for Screen Recording and Microphone again after each ad-hoc update. Building from source in Xcode is the smoother path; see the README.'
    ;;
  *)
    echo "Unknown signing mode: $MODE" >&2
    exit 1
    ;;
esac

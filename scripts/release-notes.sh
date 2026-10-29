#!/usr/bin/env bash
# Prints the GitHub release notes for the signing mode and notarization outcome that
# were actually used, so users get the right launch instructions.
#
# Usage: scripts/release-notes.sh <developer-id|ad-hoc> <true|false|empty>
#
# The second argument is whether notarization succeeded (the workflow passes the
# notarize step's output, which is empty when the step did not run).
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
set -euo pipefail

MODE="${1:?Usage: $0 <developer-id|ad-hoc> <notarized>}"
NOTARIZED="${2:-}"

GATEKEEPER_STEPS='Download `MeetingAssistant.app.zip`, then before first launch:

```bash
unzip MeetingAssistant.app.zip
xattr -dr com.apple.quarantine MeetingAssistant.app
open MeetingAssistant.app
```'

case "$MODE:$NOTARIZED" in
  developer-id:true)
    echo 'Signed and notarized macOS build of Meeting Assistant. Unzip `MeetingAssistant.app.zip` and open the app.'
    ;;
  developer-id:*)
    echo 'Developer ID signed macOS build of Meeting Assistant (not notarized).'
    echo
    echo "$GATEKEEPER_STEPS"
    echo
    echo 'macOS Gatekeeper warns about unnotarized apps on first launch. The Developer ID signature keeps the Screen Recording and Microphone permissions across updates.'
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

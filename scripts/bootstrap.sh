#!/usr/bin/env bash
# Generate the Xcode project and open it. Run from anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen not found. Installing with Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required: https://brew.sh" >&2
    exit 1
  fi
  brew install xcodegen
fi

echo "Generating MeetingAssistant.xcodeproj..."
xcodegen generate

echo "Opening in Xcode..."
open MeetingAssistant.xcodeproj

cat <<'NOTE'

Next steps in Xcode:
  1. Select the MeetingAssistant scheme and press Run (Cmd+R).
  2. Grant Screen Recording, Microphone, and Speech Recognition when prompted.
  3. Open Settings (Cmd+,) and paste your Anthropic API key.

NOTE

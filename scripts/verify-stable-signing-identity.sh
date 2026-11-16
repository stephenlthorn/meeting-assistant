#!/usr/bin/env bash
# Proves the property the self-signed identity exists for: two different builds signed
# with the same certificate and bundle identifier get the SAME designated requirement
# (what macOS keys permissions on), while the same builds signed ad-hoc get DIFFERENT ones.
#
# Usage: scripts/verify-stable-signing-identity.sh [--adhoc-only] [--trust]
#
#   --adhoc-only  only check the ad-hoc half (needs no certificate and no trust)
#   --trust       let the check mark its throwaway certificate as trusted for code signing
#                 (user domain, removed again on exit). macOS asks you to approve that with
#                 your password or Touch ID, which is why it is opt-in. Without it, a
#                 self-signed certificate is not trusted, codesign reports "no identity
#                 found", and the signed half is skipped.
#
# Everything happens in a temporary directory and a temporary keychain that is not on the
# search list; the login keychain is never touched. Exit codes: 0 property holds,
# 1 property violated, 77 the signed half could not run here (the ad-hoc half still ran).
# The requirements are printed so a person can read them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="com.example.stable-identity-check"
NAME="Stable Identity Check"
ADHOC_ONLY=false
TRUST=false
for arg in "$@"; do
  case "$arg" in
    --adhoc-only) ADHOC_ONLY=true ;;
    --trust) TRUST=true ;;
    *) echo "Usage: $0 [--adhoc-only] [--trust]" >&2; exit 1 ;;
  esac
done

command -v security >/dev/null && command -v codesign >/dev/null || { echo "security and codesign are required (macOS only)"; exit 77; }

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/check.keychain-db"
TRUSTED_CERT=""
cleanup() {
  [ -z "$TRUSTED_CERT" ] || security remove-trusted-cert "$TRUSTED_CERT" >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Two different executables stand in for two different builds of the app.
cp /bin/echo "$WORK/build-a"; cp /bin/cat "$WORK/build-b"
chmod u+w "$WORK/build-a" "$WORK/build-b"

sign_adhoc() { codesign --force --sign - --identifier "$ID" "$1" >/dev/null 2>&1; }
requirement() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^#* *designated => //p'; }

fail=0

sign_adhoc "$WORK/build-a" && sign_adhoc "$WORK/build-b" || { echo "ad-hoc codesign failed"; exit 77; }
ADHOC_A="$(requirement "$WORK/build-a")"
ADHOC_B="$(requirement "$WORK/build-b")"
echo "ad-hoc build A:      $ADHOC_A"
echo "ad-hoc build B:      $ADHOC_B"
if [ -n "$ADHOC_A" ] && [ "$ADHOC_A" != "$ADHOC_B" ]; then
  echo "OK: ad-hoc builds have different requirements."
else
  echo "FAIL: the ad-hoc builds should have different requirements"; fail=1
fi
[ "$ADHOC_ONLY" = false ] || exit "$fail"

skip() { echo "SKIP the signed half: $1"; exit 77; }

PASSWORD="check-$RANDOM-$RANDOM"
P12_PASSWORD="$PASSWORD" "$HERE/make-self-signed-identity.sh" --name "$NAME" "$WORK/identity" >/dev/null || { echo "could not make the identity"; exit 1; }
CERT="$WORK/identity/MeetingAssistantSelfSigned.cer"

security create-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || skip "cannot create a temporary keychain"
security set-keychain-settings -lut 600 "$KEYCHAIN" >/dev/null 2>&1
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || skip "cannot unlock the temporary keychain"
security import "$WORK/identity/MeetingAssistantSelfSigned.p12" -P "$PASSWORD" -A -f pkcs12 -k "$KEYCHAIN" >/dev/null 2>&1 \
  || skip "cannot import the identity into the temporary keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 \
  || skip "cannot set the key partition list"

if [ "$TRUST" = true ]; then
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT" >/dev/null 2>&1 \
    || skip "macOS did not accept the trust change"
  TRUSTED_CERT="$CERT"
fi

sign_with_identity() { codesign --force --keychain "$KEYCHAIN" --sign "$NAME" --identifier "$ID" "$1" >/dev/null 2>&1; }
sign_with_identity "$WORK/build-a" && sign_with_identity "$WORK/build-b" \
  || skip "codesign cannot use an untrusted self-signed certificate here (pass --trust to approve it for this check)"
REQ_A="$(requirement "$WORK/build-a")"
REQ_B="$(requirement "$WORK/build-b")"
echo "self-signed build A: $REQ_A"
echo "self-signed build B: $REQ_B"

[ -n "$REQ_A" ] || { echo "FAIL: no designated requirement printed for the self-signed build"; fail=1; }
[ "$REQ_A" = "$REQ_B" ] || { echo "FAIL: the self-signed builds have different requirements"; fail=1; }
case "$REQ_A" in *"certificate leaf = H"*) ;; *) echo "FAIL: the requirement is not tied to the certificate"; fail=1 ;; esac

[ "$fail" -eq 0 ] && echo "OK: the self-signed identity gives both builds one requirement; ad-hoc gives each its own."
exit "$fail"

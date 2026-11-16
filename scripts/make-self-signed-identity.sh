#!/usr/bin/env bash
# Creates a self-signed code-signing identity for release builds, so that every release
# is signed by the same certificate.
#
# Usage: scripts/make-self-signed-identity.sh [--name "Common Name"] OUTPUT_DIR
#
# Why: macOS keys Screen Recording, Microphone and Keychain access on the app's
# designated requirement. An ad-hoc signature makes that requirement the code hash,
# which changes with every build, so every update asks again. A certificate makes it
# `identifier "<bundle id>" and certificate leaf = H"<hash>"`, which stays the same for
# every build signed by this certificate. Gatekeeper still blocks the first launch,
# because only Apple's notarization removes that; permissions survive updates.
#
# Writes MeetingAssistantSelfSigned.p12 (password protected) and a public .cer into
# OUTPUT_DIR, and nowhere else: not the keychain, not GitHub. It refuses to overwrite
# either file. The p12 password comes from P12_PASSWORD, or is generated and printed once.
# Keep the .p12 safe: anyone holding it can sign an app that macOS treats as this one.
set -euo pipefail

usage() { echo "Usage: $0 [--name \"Common Name\"] OUTPUT_DIR" >&2; exit 1; }

NAME="Meeting Assistant Self-Signed"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || usage; NAME="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$OUT" ] || usage; OUT="$1"; shift ;;
  esac
done
[ -n "$OUT" ] || usage
# The name ends up in a config file and in a secret, so keep it to plain characters.
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ ]] || { echo "--name may only use letters, digits, spaces, dots, dashes and underscores (64 characters at most)" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

P12="$OUT/MeetingAssistantSelfSigned.p12"
CER="$OUT/MeetingAssistantSelfSigned.cer"
for existing in "$P12" "$CER"; do
  [ ! -e "$existing" ] || { echo "Refusing to overwrite $existing. Choose another directory or move it away." >&2; exit 1; }
done

mkdir -p "$OUT"
# Scratch files live inside OUTPUT_DIR so nothing is written anywhere else.
WORK="$(mktemp -d "$OUT/.identity-work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

GENERATED_PASSWORD=false
if [ -z "${P12_PASSWORD:-}" ]; then
  P12_PASSWORD="$(openssl rand -hex 16)"
  GENERATED_PASSWORD=true
fi

cat > "$WORK/openssl.cnf" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = $NAME
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# 3DES and SHA-1 are what the macOS Keychain can read from a .p12; AES-based files
# made by newer OpenSSL fail to import with a MAC verification error.
P12_PASSWORD="$P12_PASSWORD" openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -passout env:P12_PASSWORD -out "$WORK/identity.p12"
openssl x509 -in "$WORK/cert.pem" -outform DER -out "$WORK/identity.cer"

SHA1="$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//' | tr -d ':')"
(umask 077; cp "$WORK/identity.p12" "$P12")
cp "$WORK/identity.cer" "$CER"

echo "Created:"
echo "  $P12   (private key and certificate, keep it secret)"
echo "  $CER   (public certificate)"
echo
echo "SHA-1:                     $SHA1"
echo "MACOS_SIGNING_IDENTITY:    $NAME"
if [ "$GENERATED_PASSWORD" = true ]; then
  echo "MACOS_CERTIFICATE_PASSWORD: $P12_PASSWORD   (shown once; it is not saved anywhere)"
fi
echo
echo "Next: scripts/setup-release-signing.sh --signed $P12"
echo "Valid for 10 years. Replacing it later gives the app a new identity, and macOS asks for permissions once more."

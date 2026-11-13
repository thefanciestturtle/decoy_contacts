#!/usr/bin/env bash
# Signs a release APK made by tool/build_release.sh with the release key.
#
#   tool/sign_release.sh KEYSTORE dist/decoy_contacts-<version>-unsigned.apk
#
# Run it in a terminal of your own: apksigner asks for the keystore's
# password. It writes dist/decoy_contacts-<version>.apk (next to the
# unsigned one), signed with APK Signature Scheme v2 and v3 (Android 7 and
# newer read v2; v3 would let a later release move to a new key), and
# checks that:
#
# - it is signed with the release key: the certificate's fingerprint is the
#   one in tool/release_certificate.sha256;
# - the signature holds nothing else, such as Google's dependency metadata;
# - apart from the signature it is exactly the unsigned APK, so F-Droid can
#   copy the signature onto its own build of the same source;
# - it names no folder in /home other than the build sandbox's.
#
# If any check fails, nothing is written.
set -euo pipefail

readonly CALLER_DIR="$PWD"
cd "$(dirname "$0")/.."
source tool/check_lib.sh
source tool/release_lib.sh

if (($# != 2)); then
  echo "usage: tool/sign_release.sh KEYSTORE UNSIGNED_APK" >&2
  exit 2
fi
keystore="$(absolute_path "$1" "$CALLER_DIR")"
unsigned="$(absolute_path "$2" "$CALLER_DIR")"

need python3
[[ -f "$keystore" ]] || fail "no keystore at $keystore"
[[ -f "$unsigned" ]] || fail "no APK at $unsigned"
[[ "$unsigned" == *-unsigned.apk ]] ||
  fail "$unsigned isn't named like an unsigned release (…-unsigned.apk)"
signed="${unsigned%-unsigned.apk}.apk"
[[ ! -e "$signed" ]] || fail "$signed already exists; move it away first"
want="$(release_cert_sha256)" || exit 1
apksigner_path >/dev/null || exit 1

if is_signed "$unsigned"; then
  fail "$unsigned is already signed"
fi
apk_check home-paths "$unsigned" || fail "$unsigned names a home folder"

partial="$signed.partial"
trap 'rm -f "$partial" "$partial.idsig"' EXIT
apksigner_ sign --ks "$keystore" \
  --alignment-preserved \
  --v1-signing-enabled false --v2-signing-enabled true \
  --v3-signing-enabled true --v4-signing-enabled false \
  --out "$partial" "$unsigned" ||
  fail "apksigner couldn't sign $unsigned"

verified="$(apksigner_ verify --verbose --print-certs "$partial" 2>&1)" ||
  fail "the signed APK doesn't verify:"$'\n'"$verified"
signers="$(sed -n 's/^Number of signers: //p' <<<"$verified")"
[[ "$signers" == 1 ]] || fail "the signed APK has ${signers:-no} signers, not 1"
got="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<<"$verified")"
[[ "$got" == "$want" ]] ||
  fail "the key in $keystore isn't the release key: its certificate's" \
       "SHA-256 fingerprint is ${got:-unknown}, the release key's is $want" \
       "($RELEASE_CERT_FILE)"
blocks="$(apk_check signature "$partial" | tr '\n' ' ')"
[[ "$blocks" == "v2 v3 padding " || "$blocks" == "v2 v3 " ]] ||
  fail "the signature should have v2 and v3 only, but has: $blocks"
apk_check only-signature-added "$partial" "$unsigned" ||
  fail "signing changed more than the signature"

mv "$partial" "$signed"
echo "== Signed $signed"
sha256sum "$signed"

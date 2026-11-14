#!/usr/bin/env bash
# Signs the release APKs made by tool/build_release.sh with the release key.
#
#   tool/sign_release.sh KEYSTORE UNSIGNED_APK...
#
# e.g. tool/sign_release.sh ~/keys/release.p12 dist/decoy_contacts-2.0.0-*-unsigned.apk
#
# Run it in a terminal of your own: it asks for the keystore's password,
# once for all the APKs. For each dist/decoy_contacts-<version>-<abi>-
# unsigned.apk it writes dist/decoy_contacts-<version>-<abi>.apk (next to
# the unsigned one), signed with APK Signature Scheme v2 and v3 (Android 7
# and newer read v2; v3 would let a later release move to a new key), and
# checks that:
#
# - it is signed with the release key: the certificate's fingerprint is the
#   one in tool/release_certificate.sha256;
# - the signature holds nothing else, such as Google's dependency metadata;
# - apart from the signature it is exactly the unsigned APK, so F-Droid can
#   copy the signature onto its own build of the same source;
# - it names no folder in /home other than the build sandbox's.
#
# If any check fails, for any of the APKs, nothing is written.
set -euo pipefail

readonly CALLER_DIR="$PWD"
cd "$(dirname "$0")/.."
source tool/check_lib.sh
source tool/release_lib.sh

if (($# < 2)); then
  echo "usage: tool/sign_release.sh KEYSTORE UNSIGNED_APK..." >&2
  exit 2
fi
keystore="$(absolute_path "$1" "$CALLER_DIR")"
shift

need python3
[[ -f "$keystore" ]] || fail "no keystore at $keystore"
want="$(release_cert_sha256)" || exit 1
apksigner_path >/dev/null || exit 1

# The APK that signing unsigned APK $1 makes, next to it.
signed_of() {
  echo "${1%-unsigned.apk}.apk"
}

# Each APK to sign; all checked before any is signed.
apks=()
declare -A seen=()
for arg in "$@"; do
  unsigned="$(realpath -s -m "$(absolute_path "$arg" "$CALLER_DIR")")"
  [[ -f "$unsigned" ]] || fail "no APK at $unsigned"
  [[ "$unsigned" == *-unsigned.apk ]] ||
    fail "$unsigned isn't named like an unsigned release (…-unsigned.apk)"
  # The same file, however it is named (another path, a link to it).
  file="$(stat -L -c '%d:%i' "$unsigned")"
  [[ -z "${seen[$file]+set}" ]] ||
    fail "$unsigned is given twice (as ${seen[$file]})"
  seen[$file]="$unsigned"
  signed="$(signed_of "$unsigned")"
  [[ ! -e "$signed" ]] || fail "$signed already exists; move it away first"
  if is_signed "$unsigned"; then
    fail "$unsigned is already signed"
  fi
  check_home_paths "$unsigned"
  apks+=("$unsigned")
done

# They are signed into ….partial files first, and only put into place once
# all of them have passed the checks.
remove_partials() {
  local unsigned signed
  for unsigned in "${apks[@]}"; do
    signed="$(signed_of "$unsigned")"
    rm -f "$signed.partial" "$signed.partial.idsig"
  done
}
trap remove_partials EXIT

# Read here, not by apksigner, so it is asked once; apksigner reads it from
# a pipe (not from its command line or its environment, which other
# programs could see).
# (As typed: IFS= keeps spaces at its ends.)
password=""
IFS= read -rs -p "Keystore password: " password || true
[[ ! -t 0 ]] || echo >&2

# Signs $1 into $2 and checks the result.
sign_one() {
  local unsigned=$1 partial=$2 verified signers got blocks
  # (printf is part of bash: the password is never on a command line.)
  # apksigner then still writes a password prompt of its own, without
  # reading anything: one could take it for a real one and type the
  # password where the screen shows it. It is the only thing it writes to
  # its standard output; errors go to standard error.
  if ! printf '%s\n' "$password" |
       apksigner_ sign --ks "$keystore" --ks-pass stdin \
         "${SIGNING_OPTIONS[@]}" --out "$partial" "$unsigned" >/dev/null; then
    fail "apksigner couldn't sign $unsigned"
  fi

  verified="$(apksigner_ verify --verbose --print-certs "$partial" 2>&1)" ||
    fail "the signed $unsigned doesn't verify:"$'\n'"$verified"
  signers="$(sed -n 's/^Number of signers: //p' <<<"$verified")"
  [[ "$signers" == 1 ]] ||
    fail "the signed $unsigned has ${signers:-no} signers, not 1"
  # Each signer's certificate, once ("Signer #1 certificate SHA-256 digest:"
  # up to build-tools 36, "V3.0 Signer: certificate SHA-256 digest:" from 37).
  got="$(sed -n 's/^.*[Ss]igner.* certificate SHA-256 digest: \([0-9a-f]\{64\}\)$/\1/p' \
    <<<"$verified" | sort -u)"
  [[ "$got" == "$want" ]] ||
    fail "the key in $keystore isn't the release key: its certificate's" \
         "SHA-256 fingerprint is $(paste -sd ' ' <<<"${got:-unknown}")," \
         "the release key's is $want ($RELEASE_CERT_FILE)"
  blocks="$(apk_check signature "$partial")" ||
    fail "couldn't read the signed $unsigned"
  blocks="$(tr '\n' ' ' <<<"$blocks")"
  [[ "$blocks" == "v2 v3 padding " || "$blocks" == "v2 v3 " ]] ||
    fail "the signed $unsigned should have v2 and v3 only, but has: $blocks"
  apk_check only-signature-added "$partial" "$unsigned" ||
    fail "signing $unsigned changed more than the signature"
}

for unsigned in "${apks[@]}"; do
  sign_one "$unsigned" "$(signed_of "$unsigned").partial"
done

# Each into place as a hard link, which, unlike mv, fails if something is
# there by now (say from another run while this one asked for the
# password); then none of them is kept.
placed=()
for unsigned in "${apks[@]}"; do
  signed="$(signed_of "$unsigned")"
  if ! ln "$signed.partial" "$signed" 2>/dev/null; then
    rm -f "${placed[@]}"
    fail "couldn't write $signed (is there one now?); none of the APKs" \
         "was written"
  fi
  placed+=("$signed")
done
for signed in "${placed[@]}"; do
  echo "== Signed $signed"
done
sha256sum "${placed[@]}"

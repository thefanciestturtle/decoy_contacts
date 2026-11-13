#!/usr/bin/env bash
# Makes the release key, once, and writes its certificate's fingerprint to
# tool/release_certificate.sha256.
#
#   tool/make_release_key.sh KEYSTORE
#
# Run it in a terminal of your own: it asks for the keystore's password,
# twice. (keytool wants at least 6 characters; make it long.) If reading
# the certificate fails after the key was made, run it again: with KEYSTORE
# already made and no fingerprint written yet, it only reads the certificate.
#
# Keep the keystore out of the repository, and two copies of it elsewhere,
# with the password kept apart from them: Android installs an update only if
# it is signed with the same key, so without the key there can be no more
# updates, and moving to another key means uninstalling, which also loses
# the app's record of the fake contacts it made.
#
# The certificate is public (anyone can read it from the APK), so it names
# only the app: "CN=Decoy Contacts". RSA 4096, valid for 30 years from
# midnight UTC today. keytool reads the start date in the computer's time
# zone, so it runs in UTC; otherwise the certificate would give that away.
set -euo pipefail

readonly CALLER_DIR="$PWD"
cd "$(dirname "$0")/.."
source tool/check_lib.sh
source tool/release_lib.sh

readonly NAME='CN=Decoy Contacts'
readonly ALIAS=release
readonly DAYS=10950 # 30 years

if (($# != 1)); then
  echo "usage: tool/make_release_key.sh KEYSTORE" >&2
  exit 2
fi
keystore="$(absolute_path "$1" "$CALLER_DIR")"
# Never in the repository, where git could take it in.
case "$(realpath -m "$keystore")/" in
  "$(pwd -P)"/*) fail "$keystore is in the repository; keep the key outside it" ;;
esac

keytool="${JAVA_HOME:+$JAVA_HOME/bin/}keytool"
need "$keytool"
if [[ -s "$RELEASE_CERT_FILE" ]]; then
  fail "$RELEASE_CERT_FILE already holds the release key's fingerprint"
fi

# The password goes to keytool in its environment, which only this user's
# own processes can read (keytool asked itself would want it again for each
# step).
password=""
if [[ -e "$keystore" ]]; then
  echo "$keystore already exists: reading its certificate."
  read -rs -p "Keystore password: " password || true
  echo
else
  read -rs -p "Password for the new keystore: " password || true
  echo
  read -rs -p "The password again: " again || true
  echo
  [[ "$password" == "$again" ]] || fail "the passwords differ"
  (
    umask 077
    TZ=UTC KEYSTORE_PASSWORD="$password" "$keytool" -genkeypair \
      -keystore "$keystore" -storetype PKCS12 -alias "$ALIAS" \
      -storepass:env KEYSTORE_PASSWORD \
      -keyalg RSA -keysize 4096 \
      -startdate "$(TZ=UTC date +%Y/%m/%d) 00:00:00" -validity "$DAYS" \
      -dname "$NAME"
  ) || fail "keytool couldn't make the key"
fi

# The fingerprint as apksigner prints it: lowercase hex without colons.
sum="$(TZ=UTC KEYSTORE_PASSWORD="$password" "$keytool" -list -v \
  -keystore "$keystore" -alias "$ALIAS" -storepass:env KEYSTORE_PASSWORD |
  sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | tr -d ':' |
  tr '[:upper:]' '[:lower:]')" || sum=""
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] ||
  fail "couldn't read the certificate in $keystore; run this again to retry"
echo "$sum" >"$RELEASE_CERT_FILE"

echo "== The release key is in $keystore"
echo "Its certificate's SHA-256 fingerprint, now in $RELEASE_CERT_FILE:"
echo "  $sum"
echo "Copy the keystore to two safe places now, and keep the password" \
     "apart from them."

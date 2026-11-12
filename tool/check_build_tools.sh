#!/usr/bin/env bash
# Checks that the app's Android build tools are lined up with the Flutter
# version in use (the `flutter` on the PATH).
#
#   tool/check_build_tools.sh
#
# Flutter is tested with the versions of Gradle, the Android Gradle plugin
# (AGP), Kotlin and its own plugin loader in its project template. The app
# uses the same minor version of each (e.g. AGP 9.3), and the newest patch
# release of it (e.g. 9.3.3) when it moves to a new Flutter. This script
# checks the minor version, and that the patch release is a release and
# not older than the template's; whether a newer one is out is left to the
# upgrade. The app also uses the same plugins. Its gradle.properties sets what the
# template's sets, except org.gradle.jvmargs (the template's larger heap
# didn't make this app's build any faster, and CI's runner also has to fit
# the emulator). This script makes a new project from the template in a
# temporary folder, compares, and fails with what to change. Run it after
# a Flutter upgrade, before building (a build adds missing flags to
# gradle.properties by itself); CI runs it in a job that builds nothing.
#
# Also checked: that the Gradle wrapper downloads Gradle from Gradle's own
# site, and that its distributionSha256Sum is the checksum Gradle publishes
# there (this needs the internet; if the site can't be reached, it only
# warns).
#
# Needs bash 4.4 or newer, flutter, python3 and curl.
#
# Not compared: the app's own Java level, and the SDK versions, which come
# from Flutter itself (flutter.compileSdkVersion etc.).
set -euo pipefail

cd "$(dirname "$0")/.."
source tool/check_lib.sh
need flutter python3 curl

readonly WRAPPER=android/gradle/wrapper/gradle-wrapper.properties
readonly SETTINGS=android/settings.gradle.kts
readonly PROPERTIES=android/gradle.properties
readonly GRADLE_DISTRIBUTIONS=https://services.gradle.org/distributions/
# Set in gradle.properties on purpose, whatever the template has.
readonly OWN_PROPERTIES=(org.gradle.jvmargs)
# Plugins in settings.gradle.kts that the app uses and the template doesn't
# (none yet).
readonly OWN_PLUGINS=()

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

problems=()
problem() { problems+=("$*"); }

warning() {
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::warning::$*"; else echo "warning: $*"; fi
}

# Whether settings.gradle.kts $1 mentions the plugin $2 outside a //
# comment. (grep -c reads to the end: with -q, the grep before it could be
# cut off, and pipefail would take that for no match.)
mentions_plugin() {
  grep -v '^[[:space:]]*//' "$1" | grep -cF "\"$2\"" >/dev/null
}

# Reads .properties files as java.util.Properties (and so Gradle) reads
# them: # and ! comments, "=", ":" or spaces between key and value, lines
# continued with \, escapes, any line ends; values keep their trailing
# spaces. Run as:
#   props get FILE KEY: the value of KEY (nothing if none);
#   props compare OURS THEIRS FLUTTER_VERSION [IGNORED_KEY...]: one line
#     per difference between the two files, saying what to change in OURS.
props() { python3 "$tmp/props.py" "$@"; }
write_props_py() {
  cat >"$tmp/props.py" <<'EOF'
import re, sys

sys.stdout.reconfigure(errors="backslashreplace")

def unescape(s, path):
    def one(m):
        c = m.group(1)
        if c[0] == "u":
            if not re.fullmatch(r"u[0-9a-fA-F]{4}", c):
                # (Java can't read the file then either.)
                sys.exit(f"error: {path}: a \\u escape without four hex digits")
            return chr(int(c[1:], 16))
        return {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}.get(c, c)
    return re.sub(r"\\(u.{0,4}|.)", one, s)

def load(path):
    text = open(path, encoding="latin-1").read()
    lines, pending = [], None
    for raw in re.split(r"\r\n|\r|\n", text):
        line = raw.lstrip(" \t\f")
        if pending is None and (not line or line[0] in "#!"):
            continue
        line = (pending or "") + line
        # An odd number of backslashes at the end continues the line.
        if (len(line) - len(line.rstrip("\\"))) % 2 == 1:
            pending = line[:-1]
            continue
        pending = None
        lines.append(line)
    if pending is not None:
        lines.append(pending)
    props = {}
    for line in lines:
        i = 0
        while i < len(line) and line[i] not in "=: \t\f":
            i += 2 if line[i] == "\\" else 1
        key, rest = line[:i], line[i:].lstrip(" \t\f")
        if rest[:1] in ("=", ":"):
            rest = rest[1:].lstrip(" \t\f")
        props[unescape(key, path)] = unescape(rest, path)
    return props

def shown(s):
    """A key or value on one line of a message."""
    return s.replace("\n", "\\n").replace("\r", "\\r")

def key_shown(key):
    return shown(key) if key else "(an empty key)"

if sys.argv[1] == "get":
    value = load(sys.argv[2]).get(sys.argv[3])
    if value is not None:
        print(shown(value))
elif sys.argv[1] == "compare":
    ours_path, theirs_path, version, ignored = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
    ours, theirs = load(ours_path), load(theirs_path)
    template = f"Flutter {version}'s template"
    for key in sorted((ours.keys() | theirs.keys()) - set(ignored)):
        k = key_shown(key)
        if key not in theirs:
            print(f"{ours_path}: remove {k}={shown(ours[key])} ({template} doesn't set {k}).")
        elif key not in ours:
            print(f"{ours_path}: add {k}={shown(theirs[key])}, as in {template}.")
        elif ours[key] != theirs[key]:
            print(f"{ours_path}: {k} is '{shown(ours[key])}'; {template} has '{shown(theirs[key])}'.")
EOF
}

# The plugins a settings.gradle.kts gives a version, one "id version" line
# each, e.g. "com.android.application 9.3.3".
plugins() {
  sed -n 's/^[[:space:]]*id[[:space:]]*([[:space:]]*"\([^"]*\)"[[:space:]]*)[[:space:]]*version[[:space:]]*"\([^"]*\)".*/\1 \2/p' "$1"
}

# What a plugin is called in messages.
plugin_name() {
  case "$1" in
    com.android.application) echo "Android Gradle plugin ($1)" ;;
    org.jetbrains.kotlin.android) echo "Kotlin ($1)" ;;
    dev.flutter.flutter-plugin-loader) echo "Flutter's plugin loader ($1)" ;;
    *) echo "$1" ;;
  esac
}

# Whether $1 is a release version: numbers only (9.5, 9.5.1), no "-rc1".
is_release() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; }

# MAJOR.MINOR of a release version.
minor_line() {
  local version
  version="$(three_part_version "$1")"
  echo "${version%.*}"
}

# Compares the app's version $2 of tool $1 with the template's, $3; $4 says
# where to change it.
compare() {
  local tool=$1 ours=$2 theirs=$3 where=$4
  if ! is_release "$theirs"; then
    problem "Flutter $flutter_version's template has $tool '$theirs', which isn't a release version this script can compare. Line it up by hand, and update this script."
    return
  fi
  local line
  line="$(minor_line "$theirs")"
  local change="In $where, use the newest $line.x release (at least $theirs)."
  if [[ -z "$ours" ]]; then
    problem "$tool: couldn't read the app's version. $change"
  elif ! is_release "$ours"; then
    problem "$tool $ours isn't a release. $change"
  elif [[ "$(minor_line "$ours")" != "$line" ]]; then
    problem "$tool $ours is on the $(minor_line "$ours") line, Flutter $flutter_version's template on $line ($theirs). $change"
  elif version_older "$ours" "$theirs"; then
    problem "$tool $ours is older than Flutter $flutter_version's template ($theirs). $change"
  else
    echo "$tool $ours: OK (template: $theirs)"
  fi
}

# Whether the associative array named $1 has the key $2. (Not [[ -v ]],
# which would expand a $(...) in the key once more on older bash.)
has() {
  local -n has_array=$1
  [[ -n "${has_array[$2]+set}" ]]
}

flutter_version="$(flutter --version --machine 2>/dev/null |
  sed -n 's/^ *"frameworkVersion": *"\([^"]*\)".*/\1/p' || true)"
[[ -n "$flutter_version" ]] ||
  { echo "error: couldn't get the version of flutter" >&2; exit 1; }
if ! ci_version="$(ci_flutter_version)"; then
  warning "couldn't read FLUTTER_VERSION (one line, an exact version) in .github/workflows/dart.yml, so this doesn't know whether $flutter_version is the Flutter CI builds with."
elif [[ "$ci_version" != "$flutter_version" ]]; then
  warning "this is Flutter $flutter_version, CI builds with $ci_version (FLUTTER_VERSION in .github/workflows/dart.yml): comparing with $flutter_version's template."
fi

for file in "$WRAPPER" "$SETTINGS" "$PROPERTIES"; do
  [[ -f "$file" ]] || { echo "error: there is no $file" >&2; exit 1; }
done

echo "== Making a new project from Flutter $flutter_version's template"
if ! flutter create --platforms=android --no-pub --project-name template_check \
     "$tmp/template_check" >"$tmp/create.log" 2>&1; then
  cat "$tmp/create.log" >&2
  echo "error: flutter create failed" >&2
  exit 1
fi
template="$tmp/template_check/android"
for file in "${WRAPPER#android/}" "${SETTINGS#android/}" "${PROPERTIES#android/}"; do
  if [[ ! -f "$template/$file" ]]; then
    echo "error: Flutter $flutter_version's template has no android/$file; this script needs updating." >&2
    exit 1
  fi
done

echo "== Comparing"
write_props_py

# Gradle (the wrapper's distribution, gradle-VERSION-TYPE.zip).
ours_url="$(props get "$WRAPPER" distributionUrl)"
theirs_url="$(props get "$template/${WRAPPER#android/}" distributionUrl)"
gradle_of() { sed -n 's|.*/gradle-\(.*\)-[a-z]*\.zip$|\1|p' <<<"$1"; }
compare Gradle "$(gradle_of "$ours_url")" "$(gradle_of "$theirs_url")" \
  "$WRAPPER (distributionUrl, and distributionSha256Sum to match)"

# The plugins with versions in settings.gradle.kts. The template's must
# include AGP: if not, it is written in some other way, which this script
# can't compare (and advice about the other plugins would be wrong).
declare -A ours_plugins=() theirs_plugins=()
ours_list="$(plugins "$SETTINGS")"
theirs_list="$(plugins "$template/${SETTINGS#android/}")"
while read -r id version; do
  if [[ -n "$id" ]]; then ours_plugins["$id"]=$version; fi
done <<<"$ours_list"
while read -r id version; do
  if [[ -n "$id" ]]; then theirs_plugins["$id"]=$version; fi
done <<<"$theirs_list"
if ! has theirs_plugins com.android.application; then
  problem "couldn't read the Android Gradle plugin's (com.android.application) version in Flutter $flutter_version's template (settings.gradle.kts), so the plugins weren't compared; this script needs updating."
  theirs_plugins=() ours_plugins=()
fi
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  name="$(plugin_name "$id")"
  if ! has theirs_plugins "$id" &&
     mentions_plugin "$template/${SETTINGS#android/}" "$id"; then
    problem "$name: couldn't read its version in Flutter $flutter_version's template (settings.gradle.kts); this script needs updating."
  elif ! has theirs_plugins "$id"; then
    # (The app's own plugins aren't in the template.)
    for own in "${OWN_PLUGINS[@]}"; do [[ "$id" != "$own" ]] || continue 2; done
    problem "$name: Flutter $flutter_version's template doesn't use it. Remove it from $SETTINGS (and android/app/build.gradle.kts), or, if the template set it up another way, do as a new project (flutter create) does."
  elif has ours_plugins "$id"; then
    compare "$name" "${ours_plugins[$id]}" "${theirs_plugins[$id]}" "$SETTINGS"
  elif mentions_plugin "$SETTINGS" "$id"; then
    problem "$name: couldn't read the app's version in $SETTINGS (write it as the template does: id(\"$id\") version \"...\")."
  else
    problem "$name: Flutter $flutter_version's template uses it (version ${theirs_plugins[$id]}); add it to $SETTINGS as the template does, and see whether android/app/build.gradle.kts needs it too."
  fi
done < <(printf '%s\n' "${!ours_plugins[@]}" "${!theirs_plugins[@]}" | sort -u)

# gradle.properties.
props_problems="$(props compare "$PROPERTIES" "$template/${PROPERTIES#android/}" \
                    "$flutter_version" "${OWN_PROPERTIES[@]}")"
if [[ -z "$props_problems" ]]; then
  echo "gradle.properties: OK (as the template's, apart from ${OWN_PROPERTIES[*]})"
else
  while IFS= read -r line; do problem "$line"; done <<<"$props_problems"
fi

# The Gradle distribution: from Gradle's site, with its published checksum.
distribution="${ours_url##*/}"
sum_url="$GRADLE_DISTRIBUTIONS$distribution.sha256"
ours_sum="$(props get "$WRAPPER" distributionSha256Sum)"
if [[ "$ours_url" != "$GRADLE_DISTRIBUTIONS"gradle-*.zip ]]; then
  problem "$WRAPPER: distributionUrl is '$ours_url', not a Gradle distribution on Gradle's own site ($GRADLE_DISTRIBUTIONS)."
elif [[ -z "$ours_sum" ]]; then
  problem "$WRAPPER has no distributionSha256Sum: add Gradle's checksum of the distribution ($sum_url)."
elif ! status="$(curl -sSL --retry 3 --connect-timeout 20 --max-time 60 \
                   -o "$tmp/sha256" -w '%{http_code}' "$sum_url")"; then
  warning "couldn't reach Gradle's site for the checksum ($sum_url), so distributionSha256Sum wasn't compared with it."
else
  # (Its first word: a .sha256 file may also name the file, or end in a
  # newline. curl empties the file before each retry.)
  published=""
  read -r published _ <"$tmp/sha256" || true
  if [[ "$status" == 404 || "$status" == 410 ]]; then
    problem "Gradle's site has no checksum for $distribution ($sum_url): is distributionUrl right?"
  elif [[ "$status" != 200 ]]; then
    warning "Gradle's site answered HTTP $status for the checksum ($sum_url), so distributionSha256Sum wasn't compared with it."
  elif [[ ! "$published" =~ ^[0-9a-f]{64}$ ]]; then
    warning "what Gradle's site sent for the checksum ($sum_url) isn't one, so distributionSha256Sum wasn't compared with it."
  elif [[ "$ours_sum" != "$published" ]]; then
    problem "$WRAPPER: distributionSha256Sum is $ours_sum, but Gradle publishes $published for $distribution."
  else
    echo "Gradle distribution checksum: OK"
  fi
fi

if ((${#problems[@]})); then
  echo
  echo "The build tools don't match Flutter $flutter_version:" >&2
  printf -- '- %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "== The build tools match Flutter $flutter_version"

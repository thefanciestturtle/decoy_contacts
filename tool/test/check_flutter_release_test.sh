#!/usr/bin/env bash
# Tests tool/check_flutter_release.sh with stand-ins for `curl` (Flutter's
# list of releases) and `gh` (the repository's issues): needs neither the
# internet nor GitHub.
#
#   tool/test/check_flutter_release_test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
readonly SCRIPT="$PWD/tool/check_flutter_release.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stand-ins. `curl` prints a list of releases whose current stable one is
# $LATEST, after an older stable hotfix and a beta (it fails if $LATEST is
# empty). `gh` writes each call to $GH_LOG (the --body of a new issue also
# to $GH_LOG.body), lists $ISSUES (JSON) as the issues, shows
# $ISSUE_BODY as an issue's text, and fails at that with VIEW_FAILS=1.
mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -n "${LATEST:-}" ]] || exit 22
cat <<JSON
{"base_url": "https://example.invalid",
 "current_release": {"beta": "bbb", "stable": "sss"},
 "releases": [
  {"hash": "hhh", "channel": "stable", "version": "3.44.12"},
  {"hash": "bbb", "channel": "beta", "version": "9.0.0-1.0.pre"},
  {"hash": "sss", "channel": "stable", "version": "$LATEST"},
  {"hash": "ooo", "channel": "stable", "version": "3.47.9"}]}
JSON
EOF
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $1 $2 $3" >>"$GH_LOG"
case "$1 $2" in
  "issue list") echo "${ISSUES:-[]}" ;;
  "issue view")
    [[ "${VIEW_FAILS:-}" != 1 ]] || { echo "HTTP 502" >&2; exit 1; }
    python3 -c 'import json, os; print(json.dumps({"body": os.environ["ISSUE_BODY"]}))' ;;
  "issue create")
    while (($#)); do
      if [[ "$1" == --body ]]; then printf '%s' "$2" >"$GH_LOG.body"; fi
      shift
    done ;;
esac
EOF
chmod +x "$tmp/bin/"*

readonly TITLE='A newer stable Flutter is out'

# One issue as gh lists it: issue NUMBER STATE VERSION [AUTHOR], where
# VERSION is the release its text names.
issue() {
  python3 -c '
import json, sys
number, state, version, author, title = sys.argv[1:]
print(json.dumps({"number": int(number), "title": title, "state": state,
                  "body": f"Flutter {version} is out; ...",
                  "author": {"login": author, "is_bot": author != "someone"}}))
' "$1" "$2" "$3" "${4:-app/github-actions}" "$TITLE"
}
# A list of issues: issues "$(issue ...)" ...
issues() { local IFS=,; echo "[$*]"; }

failures=0
case_number=0

# expect NAME OURS LATEST STATUS TEXT CALLS [ARGS...] : runs the script with
# FLUTTER_VERSION OURS (none if empty) and Flutter's stable release LATEST,
# and wants exit STATUS, TEXT in its output, and exactly the gh calls that
# change something in CALLS, in order, each with its issue number (e.g.
# "create", "edit7 comment7", "" for none). The environment can set
# ISSUES, ISSUE_BODY and VIEW_FAILS.
expect() {
  local name=$1 ours=$2 latest=$3 want_status=$4 want_text=$5 want_calls=$6
  shift 6
  local proj="$tmp/case$((++case_number))"
  mkdir -p "$proj/tool" "$proj/.github/workflows"
  cp "$SCRIPT" "$proj/tool/"
  {
    echo 'env:'
    if [[ -n "$ours" ]]; then echo "  FLUTTER_VERSION: $ours"; fi
    echo '  OTHER: x'
  } >"$proj/.github/workflows/dart.yml"
  local out status=0 calls
  : >"$proj/gh.log"
  out="$(PATH="$tmp/bin:/usr/bin:/bin" LATEST="$latest" GH_LOG="$proj/gh.log" \
    ISSUES="${ISSUES:-[]}" ISSUE_BODY="${ISSUE_BODY:-}" VIEW_FAILS="${VIEW_FAILS:-}" \
    "$proj/tool/check_flutter_release.sh" "$@" 2>&1)" || status=$?
  calls="$(sed -n 's/^gh issue \(edit\|comment\|close\) \([0-9]*\).*/\1\2/p; s/^gh issue create .*/create/p' \
    "$proj/gh.log" | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$status" == "$want_status" && "$out" == *"$want_text"* &&
        "$calls" == "$want_calls" ]]; then
    echo "ok: $name"
  else
    echo "FAIL: $name: exit $status (want $want_status), calls '$calls' (want '$want_calls'), output (want '$want_text'):"
    while IFS= read -r line; do echo "    $line"; done <<<"$out"
    failures=$((failures + 1))
  fi
}

expect "up to date: nothing to do" 3.50.0 3.50.0 0 "Nothing to do." ""
expect "newer than the stable release: nothing to do" 3.51.0 3.50.0 0 \
  "Nothing to do." ""
expect "the current stable release is found by its hash" 3.50.0 3.51.0 0 \
  "the current stable release is 3.51.0." "create"
body="$(cat "$tmp/case$case_number/gh.log.body")"
[[ "$body" == "Flutter 3.51.0 is out; CI builds with Flutter 3.50.0 (\`FLUTTER_VERSION\` in \`.github/workflows/dart.yml\`)."* ]] ||
  { echo "FAIL: the issue's text: $body"; failures=$((failures + 1)); }
expect "Flutter's list can't be read: an error" 3.50.0 "" 22 "" ""

ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" ISSUE_BODY="$body" expect \
  "the issue already says so: nothing changes" 3.50.0 3.51.0 0 \
  "Issue #7 already says so." ""
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" ISSUE_BODY="${body//$'\n'/$'\r\n'}" expect \
  "the same text with Windows line ends: nothing changes" 3.50.0 3.51.0 0 \
  "Issue #7 already says so." ""
ISSUES="$(issues "$(issue 7 OPEN 3.50.1)")" ISSUE_BODY="${body//3.51.0/3.50.1}" expect \
  "a still newer release: the text is updated, with a comment" 3.50.0 3.51.0 0 \
  "Updating issue #7: Flutter 3.51.0 is out." "edit7 comment7"
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" ISSUE_BODY="$body" expect \
  "only the rest of the text changed: updated without a comment" 3.50.1 3.51.0 0 \
  "Updating the text of issue #7 (still about Flutter 3.51.0)." "edit7"
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" VIEW_FAILS=1 expect \
  "the issue can't be read: an error, nothing changes" 3.50.0 3.51.0 1 \
  "HTTP 502" ""
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" expect \
  "caught up: the issue is closed" 3.51.0 3.51.0 0 \
  "Closing issue #7: CI now builds with Flutter 3.51.0." "close7"
ISSUES="$(issues "$(issue 7 OPEN 3.50.1)" "$(issue 9 OPEN 3.51.0)")" expect \
  "caught up with two open: both are closed" 3.51.0 3.51.0 0 \
  "Closing issue #7" "close9 close7"
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)" "$(issue 9 OPEN 3.51.0)")" ISSUE_BODY="$body" expect \
  "two open: the newer one is kept, the other closed" 3.50.0 3.51.0 0 \
  "Closing issue #7: #9 says the same." "close7"

ISSUES="$(issues "$(issue 5 OPEN 3.51.0 someone)")" expect \
  "someone else's issue with the same title is left alone" 3.50.0 3.51.0 0 \
  "Opening an issue" "create"
ISSUES="$(issues "$(issue 5 OPEN 3.51.0 someone)")" expect \
  "and isn't closed either" 3.51.0 3.51.0 0 "Nothing to do." ""
ISSUES="$(issues "$(issue 7 OPEN 3.51.0 github-actions)")" expect \
  "GitHub Actions also counts without 'app/'" 3.51.0 3.51.0 0 \
  "Closing issue #7" "close7"

ISSUES="$(issues "$(issue 7 CLOSED 3.51.0)")" expect \
  "closed while it named this release: stays closed" 3.50.0 3.51.0 0 \
  "Nothing to do: the issue about Flutter 3.51.0 was closed." ""
ISSUES="$(issues "$(issue 7 CLOSED 3.50.1)")" expect \
  "closed for an older release: a newer one opens an issue" 3.50.0 3.51.0 0 \
  "Opening an issue: Flutter 3.51.0 is out." "create"

expect "--dry-run changes nothing" 3.50.0 3.51.0 0 \
  "(dry run) would run: gh issue create --title $TITLE" "" --dry-run
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" expect \
  "--dry-run doesn't close either" 3.51.0 3.51.0 0 \
  "(dry run) would run: gh issue close 7" "" --dry-run
expect "an unknown argument is refused" 3.50.0 3.51.0 2 "usage:" "" --dryrun
expect "no FLUTTER_VERSION is an error" "" 3.51.0 1 \
  "error: no FLUTTER_VERSION in .github/workflows/dart.yml" ""

if ((failures)); then
  echo "$failures of $case_number cases failed" >&2
  exit 1
fi
echo "All $case_number cases passed"

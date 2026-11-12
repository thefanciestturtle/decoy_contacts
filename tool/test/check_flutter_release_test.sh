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
# $LATEST. `gh` writes each call to $GH_LOG (the --body of a new issue
# also to $GH_LOG.body), lists $ISSUES (JSON) as the open issues, and
# shows $ISSUE_BODY as an issue's text.
mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
{"base_url": "https://example.invalid",
 "current_release": {"beta": "bbb", "stable": "sss"},
 "releases": [
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
bot_issue() { echo "[{\"number\": 7, \"title\": \"$TITLE\", \"author\": {\"login\": \"app/github-actions\", \"is_bot\": true}}]"; }
person_issue() { echo "[{\"number\": 5, \"title\": \"$TITLE\", \"author\": {\"login\": \"someone\", \"is_bot\": false}}]"; }

failures=0
case_number=0

# expect NAME OURS LATEST STATUS TEXT CALLS [ARGS...] : runs the script with
# FLUTTER_VERSION OURS (none if empty) and Flutter's stable release LATEST,
# and wants exit STATUS, TEXT in its output, and exactly the gh calls that
# change something in CALLS (e.g. "create", "edit comment", or "" for
# none). The environment can set ISSUES and ISSUE_BODY.
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
    ISSUES="${ISSUES:-[]}" ISSUE_BODY="${ISSUE_BODY:-}" \
    "$proj/tool/check_flutter_release.sh" "$@" 2>&1)" || status=$?
  calls="$(sed -n 's/^gh issue \(create\|edit\|comment\|close\) .*/\1/p' \
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
expect "a newer release opens an issue" 3.50.0 3.51.0 0 \
  "Opening an issue: Flutter 3.51.0 is out." "create"
body="$(cat "$tmp/case$case_number/gh.log.body")"
[[ "$body" == "Flutter 3.51.0 is out; CI builds with Flutter 3.50.0 (\`FLUTTER_VERSION\` in \`.github/workflows/dart.yml\`)."* ]] ||
  { echo "FAIL: the issue's text: $body"; failures=$((failures + 1)); }

ISSUES="$(bot_issue)" ISSUE_BODY="$body" expect \
  "the issue already says so: nothing changes" 3.50.0 3.51.0 0 \
  "Issue #7 already says so." ""
ISSUES="$(bot_issue)" ISSUE_BODY="${body//$'\n'/$'\r\n'}" expect \
  "the same text with Windows line ends: nothing changes" 3.50.0 3.51.0 0 \
  "Issue #7 already says so." ""
ISSUES="$(bot_issue)" ISSUE_BODY="${body//3.51.0/3.50.1}" expect \
  "a still newer release: the text is updated, with a comment" 3.50.0 3.51.0 0 \
  "Updating issue #7: Flutter 3.51.0 is out." "edit comment"
ISSUES="$(bot_issue)" expect "caught up: the issue is closed" 3.51.0 3.51.0 0 \
  "Closing issue #7: CI now builds with Flutter 3.51.0." "close"
ISSUES="$(person_issue)" expect \
  "someone else's issue with the same title is left alone" 3.50.0 3.51.0 0 \
  "Opening an issue" "create"
ISSUES="$(person_issue)" expect "and isn't closed either" 3.51.0 3.51.0 0 \
  "Nothing to do." ""

expect "--dry-run changes nothing" 3.50.0 3.51.0 0 \
  "(dry run) would run: gh issue create --title $TITLE" "" --dry-run
ISSUES="$(bot_issue)" expect "--dry-run doesn't close either" 3.51.0 3.51.0 0 \
  "(dry run) would run: gh issue close 7" "" --dry-run
expect "an unknown argument is refused" 3.50.0 3.51.0 2 "usage:" "" --dryrun
expect "no FLUTTER_VERSION is an error" "" 3.51.0 1 \
  "error: no FLUTTER_VERSION in .github/workflows/dart.yml" ""

if ((failures)); then
  echo "$failures of $case_number cases failed" >&2
  exit 1
fi
echo "All $case_number cases passed"

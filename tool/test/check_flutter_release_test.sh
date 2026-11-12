#!/usr/bin/env bash
# Tests tool/check_flutter_release.sh with stand-ins for `curl` (Flutter's
# list of releases) and `gh` (the repository's issues): needs neither the
# internet nor GitHub.
#
#   tool/test/check_flutter_release_test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
readonly SCRIPT="$PWD/tool/check_flutter_release.sh"
readonly LIB="$PWD/tool/check_lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stand-ins. `curl` writes the URL it was given to $CURL_LOG and prints a
# list of releases whose current stable one is $LATEST, out on
# 2026-11-11T19:05:47.758707Z, after an older stable hotfix and a beta; it
# fails if $LATEST is empty, and gives a list without the current release
# with BAD_LIST=1. `gh` writes each call to $GH_LOG on one line (the
# --body of a new issue also to $GH_LOG.body), and lists $ISSUES (JSON) as
# the issues, as asked: only the open ones without --state all, only the
# fields named after --json. It fails at that with LIST_FAILS=1. An
# issue's comments are $ISSUE_COMMENTS (a JSON list of their texts). It
# also writes the repository it was given in GH_REPO to $GH_LOG.
mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >>"$CURL_LOG"
[[ -n "${LATEST:-}" ]] || exit 22
if [[ "${BAD_LIST:-}" == 1 ]]; then
  echo '{"current_release": {"stable": "zzz"}, "releases": []}'
  exit 0
fi
cat <<JSON
{"base_url": "https://example.invalid",
 "current_release": {"beta": "bbb", "stable": "sss"},
 "releases": [
  {"hash": "hhh", "channel": "stable", "version": "3.44.12"},
  {"hash": "bbb", "channel": "beta", "version": "9.0.0-1.0.pre"},
  {"hash": "sss", "channel": "stable", "version": "$LATEST",
   "release_date": "2026-11-11T19:05:47.758707Z"},
  {"hash": "ooo", "channel": "stable", "version": "3.47.9"}]}
JSON
EOF
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
all="$*"
echo "gh ${all//$'\n'/ }" >>"$GH_LOG"
echo "repo ${GH_REPO:-}" >>"$GH_LOG"
case "$1 $2" in
  "issue list")
    [[ "${LIST_FAILS:-}" != 1 ]] || { echo "HTTP 502" >&2; exit 1; }
    python3 -c '
import json, os, sys
args = sys.argv[1:]
fields = args[args.index("--json") + 1].split(",")
everything = "--state" in args and args[args.index("--state") + 1] == "all"
print(json.dumps([{k: v for k, v in i.items() if k in fields}
                  for i in json.loads(os.environ.get("ISSUES") or "[]")
                  if everything or i["state"] == "OPEN"]))
' "$@" ;;
  "issue view")
    python3 -c '
import json, os
print(json.dumps({"comments": [{"body": b} for b in
                  json.loads(os.environ.get("ISSUE_COMMENTS") or "[]")]}))' ;;
  "issue create")
    while (($#)); do
      if [[ "$1" == --body ]]; then printf '%s' "$2" >"$GH_LOG.body"; fi
      shift
    done ;;
esac
EOF
chmod +x "$tmp/bin/"*

readonly TITLE='A newer stable Flutter is out'
readonly RELEASES=https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json

# One issue as gh lists it: issue NUMBER STATE VERSION [AUTHOR [REASON
# [CLOSED_AT [CREATED_AT]]]]. VERSION is the release its text names ("-":
# text that names none); REASON is why it was closed (COMPLETED,
# NOT_PLANNED or DUPLICATE), and CLOSED_AT when (by default a day after the
# release); CREATED_AT when it was opened (by default ten days before).
issue() {
  python3 -c '
import json, sys
number, state, version, author, reason, closed_at, created_at, title = sys.argv[1:]
body = "Notes first" if version == "-" else f"Flutter {version} is out; ..."
print(json.dumps({"number": int(number), "title": title, "state": state,
                  "stateReason": reason or None, "body": body,
                  "createdAt": created_at,
                  "closedAt": closed_at if state == "CLOSED" else None,
                  "author": {"login": author, "is_bot": author != "someone"}}))
' "$1" "$2" "$3" "${4:-app/github-actions}" "${5:-}" \
    "${6:-2026-11-12T08:00:00Z}" "${7:-2026-11-01T08:00:00Z}" "$TITLE"
}
# A list of issues: issues "$(issue ...)" ...
issues() { local IFS=,; echo "[$*]"; }

failures=0
case_number=0

# expect NAME OURS LATEST STATUS TEXT CALLS [ARGS...] : runs the script with
# FLUTTER_VERSION OURS (written as given; none if empty) and Flutter's
# stable release LATEST, and wants exit STATUS, TEXT in its output, and
# exactly the gh calls that change something in CALLS, in order: "create",
# "editN", "commentN", "closeN:REASON", "closeN:duplicate-of-M" ("" for
# none). It runs as in GitHub
# Actions unless IN_ACTIONS is empty. The environment can also set ISSUES,
# ISSUE_COMMENTS, LIST_FAILS, BAD_LIST, and ORIGIN, the URL of the project's
# git remote "origin" (none by default).
expect() {
  local name=$1 ours=$2 latest=$3 want_status=$4 want_text=$5 want_calls=$6
  shift 6
  local proj="$tmp/case$((++case_number))"
  mkdir -p "$proj/tool" "$proj/.github/workflows"
  cp "$SCRIPT" "$LIB" "$proj/tool/"
  {
    echo 'env:'
    if [[ -n "$ours" ]]; then echo "  FLUTTER_VERSION: $ours"; fi
    echo '  OTHER: x'
  } >"$proj/.github/workflows/dart.yml"
  local out status=0 calls
  : >"$proj/gh.log"
  if [[ -n "${ORIGIN:-}" ]]; then
    git -C "$proj" init -q && git -C "$proj" remote add origin "$ORIGIN"
  fi
  out="$(PATH="$tmp/bin:/usr/bin:/bin" LATEST="$latest" GH_LOG="$proj/gh.log" \
    CURL_LOG="$proj/curl.log" ISSUES="${ISSUES:-[]}" \
    ISSUE_COMMENTS="${ISSUE_COMMENTS:-[]}" GH_REPO="" \
    LIST_FAILS="${LIST_FAILS:-}" BAD_LIST="${BAD_LIST:-}" \
    GITHUB_ACTIONS="${IN_ACTIONS-true}" \
    "$proj/tool/check_flutter_release.sh" "$@" 2>&1)" || status=$?
  calls="$(sed -n \
    -e 's/^gh issue create .*/create/p' \
    -e 's/^gh issue \(edit\|comment\) \([0-9]*\) .*/\1\2/p' \
    -e 's/^gh issue close \([0-9]*\) --reason \([a-z]*\) .*/close\1:\2/p' \
    -e 's/^gh issue close \([0-9]*\) --duplicate-of \([0-9]*\).*/close\1:duplicate-of-\2/p' \
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
grep -qx "repo " "$tmp/case$case_number/gh.log" ||
  { echo "FAIL: GH_REPO without a remote: $(grep ^repo "$tmp/case$case_number/gh.log")"; failures=$((failures + 1)); }
ORIGIN=https://github.com/someone/fake_contacts.git expect \
  "the repository is origin's" 3.50.0 3.50.0 0 "Nothing to do." ""
grep -qx "repo someone/fake_contacts" "$tmp/case$case_number/gh.log" ||
  { echo "FAIL: GH_REPO from origin: $(grep ^repo "$tmp/case$case_number/gh.log")"; failures=$((failures + 1)); }
[[ "$(cat "$tmp/case$case_number/curl.log")" == "$RELEASES" ]] ||
  { echo "FAIL: the list's URL: $(cat "$tmp/case$case_number/curl.log")"; failures=$((failures + 1)); }
expect "newer than the stable release: nothing to do" 3.51.0 3.50.0 0 \
  "Nothing to do." ""
expect "the current stable release is found by its hash" 3.50.0 3.51.0 0 \
  "the current stable release is 3.51.0." "create"
body="$(cat "$tmp/case$case_number/gh.log.body" 2>/dev/null || true)"
[[ "$body" == "Flutter 3.51.0 is out; CI builds with Flutter 3.50.0 (\`FLUTTER_VERSION\` in \`.github/workflows/dart.yml\`)."*"finds it by its title"*"close it as not planned." ]] ||
  { echo "FAIL: the issue's text: $body"; failures=$((failures + 1)); }
expect "Flutter's list can't be downloaded: an error" 3.50.0 "" 22 "" ""
BAD_LIST=1 expect "Flutter's list without the current release: an error" \
  3.50.0 3.51.0 1 "error: unexpected list of Flutter releases (StopIteration" ""
LIST_FAILS=1 expect "the issues can't be listed: an error" 3.50.0 3.51.0 1 \
  "HTTP 502" ""

ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" expect \
  "the issue already names the release: nothing changes" 3.50.0 3.51.0 0 \
  "Issue #7 already says so." ""
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" expect \
  "nor when FLUTTER_VERSION moved but isn't there yet (notes are kept)" \
  3.50.1 3.51.0 0 "Issue #7 already says so." ""
ISSUES="$(issues "$(issue 7 OPEN 3.50.1)")" expect \
  "a still newer release: the text is updated, with a comment" 3.50.0 3.51.0 0 \
  "Updating issue #7: Flutter 3.51.0 is out." "comment7 edit7"
ISSUES="$(issues "$(issue 7 OPEN -)")" expect \
  "text changed by hand is left, but told of the release" 3.50.0 3.51.0 0 \
  "Issue #7's text was changed by hand; leaving it, but commenting: Flutter 3.51.0 is out." \
  "comment7"
ISSUES="$(issues "$(issue 7 OPEN -)")" \
  ISSUE_COMMENTS='["A note", "Flutter 3.51.0 is out now.\n"]' expect \
  "only once" 3.50.0 3.51.0 0 \
  "Issue #7's text was changed by hand; it was told of Flutter 3.51.0 already." ""
ISSUES="$(issues "$(issue 7 OPEN - app/github-actions "" "" 2026-11-12T08:00:00Z)")" expect \
  "and not at all if it was opened about this release" 3.50.0 3.51.0 0 \
  "Issue #7's text was changed by hand; it was opened about Flutter 3.51.0." ""
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" expect \
  "caught up: the issue is closed as completed" 3.51.0 3.51.0 0 \
  "Closing issue #7: CI now builds with Flutter 3.51.0." "close7:completed"
ISSUES="$(issues "$(issue 7 OPEN 3.50.1)" "$(issue 9 OPEN 3.51.0)")" expect \
  "caught up with two open: both are closed" 3.51.0 3.51.0 0 \
  "Closing issue #7" "close9:completed close7:completed"
ISSUES="$(issues "$(issue 9 OPEN 3.52.0)")" expect \
  "an issue naming a newer release than the current (withdrawn) one is left" \
  3.51.0 3.51.1 0 \
  "Issue #9 names Flutter 3.52.0, newer than the current stable release; leaving it." ""
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)" "$(issue 9 OPEN 3.51.0)")" expect \
  "two open: the newer one is kept, the other closed as a duplicate" \
  3.50.0 3.51.0 0 "Closing issue #7 as a duplicate of #9." "close7:duplicate-of-9"

ISSUES="$(issues "$(issue 5 OPEN 3.51.0 someone)")" expect \
  "someone else's issue with the same title is left alone" 3.50.0 3.51.0 0 \
  "Opening an issue" "create"
ISSUES="$(issues "$(issue 5 OPEN 3.51.0 someone)")" expect \
  "and isn't closed either" 3.51.0 3.51.0 0 "Nothing to do." ""
ISSUES="$(issues "$(issue 7 OPEN 3.51.0 github-actions)")" expect \
  "GitHub Actions also counts without 'app/'" 3.51.0 3.51.0 0 \
  "Closing issue #7" "close7:completed"

ISSUES="$(issues "$(issue 7 CLOSED 3.51.0 app/github-actions NOT_PLANNED)")" expect \
  "closed as not planned while it named this release: stays closed" 3.50.0 3.51.0 0 \
  "Nothing to do: the issue about Flutter 3.51.0 was closed as not planned." ""
ISSUES="$(issues "$(issue 7 CLOSED 3.50.1 app/github-actions NOT_PLANNED)")" expect \
  "closed as not planned while it named an older one: a new issue (even after)" \
  3.50.0 3.51.0 0 "Opening an issue: Flutter 3.51.0 is out." "create"
ISSUES="$(issues "$(issue 7 CLOSED - app/github-actions NOT_PLANNED)")" expect \
  "with its text changed by hand, closed after the release came out: put off" \
  3.50.0 3.51.0 0 "Nothing to do: the issue about Flutter 3.51.0 was closed as not planned." ""
ISSUES="$(issues "$(issue 7 CLOSED - app/github-actions NOT_PLANNED 2026-11-01T08:00:00Z)")" expect \
  "with its text changed by hand, closed before: a new issue" 3.50.0 3.51.0 0 \
  "Opening an issue: Flutter 3.51.0 is out." "create"
ISSUES="$(issues "$(issue 7 CLOSED 3.51.0 app/github-actions COMPLETED)")" expect \
  "closed as done, then FLUTTER_VERSION went back: a new issue" 3.50.0 3.51.0 0 \
  "Opening an issue: Flutter 3.51.0 is out." "create"

expect "--dry-run changes nothing" 3.50.0 3.51.0 0 \
  "(dry run) would run: gh issue create --title $TITLE" "" --dry-run
ISSUES="$(issues "$(issue 7 OPEN 3.51.0)")" expect \
  "--dry-run doesn't close either" 3.51.0 3.51.0 0 \
  "(dry run) would run: gh issue close 7 --reason completed" "" --dry-run
expect "an unknown argument is refused" 3.50.0 3.51.0 2 "usage:" "" --dryrun
IN_ACTIONS="" expect "outside GitHub Actions, only --dry-run" 3.50.0 3.51.0 2 \
  "error: outside GitHub Actions, run this with --dry-run" ""
IN_ACTIONS="" expect "(where --dry-run works)" 3.50.0 3.51.0 0 \
  "(dry run) would run: gh issue create" "" --dry-run
expect "FLUTTER_VERSION in quotes, with a comment" "'3.50.0' # pinned" 3.51.0 0 \
  "CI builds with Flutter 3.50.0;" "create"
expect "FLUTTER_VERSION that isn't exact is an error" "3.50.x" 3.51.0 1 \
  "error: no FLUTTER_VERSION with an exact version" ""
expect "nor is one without its patch" "3.50" 3.51.0 1 \
  "error: no FLUTTER_VERSION with an exact version" ""
expect "two FLUTTER_VERSION lines are an error" $'3.50.0\n  FLUTTER_VERSION: 3.47.9' 3.51.0 1 \
  "error: no FLUTTER_VERSION with an exact version (e.g. 3.50.0) in .github/workflows/dart.yml, or more than one" ""
expect "no FLUTTER_VERSION is an error" "" 3.51.0 1 \
  "error: no FLUTTER_VERSION with an exact version (e.g. 3.50.0) in .github/workflows/dart.yml, or more than one" ""

if ((failures)); then
  echo "$failures of $case_number cases failed" >&2
  exit 1
fi
echo "All $case_number cases passed"

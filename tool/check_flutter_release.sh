#!/usr/bin/env bash
# Keeps an issue open while a newer stable Flutter is out than the one CI
# builds with.
#
#   tool/check_flutter_release.sh [--dry-run]
#
# Compares FLUTTER_VERSION in .github/workflows/dart.yml with Flutter's
# current stable release, from Flutter's list of releases. If that is newer,
# it opens an issue saying so. If a still newer one comes out while it is
# open, it updates the issue and comments on it (one issue, however many
# runs); notes go in comments (a text changed by hand is left alone, and
# only gets a comment for a newer release). Once FLUTTER_VERSION has caught
# up, it closes it. To put the upgrade off until a newer release comes out,
# close it as "not planned". It finds the issue by its title, so keep that.
#
# It only touches issues opened by GitHub Actions: it runs in the weekly
# workflow (.github/workflows/flutter_release.yml), with that workflow's
# token (`issues: write`). Elsewhere, only with --dry-run, which only says
# what it would do (and needs `gh` with read access to the issues).
#
# Needs bash 4.4 or newer, curl, python3 and gh.
set -euo pipefail

cd "$(dirname "$0")/.."
source tool/check_lib.sh
need curl python3 gh

# This repository's issues: in GitHub Actions, GH_REPO says which; else the
# one origin points to (gh would pick among the remotes, upstream too).
if [[ -z "${GH_REPO:-}" ]]; then
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    export GH_REPO="${BASH_REMATCH[1]%.git}"
  fi
fi

readonly RELEASES=https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
readonly TITLE='A newer stable Flutter is out'

dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
# (An issue opened from someone's own account wouldn't be found again.)
if ! $dry_run && [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  echo "error: outside GitHub Actions, run this with --dry-run" >&2
  exit 2
fi

# Runs "$@", or with --dry-run only shows it.
act() {
  if $dry_run; then
    echo "(dry run) would run: $*"
  else
    "$@"
  fi
}

ours="$(ci_flutter_version)" || {
  echo "error: no FLUTTER_VERSION with an exact version (e.g. 3.50.0) in .github/workflows/dart.yml, or more than one" >&2
  exit 1
}

releases="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 "$RELEASES")"
# The current stable release, and when it came out.
latest_and_date="$(python3 -c '
import json, sys
try:
    releases = json.load(sys.stdin)
    current = releases["current_release"]["stable"]
    release = next(r for r in releases["releases"]
                   if r["hash"] == current and r["channel"] == "stable")
    print(release["version"], release["release_date"])
except (ValueError, KeyError, TypeError, StopIteration) as e:
    sys.exit(f"error: unexpected list of Flutter releases ({type(e).__name__}: {e})")
' <<<"$releases")"
read -r latest latest_date <<<"$latest_and_date"
echo "CI builds with Flutter $ours; the current stable release is $latest."

# The issues this script opened (by GitHub Actions, with its title), as
# lines "STATE NUMBER VERSION", newest first. VERSION is the release the
# issue names ("Flutter VERSION is out"); if its text no longer says, "-",
# or "-current" if it was opened after the current release came out (so it
# was about that one). STATE is open, closed, or put-off: closed as not
# planned while it named the current release (or, with its text changed,
# after that came out). (Not found through GitHub's search, which can lag
# behind by a minute.)
issues="$(gh issue list --state all --limit 1000 \
            --json number,title,author,state,stateReason,createdAt,closedAt,body)"
ours_issues="$(python3 -c '
import json, re, sys
from datetime import datetime

def when(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))

title, latest, released = sys.argv[1], sys.argv[2], when(sys.argv[3])
for i in sorted(json.load(sys.stdin), key=lambda i: -i["number"]):
    if i["title"] != title or \
            i["author"]["login"] not in ("app/github-actions", "github-actions"):
        continue
    named = re.match(r"Flutter (\S+) is out", i["body"] or "")
    named = named.group(1) if named else "-"
    if named == "-" and i.get("createdAt") and when(i["createdAt"]) >= released:
        named = "-current"
    state = i["state"].lower()
    if state == "closed" and i.get("stateReason") == "NOT_PLANNED" and (
            named in (latest, "-current") or named == "-" and i.get("closedAt")
            and when(i["closedAt"]) >= released):
        state = "put-off"
    print(state, i["number"], named)
' "$TITLE" "$latest" "$latest_date" <<<"$issues")"
# The open ones, newest first, and the release the newest names.
open_issues=() newest_named=""
while read -r state number named; do
  if [[ "$state" == open ]]; then
    open_issues+=("$number")
    if [[ -z "$newest_named" ]]; then newest_named=$named; fi
  fi
done <<<"$ours_issues"

if ! version_older "$ours" "$latest"; then
  if ((${#open_issues[@]} == 0)); then
    echo "Nothing to do."
  fi
  for number in "${open_issues[@]}"; do
    echo "Closing issue #$number: CI now builds with Flutter $ours."
    act gh issue close "$number" --reason completed \
      --comment "CI now builds with Flutter $ours."
  done
  exit 0
fi

body="Flutter $latest is out; CI builds with Flutter $ours (\`FLUTTER_VERSION\` in \`.github/workflows/dart.yml\`).

To move to it: change \`FLUTTER_VERSION\` and the minimums in \`pubspec.yaml\`, and line the build tools up with it (\`tool/check_build_tools.sh\` says what to change). What's new: https://docs.flutter.dev/release/release-notes

This issue is kept by \`tool/check_flutter_release.sh\`, which runs weekly and finds it by its title: it rewrites this text when a newer release comes out (notes go in comments), and closes the issue once \`FLUTTER_VERSION\` has caught up. To put the upgrade off until a newer release comes out, close it as not planned."

if ((${#open_issues[@]} == 0)); then
  if grep -q '^put-off ' <<<"$ours_issues"; then
    echo "Nothing to do: the issue about Flutter $latest was closed as not planned."
  else
    echo "Opening an issue: Flutter $latest is out."
    act gh issue create --title "$TITLE" --body "$body"
  fi
  exit 0
fi

# The newest open one is kept; any other is closed (opened twice somehow).
issue="${open_issues[0]}"
for number in "${open_issues[@]:1}"; do
  echo "Closing issue #$number as a duplicate of #$issue."
  act gh issue close "$number" --duplicate-of "$issue"
done
# Its text is only rewritten for a newer release (so notes added to it
# meanwhile are kept until then), and not at all if it no longer names one:
# someone changed it.
if [[ "$newest_named" == "$latest" ]]; then
  echo "Issue #$issue already says so."
elif [[ "$newest_named" == -current ]]; then
  echo "Issue #$issue's text was changed by hand; it was opened about Flutter $latest."
elif [[ "$newest_named" == - ]]; then
  # Someone changed its text: that stays, but it is told of a newer
  # release (once: whether it was is in its comments).
  comments="$(gh issue view "$issue" --json comments)"
  if python3 -c '
import json, sys
sys.exit(0 if any(c["body"].strip() == sys.argv[1]
                  for c in json.load(sys.stdin)["comments"]) else 1)
' "Flutter $latest is out now." <<<"$comments"; then
    echo "Issue #$issue's text was changed by hand; it was told of Flutter $latest already."
  else
    echo "Issue #$issue's text was changed by hand; leaving it, but commenting: Flutter $latest is out."
    act gh issue comment "$issue" --body "Flutter $latest is out now."
  fi
elif ! version_older "$newest_named" "$latest"; then
  # (Flutter can withdraw a release.)
  echo "Issue #$issue names Flutter $newest_named, newer than the current stable release; leaving it."
else
  # (Editing the text notifies nobody; a comment does. The comment first:
  # if editing then fails, the next run tries again, and only comments
  # twice.)
  echo "Updating issue #$issue: Flutter $latest is out."
  act gh issue comment "$issue" --body "Flutter $latest is out now."
  act gh issue edit "$issue" --body "$body"
fi

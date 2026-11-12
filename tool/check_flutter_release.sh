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
# runs); the issue's text is the script's, notes go in comments. Once
# FLUTTER_VERSION has caught up, it closes it. To put the upgrade off until
# a newer release than the one the issue names, close it as "not planned".
#
# It only touches issues opened by GitHub Actions: it runs in the weekly
# workflow (.github/workflows/flutter_release.yml), with that workflow's
# token (`issues: write`). Elsewhere, only with --dry-run, which only says
# what it would do (and needs `gh` with read access to the issues).
set -euo pipefail

cd "$(dirname "$0")/.."

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

# (Quoted or not, with or without a comment after it.)
ours="$(sed -n 's/^[[:space:]]*FLUTTER_VERSION:[[:space:]]*["'\'']\{0,1\}\([0-9][0-9.]*\)["'\'']\{0,1\}[[:space:]]*\(#.*\)\{0,1\}$/\1/p' \
  .github/workflows/dart.yml)"
[[ -n "$ours" ]] || {
  echo "error: no FLUTTER_VERSION with an exact version (e.g. 3.50.0) in .github/workflows/dart.yml" >&2
  exit 1
}

releases="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 "$RELEASES")"
latest="$(python3 -c '
import json, sys
try:
    releases = json.load(sys.stdin)
    current = releases["current_release"]["stable"]
    print(next(r["version"] for r in releases["releases"]
               if r["hash"] == current and r["channel"] == "stable"))
except (ValueError, KeyError, TypeError, StopIteration) as e:
    sys.exit(f"error: unexpected list of Flutter releases ({type(e).__name__}: {e})")
' <<<"$releases")"
echo "CI builds with Flutter $ours; the current stable release is $latest."

# The issues this script opened (by GitHub Actions, with its title), as
# lines "STATE NUMBER VERSION", newest first. STATE is open, closed or
# put-off (closed as not planned); VERSION is the release the issue names
# ("Flutter VERSION is out"), or "-" if its text no longer says. (Not found
# through GitHub's search, which can lag behind by a minute.)
issues="$(gh issue list --state all --limit 1000 \
            --json number,title,author,state,stateReason,body)"
ours_issues="$(python3 -c '
import json, re, sys
title = sys.argv[1]
for i in sorted(json.load(sys.stdin), key=lambda i: -i["number"]):
    if i["title"] != title or \
            i["author"]["login"] not in ("app/github-actions", "github-actions"):
        continue
    named = re.match(r"Flutter (\S+) is out", i["body"] or "")
    state = i["state"].lower()
    if state == "closed" and i.get("stateReason") == "NOT_PLANNED":
        state = "put-off"
    print(state, i["number"], named.group(1) if named else "-")
' "$TITLE" <<<"$issues")"
open_issues=() open_named=()
while read -r state number named; do
  if [[ "$state" == open ]]; then
    open_issues+=("$number")
    open_named+=("$named")
  fi
done <<<"$ours_issues"

if [[ "$(printf '%s\n%s\n' "$ours" "$latest" | sort -V | tail -n 1)" == "$ours" ]]; then
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

This issue is kept by \`tool/check_flutter_release.sh\`, which runs weekly: it rewrites this text when a newer release comes out (notes go in comments), and closes the issue once \`FLUTTER_VERSION\` has caught up. To put the upgrade off until a newer release than this one, close it as not planned."

if ((${#open_issues[@]} == 0)); then
  if awk -v v="$latest" '$1 == "put-off" && $3 == v { found = 1 } END { exit !found }' \
       <<<"$ours_issues"; then
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
  echo "Closing issue #$number: #$issue says the same."
  act gh issue close "$number" --reason duplicate --comment "Closed: #$issue says the same."
done
# Its text is only rewritten for a newer release, so notes added to it
# meanwhile are kept until then.
if [[ "${open_named[0]}" == "$latest" ]]; then
  echo "Issue #$issue already says so."
else
  # (Editing the text notifies nobody; a comment does.)
  echo "Updating issue #$issue: Flutter $latest is out."
  act gh issue edit "$issue" --body "$body"
  act gh issue comment "$issue" --body "Flutter $latest is out now."
fi

#!/usr/bin/env bash
# Keeps an issue open while a newer stable Flutter is out than the one CI
# builds with.
#
#   tool/check_flutter_release.sh [--dry-run]
#
# Compares FLUTTER_VERSION in .github/workflows/dart.yml with Flutter's
# current stable release, from Flutter's list of releases. If that is newer,
# it opens an issue saying so, or updates the one already open (one issue,
# however many runs). Once FLUTTER_VERSION has caught up, it closes it.
#
# Needs `gh` with access to the repository's issues (in CI, the workflow's
# token with `issues: write`). With --dry-run it only says what it would do.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly RELEASES=https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
readonly TITLE='A newer stable Flutter is out'

dry_run=false
[[ "${1:-}" == --dry-run ]] && dry_run=true

# Runs "$@", or with --dry-run only shows it.
act() {
  if $dry_run; then
    echo "(dry run) would run: $*"
  else
    "$@"
  fi
}

ours="$(sed -n 's/^ *FLUTTER_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' \
  .github/workflows/dart.yml)"
[[ -n "$ours" ]] ||
  { echo "error: no FLUTTER_VERSION in .github/workflows/dart.yml" >&2; exit 1; }

latest="$(curl -fsSL --retry 3 "$RELEASES" | python3 -c '
import json, sys
releases = json.load(sys.stdin)
current = releases["current_release"]["stable"]
print(next(r["version"] for r in releases["releases"]
           if r["hash"] == current and r["channel"] == "stable"))
')"
echo "CI builds with Flutter $ours; the current stable release is $latest."

# The open issue this script keeps, if any (its number). (Not found through
# GitHub's search, which can lag behind by a minute.)
issue="$(gh issue list --state open --limit 1000 --json number,title \
  --jq ".[] | select(.title == \"$TITLE\") | .number" | head -n 1)"

newest="$(printf '%s\n%s\n' "$ours" "$latest" | sort -V | tail -n 1)"
if [[ "$latest" == "$ours" || "$newest" == "$ours" ]]; then
  if [[ -n "$issue" ]]; then
    echo "Closing issue #$issue: CI now builds with Flutter $ours."
    act gh issue close "$issue" --comment "CI now builds with Flutter $ours."
  else
    echo "Nothing to do."
  fi
  exit 0
fi

body="Flutter $latest is out; CI builds with Flutter $ours (\`FLUTTER_VERSION\` in \`.github/workflows/dart.yml\`).

To move to it: change \`FLUTTER_VERSION\` and the minimums in \`pubspec.yaml\`, and line the build tools up with it (\`tool/check_build_tools.sh\` says what to change). What's new: https://docs.flutter.dev/release/release-notes

This issue is kept by \`tool/check_flutter_release.sh\`, which runs weekly, and is closed once \`FLUTTER_VERSION\` has caught up."

if [[ -z "$issue" ]]; then
  echo "Opening an issue: Flutter $latest is out."
  act gh issue create --title "$TITLE" --body "$body"
elif [[ "$(gh issue view "$issue" --json body --jq .body)" != "$body" ]]; then
  echo "Updating issue #$issue: Flutter $latest is out."
  act gh issue edit "$issue" --body "$body"
else
  echo "Issue #$issue already says so."
fi

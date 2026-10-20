#!/bin/bash
# Tests for release-notes.sh and check-notes.sh in a throwaway git repository.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

cd "$tmp"
git init -q -b main
git config user.email t@example.com
git config user.name Test
git commit -q --allow-empty -m "Initial"
git tag v1.0.0
git commit -q --allow-empty -m "Add one-click updates" -m "New versions show up when the app opens.

Co-Authored-By: Someone <s@example.com>"
git commit -q --allow-empty -m "wip"
git commit -q --allow-empty -m "Fix wrapping in the notes card."

notes="$("$here/release-notes.sh")"
printf '%s\n' "$notes" | grep -q '^## Fix wrapping in the notes card\.$' || fail "headline is the newest subject"
printf '%s\n' "$notes" | grep -q '^- \*\*Add one-click updates\.\*\* New versions show up when the app opens\.$' || fail "bullet with body"
printf '%s\n' "$notes" | grep -q '^- \*\*Fix wrapping in the notes card\.\*\*$' || fail "bullet without body keeps its full stop once"
printf '%s\n' "$notes" | grep -qi 'wip' && fail "wip commits are skipped"
printf '%s\n' "$notes" | grep -qi 'Co-Authored' && fail "trailers are skipped"
printf '%s\n' "$notes" | grep -qi 'Initial' && fail "commits before the tag are skipped"

custom="$("$here/release-notes.sh" --headline "Fetch now updates itself" --since v1.0.0)"
printf '%s\n' "$custom" | head -1 | grep -q '^## Fetch now updates itself$' || fail "custom headline"

"$here/check-notes.sh" - <<< "$notes" || fail "generated notes pass the check"
if "$here/check-notes.sh" - <<< "" 2>/dev/null; then fail "empty notes fail"; fi
if "$here/check-notes.sh" - <<< "## Only a heading" 2>/dev/null; then fail "heading-only notes fail"; fi
if "$here/check-notes.sh" - <<< $'## Head\n- TODO write notes here please' 2>/dev/null; then fail "placeholders fail"; fi
if "$here/check-notes.sh" - <<< "- ok" 2>/dev/null; then fail "tiny notes fail"; fi

git tag v1.1.0
if "$here/release-notes.sh" 2>/dev/null; then fail "no commits since the last tag is an error"; fi

echo "release-notes scripts: all passed"

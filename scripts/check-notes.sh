#!/bin/bash
# Fails when release notes would leave the update splash with nothing useful to say.
# For release scripts to call before publishing.
#
#   scripts/check-notes.sh notes.md             # a file
#   some-command | scripts/check-notes.sh -     # stdin
#   scripts/check-notes.sh --release owner/repo-releases v1.5.3   # a published release body (needs gh)
#
# Exit 0 when the notes are fine; exit 1 with the reason on stderr otherwise.
set -euo pipefail

if [ "${1:-}" = "--release" ]; then
  [ $# -eq 3 ] || { echo "usage: $0 --release owner/repo tag" >&2; exit 2; }
  notes="$(gh release view "$3" --repo "$2" --json body --jq .body)"
elif [ "${1:-}" = "-" ]; then
  notes="$(cat)"
elif [ -n "${1:-}" ]; then
  [ -f "$1" ] || { echo "no such file: $1" >&2; exit 2; }
  notes="$(cat "$1")"
else
  echo "usage: $0 <file|-|--release owner/repo tag>" >&2
  exit 2
fi

stripped="$(printf '%s' "$notes" | tr -d '[:space:]')"
if [ -z "$stripped" ]; then
  echo "release notes are empty: the update window would only say 'Improvements and fixes.'" >&2
  exit 1
fi

# At least one real line that is not a heading.
content="$(printf '%s\n' "$notes" | grep -v '^[[:space:]]*#' | grep -c '[[:alnum:]]' || true)"
if [ "$content" -lt 1 ]; then
  echo "release notes have a heading but no bullets or text" >&2
  exit 1
fi

if printf '%s' "$notes" | grep -Eiq 'TODO|TBD|FIXME|lorem ipsum|<[^>]*describe[^>]*>'; then
  echo "release notes still contain a placeholder (TODO/TBD/FIXME)" >&2
  exit 1
fi

if [ "${#stripped}" -lt 20 ]; then
  echo "release notes are too short to be useful (${#stripped} characters)" >&2
  exit 1
fi

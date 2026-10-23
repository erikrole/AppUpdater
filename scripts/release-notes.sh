#!/bin/bash
# Turns the commits since the last tag into the release body the update splash reads.
#
#   scripts/release-notes.sh [--since TAG] [--headline "One line"] [--repo DIR]
#
# Output (Markdown, stdout):
#   ## <headline>
#   - **Subject.** First paragraph of the commit body, if there is one.
#
# Without --since it uses the most recent tag (or the whole history if there are no tags).
# Without --headline it uses the newest commit subject. Merge commits, "wip"/"fixup" commits and
# trailer lines (Co-Authored-By, Signed-off-by) are left out.
set -euo pipefail

since=""
headline=""
repo="."
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="$2"; shift 2 ;;
    --headline) headline="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$repo"
if [ -z "$since" ]; then
  since="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi
range="HEAD"
[ -n "$since" ] && range="$since..HEAD"

shas="$(git log --no-merges --reverse --format=%H "$range")"
if [ -z "$shas" ]; then
  echo "no commits since ${since:-the start}" >&2
  exit 1
fi

# "Fix the wrapping" -> "Fix the wrapping." so the bold lead reads as a sentence.
sentence() {
  case "$1" in *[.!?]) printf '%s' "$1" ;; *) printf '%s.' "$1" ;; esac
}

bullets=""
newest_subject=""
while IFS= read -r sha; do
  subject="$(git log -1 --format=%s "$sha")"
  case "$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')" in
    wip*|fixup*|squash*|"merge "*|"bump "*|"release "*) continue ;;
  esac
  newest_subject="$subject"
  # First paragraph of the body, minus trailers, on one line.
  body="$(git log -1 --format=%b "$sha" \
    | awk 'BEGIN{p=0} /^[[:space:]]*$/ {if (p) exit; next} /^(Co-Authored-By|Signed-off-by|Generated with|🤖)/ {next} {p=1; print}' \
    | tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"
  line="- **$(sentence "$subject")**"
  [ -n "$body" ] && line="$line $body"
  bullets="$bullets$line"$'\n'
done <<< "$shas"

if [ -z "$bullets" ]; then
  echo "every commit since ${since:-the start} was filtered out; write the notes by hand" >&2
  exit 1
fi

[ -z "$headline" ] && headline="$newest_subject"
printf '## %s\n\n%s' "$headline" "$bullets"

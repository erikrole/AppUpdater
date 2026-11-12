#!/usr/bin/env bash
# Check that a public release serves the exact archive validated before publication.
set -euo pipefail

repo="${1:?Usage: verify-published-release.sh OWNER/REPO TAG ARCHIVE}"
tag="${2:?Missing tag}"
archive="${3:?Missing validated archive}"
name="${archive##*/}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.(zip|dmg)$ ]]
[[ -f "$archive" ]]

download="$(mktemp)"
trap 'rm -f "$download"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --max-time 300 --output "$download" \
    "https://github.com/$repo/releases/download/$tag/$name"
cmp -s "$archive" "$download" || {
    echo "Published $name differs from the verified archive." >&2
    exit 1
}
printf 'Verified %s/%s %s\n' "$repo" "$tag" "$name"

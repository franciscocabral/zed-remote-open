#!/usr/bin/env bash
# Prints the next release version, or nothing if no release is necessary.
#
# - No tag yet: the version in the VERSION file.
# - Else, from the Conventional Commits since the last tag:
#   "type!:" or "BREAKING CHANGE:" = major, "feat:" = minor, "fix:"/"perf:" = patch.
# - A VERSION file with a higher version wins (to make a manual release).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

file_version=$(tr -d '[:space:]' <VERSION)
last_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
if [[ -z $last_tag ]]; then
    echo "$file_version"
    exit 0
fi

greater() { # A B: returns 0 if A > B
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

last=${last_tag#v}
log=$(git log --format='%s%n%b' "$last_tag..HEAD")
IFS=. read -r major minor patch <<<"$last"
if grep -qE '^[a-z]+(\([^)]*\))?!:|^BREAKING[ -]CHANGE:' <<<"$log"; then
    next="$((major + 1)).0.0"
elif grep -qE '^feat(\([^)]*\))?:' <<<"$log"; then
    next="$major.$((minor + 1)).0"
elif grep -qE '^(fix|perf)(\([^)]*\))?:' <<<"$log"; then
    next="$major.$minor.$((patch + 1))"
else
    next=""
fi

if greater "$file_version" "$last" && { [[ -z $next ]] || greater "$file_version" "$next"; }; then
    next=$file_version
fi
echo "$next"

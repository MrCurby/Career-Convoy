#!/usr/bin/env bash
# Release versions, from the release tags (v<x.y.z>). The code itself only says "dev": a release
# stamps its version into the package (tools/package.sh).
#
#   tools/version.sh                  the last release, e.g. 0.34.0 (0.0.0 before the first one)
#   tools/version.sh patch            the next one: 0.34.1 (fixes)
#   tools/version.sh minor            0.35.0 (new features)
#   tools/version.sh major            1.0.0 (a big update)
#   tools/version.sh 1.2.0            exactly this one: higher than the last, not released yet
set -euo pipefail
cd "$(dirname "$0")/.."
LAST=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)
LAST="${LAST#v}"
LAST="${LAST:-0.0.0}"
IFS=. read -r a b c <<<"$LAST"
case "${1:-}" in
	"") echo "$LAST"; exit 0 ;;
	patch) NEW="$a.$b.$((c + 1))" ;;
	minor) NEW="$a.$((b + 1)).0" ;;
	major) NEW="$((a + 1)).0.0" ;;
	*)
		NEW="$1"
		if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "Not a version: $NEW (use x.y.z, e.g. 1.0.0)" >&2
			exit 1
		fi
		if [ "$NEW" = "$LAST" ] || [ "$(printf '%s\n%s\n' "$LAST" "$NEW" | sort -V | tail -n 1)" != "$NEW" ]; then
			echo "Version $NEW is not higher than the last release $LAST." >&2
			exit 1
		fi
		;;
esac
echo "$NEW"

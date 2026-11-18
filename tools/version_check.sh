#!/usr/bin/env bash
# Checks a pull request into main: if it changes the mod (client/ or Resources/), it must raise the
# version (tools/bump.sh), so merging builds a release. Otherwise the change would reach main
# without a release, and servers would never get it.
#
#   tools/version_check.sh [base]   base = the branch it goes into (default origin/main)
#
# A change of tools, tests or docs only needs no new version. A change of tools/server.sh needs a
# higher SCRIPT_REVISION in it (servers only replace their server.sh with a higher revision).
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:-origin/main}"
SCRIPT=tools/server.sh
revision_of() { sed -n 's/^SCRIPT_REVISION=\([0-9]*\).*/\1/p' | head -n 1; }
if [ -n "$(git diff --name-only "$(git merge-base "$BASE" HEAD)" HEAD -- "$SCRIPT")" ]; then
	R_NEW=$(revision_of <"$SCRIPT"); R_OLD=$(git show "$BASE:$SCRIPT" | revision_of)
	if [ "${R_NEW:-0}" -le "${R_OLD:-0}" ]; then
		echo "Version check failed: $SCRIPT changed, but SCRIPT_REVISION is still ${R_OLD:-0} – raise it." >&2
		exit 1
	fi
	echo "Version check: $SCRIPT revision ${R_OLD:-0} -> $R_NEW."
fi
SERVER=Resources/Server/SharedCareer/main.lua
version_of() { sed -n 's/^local VERSION = "\(.*\)"/\1/p'; }
NEW=$(version_of <"$SERVER")
OLD=$(git show "$BASE:$SERVER" | version_of)
CHANGED=$(git diff --name-only "$(git merge-base "$BASE" HEAD)" HEAD -- client Resources)
if [ -z "$CHANGED" ]; then
	echo "Version check: the mod is unchanged (only tools, tests or docs) – no new version needed."
	exit 0
fi
if [ "$NEW" = "$OLD" ]; then
	echo "Version check failed: the mod changed, but the version is still $OLD." >&2
	echo "Raise it with tools/bump.sh patch|minor|x.y.z, so merging builds a release." >&2
	exit 1
fi
if [ "$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -V | tail -n 1)" != "$NEW" ]; then
	echo "Version check failed: $NEW is lower than $OLD on main." >&2
	exit 1
fi
if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
	echo "Version check failed: release v$NEW exists already – pick a higher version." >&2
	exit 1
fi
echo "Version check: $OLD -> $NEW, merging builds release v$NEW."

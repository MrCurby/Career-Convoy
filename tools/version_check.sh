#!/usr/bin/env bash
# Checks a pull request into main:
# - only a release pull request (branch release/v<version>, opened by the "Prepare release"
#   workflow) changes the version, and only to a higher one that has no release yet. Merging it
#   publishes the release; other pull requests just collect on main until then.
# - a change of tools/server.sh needs a higher SCRIPT_REVISION in it (servers only replace their
#   server.sh with a higher revision).
#
#   tools/version_check.sh [base] [branch]   base = the branch it goes into (default origin/main),
#                                            branch = the pull request's branch (default: current)
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:-origin/main}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"
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
if [ "$NEW" = "$OLD" ]; then
	echo "Version check: still $OLD (raised by the \"Prepare release\" workflow)."
	exit 0
fi
if [[ "$BRANCH" != release/* ]]; then
	echo "Version check failed: the version changed ($OLD -> $NEW) outside a release pull request." >&2
	echo "Keep it at $OLD; the \"Prepare release\" workflow raises it." >&2
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
echo "Version check: $OLD -> $NEW, merging publishes release v$NEW."

#!/usr/bin/env bash
# Checks a pull request into main (the check "version"):
# - the version in the code stays "dev" (util.lua and main.lua): a release stamps its version into
#   the package (tools/package.sh, the Release workflow), nobody raises it by hand.
# - a change of tools/server.sh needs a higher SCRIPT_REVISION in it (servers only replace their
#   server.sh with a higher revision).
#
#   tools/version_check.sh [base]   base = the branch it goes into (default origin/main)
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
SERVER=$(sed -n 's/^local VERSION = "\(.*\)"$/\1/p' Resources/Server/CareerConvoy/main.lua)
CLIENT=$(sed -n 's/^M.VERSION = "\(.*\)"$/\1/p' client/lua/ge/extensions/careerConvoy/util.lua)
if [ "$SERVER" != "dev" ] || [ "$CLIENT" != "dev" ]; then
	echo "Version check failed: the version in the code must stay \"dev\" (server: $SERVER, client: $CLIENT)." >&2
	echo "A release sets it: Actions → Release → Run workflow (docs/releasing.md)." >&2
	exit 1
fi
echo "Version check: the code says \"dev\"; the next release is $(tools/version.sh patch) or higher."

#!/usr/bin/env bash
# Builds the package for rolling out: SharedCareer-<version>.zip
# Contents: Resources/Client/SharedCareer.zip, Resources/Server/SharedCareer/main.lua, README.md,
#           server.sh (server control, lands in the server folder when unpacked)
# (no config/ – settings on the server stay untouched when unpacking).
#
#   tools/package.sh 0.35.0   release package (the Release workflow, see tools/version.sh)
#   tools/package.sh --dev    dev build for a test server: the last release's version plus
#                             -dev.<commit>, e.g. 0.34.0-dev.ab12cd3
# The code says VERSION "dev"; the version is stamped into util.lua and main.lua (shown in the
# game and on the server) only for the build, and the files are restored afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
	--dev) VERSION="$(tools/version.sh)-dev.$(git rev-parse --short=7 HEAD)" ;;
	[0-9]*.[0-9]*.[0-9]*) VERSION="$1" ;;
	*) echo "Usage: tools/package.sh <version>|--dev" >&2; exit 1 ;;
esac
SERVER=Resources/Server/SharedCareer/main.lua
CLIENT=client/lua/ge/extensions/sharedCareer/util.lua
tools/test.sh >/dev/null
SAVED="$(mktemp -d)"
cp "$SERVER" "$SAVED/main.lua"
cp "$CLIENT" "$SAVED/util.lua"
trap 'cp "$SAVED/main.lua" "$SERVER"; cp "$SAVED/util.lua" "$CLIENT"; rm -rf "$SAVED"' EXIT
sed -i "s/^local VERSION = \".*\"/local VERSION = \"$VERSION\"/" "$SERVER"
sed -i "s/^M.VERSION = \".*\"/M.VERSION = \"$VERSION\"/" "$CLIENT"
if ! grep -q "^local VERSION = \"$VERSION\"" "$SERVER" || ! grep -q "^M.VERSION = \"$VERSION\"" "$CLIENT"; then
	echo "Could not stamp the version $VERSION into $SERVER and $CLIENT" >&2
	exit 1
fi
tools/build.sh >/dev/null
rm -f SharedCareer-*.zip
cp tools/server.sh server.sh && chmod +x server.sh
zip -qr "SharedCareer-$VERSION.zip" server.sh Resources/Client/SharedCareer.zip "$SERVER" README.md
rm -f server.sh
echo "built: SharedCareer-$VERSION.zip (tests passed)"

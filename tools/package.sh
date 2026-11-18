#!/usr/bin/env bash
# Builds the package for rolling out: SharedCareer-<version>.zip
# Contents: Resources/Client/SharedCareer.zip, Resources/Server/SharedCareer/main.lua, README.md,
#           server.sh (server control, lands in the server folder when unpacked)
# (no config/ – settings on the server stay untouched when unpacking).
#
#   tools/package.sh         release package, version as in util.lua / main.lua
#   tools/package.sh --dev   dev build for a test server: version <version>-dev.<commit>, e.g.
#                            0.16.0-dev.ab12cd3 (shown in the game and on the server). The files
#                            are only stamped for the build and restored afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=0
case "${1:-}" in
	--dev) DEV=1 ;;
	"") ;;
	*) echo "Usage: tools/package.sh [--dev]" >&2; exit 1 ;;
esac
SERVER=Resources/Server/SharedCareer/main.lua
CLIENT=client/lua/ge/extensions/sharedCareer/util.lua
tools/test.sh >/dev/null
VERSION=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' "$SERVER")
CLIENT_VERSION=$(sed -n 's/^M.VERSION = "\(.*\)"/\1/p' "$CLIENT")
if [ "$VERSION" != "$CLIENT_VERSION" ]; then
	echo "Versions do not match: server $VERSION, client $CLIENT_VERSION" >&2
	exit 1
fi
if [ "$DEV" = 1 ]; then
	VERSION="$VERSION-dev.$(git rev-parse --short=7 HEAD)"
	SAVED="$(mktemp -d)"
	cp "$SERVER" "$SAVED/main.lua"
	cp "$CLIENT" "$SAVED/util.lua"
	trap 'cp "$SAVED/main.lua" "$SERVER"; cp "$SAVED/util.lua" "$CLIENT"; rm -rf "$SAVED"' EXIT
	sed -i "s/^local VERSION = \".*\"/local VERSION = \"$VERSION\"/" "$SERVER"
	sed -i "s/^M.VERSION = \".*\"/M.VERSION = \"$VERSION\"/" "$CLIENT"
fi
tools/build.sh >/dev/null
rm -f SharedCareer-*.zip
cp tools/server.sh server.sh && chmod +x server.sh
zip -qr "SharedCareer-$VERSION.zip" server.sh Resources/Client/SharedCareer.zip "$SERVER" README.md
rm -f server.sh
echo "built: SharedCareer-$VERSION.zip (tests passed)"

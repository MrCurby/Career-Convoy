#!/usr/bin/env bash
# Builds the package for rolling out: SharedCareer-<version>.zip
# Contents: Resources/Client/SharedCareer.zip, Resources/Server/SharedCareer/main.lua, README.md,
#           server.sh (server control, lands in the server folder when unpacked)
# (no config/ – settings on the server stay untouched when unpacking).
set -euo pipefail
cd "$(dirname "$0")/.."
tools/test.sh >/dev/null
tools/build.sh >/dev/null
VERSION=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' Resources/Server/SharedCareer/main.lua)
CLIENT_VERSION=$(sed -n 's/^M.VERSION = "\(.*\)"/\1/p' client/lua/ge/extensions/sharedCareer/util.lua)
if [ "$VERSION" != "$CLIENT_VERSION" ]; then
	echo "Versions do not match: server $VERSION, client $CLIENT_VERSION" >&2
	exit 1
fi
rm -f SharedCareer-*.zip
cp tools/server.sh server.sh && chmod +x server.sh
zip -qr "SharedCareer-$VERSION.zip" server.sh Resources/Client/SharedCareer.zip Resources/Server/SharedCareer/main.lua README.md
rm -f server.sh
echo "built: SharedCareer-$VERSION.zip (tests passed)"

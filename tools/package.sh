#!/usr/bin/env bash
# Baut das Paket zum Ausrollen: SharedCareer-<version>.zip
# Inhalt: Resources/Client/SharedCareer.zip, Resources/Server/SharedCareer/main.lua, README.md,
#         server.sh (Server-Steuerung, landet beim Entpacken im Server-Ordner)
# (keine config/ – Einstellungen auf dem Server bleiben beim Entpacken unangetastet).
set -euo pipefail
cd "$(dirname "$0")/.."
tools/test.sh >/dev/null
tools/build.sh >/dev/null
VERSION=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' Resources/Server/SharedCareer/main.lua)
CLIENT_VERSION=$(sed -n 's/^M.VERSION = "\(.*\)"/\1/p' client/lua/ge/extensions/sharedCareer/util.lua)
if [ "$VERSION" != "$CLIENT_VERSION" ]; then
	echo "Versionen passen nicht: Server $VERSION, Client $CLIENT_VERSION" >&2
	exit 1
fi
rm -f SharedCareer-*.zip
cp tools/server.sh server.sh && chmod +x server.sh
zip -qr "SharedCareer-$VERSION.zip" server.sh Resources/Client/SharedCareer.zip Resources/Server/SharedCareer/main.lua README.md
rm -f server.sh
echo "gebaut: SharedCareer-$VERSION.zip (Tests bestanden)"

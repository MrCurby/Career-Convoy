#!/usr/bin/env bash
# Neue Version setzen (Client util.lua + Server main.lua), Tests laufen lassen.
#
#   tools/bump.sh 0.8.5      Version auf 0.8.5 setzen
#   tools/bump.sh patch      0.8.4 -> 0.8.5   (Fehlerbehebung)
#   tools/bump.sh minor      0.8.4 -> 0.9.0   (neue Funktion)
#
# Danach committen und auf main pushen -> GitHub baut das Release v<version> automatisch.
set -euo pipefail
cd "$(dirname "$0")/.."

CLIENT=client/lua/ge/extensions/sharedCareer/util.lua
SERVER=Resources/Server/SharedCareer/main.lua
OLD=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' "$SERVER")

case "${1:-}" in
	patch) IFS=. read -r a b c <<< "$OLD"; NEW="$a.$b.$((c + 1))" ;;
	minor) IFS=. read -r a b c <<< "$OLD"; NEW="$a.$((b + 1)).0" ;;
	[0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
	*) echo "Aufruf: tools/bump.sh <x.y.z|patch|minor>   (aktuell: $OLD)"; exit 1 ;;
esac

sed -i "s/^M.VERSION = \".*\"/M.VERSION = \"$NEW\"/" "$CLIENT"
sed -i "s/^local VERSION = \".*\"/local VERSION = \"$NEW\"/" "$SERVER"
echo "Version: $OLD -> $NEW"
tools/test.sh >/dev/null && echo "Tests bestanden."
echo "Jetzt committen und pushen, z.B.:"
echo "  git commit -am \"SharedCareer $NEW\" && git push"

#!/usr/bin/env bash
# Set a new version (client util.lua + server main.lua) and run the tests.
#
#   tools/bump.sh 0.8.5      set the version to 0.8.5
#   tools/bump.sh patch      0.8.4 -> 0.8.5   (bug fix)
#   tools/bump.sh minor      0.8.4 -> 0.9.0   (new feature)
#
# Then commit and push to main -> GitHub builds the release v<version> automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

CLIENT=client/lua/ge/extensions/sharedCareer/util.lua
SERVER=Resources/Server/SharedCareer/main.lua
OLD=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' "$SERVER")

case "${1:-}" in
	patch) IFS=. read -r a b c <<< "$OLD"; NEW="$a.$b.$((c + 1))" ;;
	minor) IFS=. read -r a b c <<< "$OLD"; NEW="$a.$((b + 1)).0" ;;
	[0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
	*) echo "Usage: tools/bump.sh <x.y.z|patch|minor>   (current: $OLD)"; exit 1 ;;
esac

sed -i "s/^M.VERSION = \".*\"/M.VERSION = \"$NEW\"/" "$CLIENT"
sed -i "s/^local VERSION = \".*\"/local VERSION = \"$NEW\"/" "$SERVER"
echo "Version: $OLD -> $NEW"
tools/test.sh >/dev/null && echo "Tests passed."
echo "Now commit and push, for example:"
echo "  git commit -am \"SharedCareer $NEW\" && git push"

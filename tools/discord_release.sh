#!/usr/bin/env bash
# Posts a new release to a Discord channel through a webhook: a heading with the link to the
# release, then its notes. Discord allows 2000 characters per message, so long notes go out as
# several messages, split between lines. Mentions in the notes (@everyone, roles, users) don't ping.
#
#   DISCORD_WEBHOOK=<url> tools/discord_release.sh <version> <release url> <notes file>
#
# Without DISCORD_WEBHOOK it does nothing, so a fork without the secret still releases.
set -euo pipefail
VERSION="$1"
URL="$2"
NOTES="$3"
if [ -z "${DISCORD_WEBHOOK:-}" ]; then
	echo "Discord: no webhook (secret DISCORD_RELEASE_WEBHOOK) - nothing posted."
	exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
{
	echo "# Career-Convoy $VERSION"
	echo "<$URL>"
	echo
	cat "$NOTES"
} | awk -v dir="$dir" -v max=1900 '
	function flush() { if (buf != "") { n++; printf "%s", buf > (dir "/" sprintf("%03d", n)); close(dir "/" sprintf("%03d", n)); buf = "" } }
	{
		line = $0 "\n"
		while (length(line) > max) { flush(); buf = substr(line, 1, max); flush(); line = substr(line, max + 1) }
		if (length(buf) + length(line) > max) flush()
		buf = buf line
	}
	END { flush() }'

for part in "$dir"/*; do
	jq -n --rawfile content "$part" '{content: $content, allowed_mentions: {parse: []}}' |
		curl -fsS -H "Content-Type: application/json" --data-binary @- "$DISCORD_WEBHOOK" >/dev/null
	sleep 1 # stay below Discord's rate limit
done
echo "Discord: posted $(ls "$dir" | wc -l) message(s)."

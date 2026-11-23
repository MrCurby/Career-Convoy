#!/usr/bin/env bash
# Writes the notes of a new release: the install hint, then title and text of every pull request
# merged into main since the last release (tag v*). A version can collect several pull requests,
# e.g. a docs-only one merged without a new version, so all of them are listed.
#
#   tools/release_notes.sh > notes.md      (needs gh with GH_TOKEN, and the tags: fetch-depth 0)
#
# Left out of the release: HTML comments (the hints of .github/pull_request_template.md) and the
# "Generated with Claude Code" footer with its session link.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${GITHUB_REPOSITORY:-MrCurby/SharedCareer}"

echo "Install on a server: \`./server.sh update\` (downloads this release automatically)."

LAST=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)
RANGE="${LAST:+$LAST..}HEAD"

# Commits straight on main are the merge (or squash) commits of the pull requests.
PRS=$(git log --first-parent --format=%H "$RANGE" | while read -r sha; do
	gh api "repos/$REPO/commits/$sha/pulls" \
		--jq '.[] | select(.merged_at != null and .base.ref == "main") | .number'
done | awk '!seen[$0]++')

for pr in $PRS; do
	gh pr view "$pr" --repo "$REPO" --json title,body,url \
		--template '{{"\n## "}}{{.title}} ({{.url}}){{"\n\n"}}{{.body}}{{"\n"}}' |
		perl -0pe 's/<!--.*?-->[ \t]*\n?//gs' |
		grep -v -e '^🤖 Generated with \[Claude Code\]' -e '^https://claude\.ai/code/session_'
done

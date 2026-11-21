#!/usr/bin/env bash
# Syntax check + tests + Lua formatting. Needs luajit (client), lua5.3 (server), python3, node (UI apps)
# and stylua (formatting, see stylua.toml; skipped with a note when it isn't installed).
set -euo pipefail
cd "$(dirname "$0")/.."
for f in $(find client -name '*.lua'); do luajit -e "assert(loadfile('$f'))"; done
lua5.3 -e "assert(loadfile('Resources/Server/SharedCareer/main.lua'))"
luajit tests/client_test.lua
lua5.3 tests/server_test.lua
lua5.3 tests/config_update_test.lua
python3 tests/zones_test.py | grep -v 'computer zones enlarged'
# UI apps in node; then their clicks replayed against the real menu.lua
timeline="$(mktemp)"; trap 'rm -f "$timeline"' EXIT
node tests/ui_test.js "$timeline"
luajit tests/ui_replay.lua "$timeline"
# Lua formatted as in stylua.toml (fix with: stylua .)
if command -v stylua >/dev/null; then
	stylua --check . >/dev/null || { echo "Lua formatting: run 'stylua .' (see stylua.toml)" >&2; exit 1; }
	echo "Lua formatting: ok"
else
	echo "Lua formatting: skipped (stylua not installed)"
fi
# everything in English (comments, strings, docs) – see tests/language_check.py
python3 tests/language_check.py

#!/usr/bin/env bash
# Syntax check + tests. Needs luajit (client), lua5.3 (server) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in $(find client -name '*.lua'); do luajit -e "assert(loadfile('$f'))"; done
lua5.3 -e "assert(loadfile('Resources/Server/SharedCareer/main.lua'))"
luajit tests/client_test.lua
lua5.3 tests/server_test.lua
lua5.3 tests/config_update_test.lua
python3 tests/zones_test.py | grep -v 'computer zones enlarged'
# everything in English (comments, strings, docs) – see tests/language_check.py
python3 tests/language_check.py

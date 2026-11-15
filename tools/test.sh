#!/usr/bin/env bash
# Syntaxprüfung + Tests. Braucht luajit (Client) und lua5.3 (Server).
set -euo pipefail
cd "$(dirname "$0")/.."
for f in $(find client -name '*.lua'); do luajit -e "assert(loadfile('$f'))"; done
lua5.3 -e "assert(loadfile('Resources/Server/SharedCareer/main.lua'))"
luajit tests/client_test.lua
lua5.3 tests/server_test.lua
lua5.3 tests/config_update_test.lua
python3 tests/zones_test.py | grep -v Computer-Zonen

#!/usr/bin/env bash
# Packt den Client-Mod nach Resources/Client/SharedCareer.zip
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources/Client
rm -f Resources/Client/SharedCareer.zip
(cd client && zip -qr -X ../Resources/Client/SharedCareer.zip lua scripts levels ui)
echo "gebaut: Resources/Client/SharedCareer.zip"

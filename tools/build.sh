#!/usr/bin/env bash
# Packs the client mod into Resources/Client/SharedCareer.zip
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources/Client
rm -f Resources/Client/SharedCareer.zip
(cd client && zip -qr -X ../Resources/Client/SharedCareer.zip lua scripts levels ui)
echo "built: Resources/Client/SharedCareer.zip"

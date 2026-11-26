#!/usr/bin/env bash
# Packs the client mod into Resources/Client/CareerConvoy.zip
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources/Client
rm -f Resources/Client/CareerConvoy.zip
(cd client && zip -qr -X ../Resources/Client/CareerConvoy.zip lua scripts levels ui)
echo "built: Resources/Client/CareerConvoy.zip"

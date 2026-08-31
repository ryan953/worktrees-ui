#!/bin/bash
# Render the app icon to the given .icns path.
set -euo pipefail
OUT="${1:?usage: make-icon.sh <output.icns>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$(dirname "$OUT")"
swift "$DIR/make-icon.swift" "$OUT"

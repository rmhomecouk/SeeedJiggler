#!/bin/bash
# Compile the app into build/SeeedJiggler (needs Xcode command line tools: xcode-select --install)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc -O -o "$REPO/build/SeeedJiggler" "$REPO/menubar/SeeedJiggler.swift" -framework AppKit -framework IOKit
echo "Built $REPO/build/SeeedJiggler"

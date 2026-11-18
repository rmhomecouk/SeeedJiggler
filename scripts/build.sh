#!/bin/bash
# Compile the host service into build/seeedjiggler (needs Xcode command line tools: xcode-select --install)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO/build"
clang -O2 -Wall -Wextra -o "$REPO/build/seeedjiggler" "$REPO/host/seeedjiggler.c" \
  -framework IOKit -framework CoreFoundation
echo "Built $REPO/build/seeedjiggler"

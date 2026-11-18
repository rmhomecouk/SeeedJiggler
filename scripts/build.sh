#!/bin/bash
# Compile the app into build/SeeedJiggler (needs Xcode command line tools: xcode-select --install)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO/build"
# Version = short commit (plus "-dirty" for uncommitted changes) and build date, embedded as the binary's Info.plist
# (rev-parse, not describe: describe switches format as soon as a tag exists)
VER="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$REPO" update-index -q --refresh 2>/dev/null || true   # stat-only changes are not "dirty"
git -C "$REPO" diff-index --quiet HEAD -- 2>/dev/null || VER="$VER-dirty"
cat > "$REPO/build/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.seeedjiggler</string>
  <key>CFBundleName</key><string>SeeedJiggler</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$(date +%Y-%m-%d)</string>
</dict></plist>
PL
# explicit target: otherwise the minimum macOS version is the build machine's, and a release built on a new runner
# could refuse to start on an older Mac
swiftc -O -target arm64-apple-macos13.0 -o "$REPO/build/SeeedJiggler" "$REPO/app/SeeedJiggler.swift" -framework AppKit -framework IOKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$REPO/build/Info.plist"
echo "Built $REPO/build/SeeedJiggler"

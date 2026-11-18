#!/bin/bash
# Stop SeeedJiggler and remove its LaunchAgent (and the run-from copy install.sh made outside the repo, if any).
# With the app gone the board falls back to its own watchdog jiggle after 30 s of silence.
set -euo pipefail
LABEL="com.seeedjiggler"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$(plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true)"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
case "$BIN" in ""|"$REPO"/*) ;; *) rm -f "$BIN" ;; esac
rm -rf "$HOME/Applications/SeeedJiggler.app"
echo "Removed $LABEL"

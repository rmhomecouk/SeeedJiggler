#!/bin/bash
# Remove the SeeedJiggler LaunchAgent. The board then falls back to its own watchdog jiggle.
set -euo pipefail
LABEL="com.seeedjiggler"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed $LABEL"

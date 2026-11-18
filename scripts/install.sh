#!/bin/bash
# Build SeeedJiggler, start it now, and start it at every login (per-user LaunchAgent, no logs; restarted after a crash,
# but Quit in its menu stays quit). The same can be switched on and off from the app's "Start at login" item.
#   BIN_DIR=$HOME/.local/bin scripts/install.sh     # choose where the run-from copy goes
set -euo pipefail

LABEL="com.seeedjiggler"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/build/SeeedJiggler"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
DEST="${BIN_DIR:-}"
# A LaunchAgent whose binary sits in ~/Documents, ~/Desktop or ~/Downloads can hang at launch (macOS file-access
# protection; see docs/how-it-works.md), so from there the binary is copied to ~/.local/bin (or $BIN_DIR) and run from the copy.
case "$REPO" in "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*) DEST="${DEST:-$HOME/.local/bin}" ;; esac

"$REPO/scripts/build.sh"
# migrate from the earlier label (com.seeedjiggler.menu): stop and remove it
launchctl bootout "$DOMAIN/com.seeedjiggler.menu" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.seeedjiggler.menu.plist"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
if [ -n "$DEST" ]; then mkdir -p "$DEST"; rm -f "$DEST/SeeedJiggler"; cp "$BIN" "$DEST/SeeedJiggler"; BIN="$DEST/SeeedJiggler"; fi
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PL
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $LABEL running $BIN. Look for the mouse icon in the menu bar."

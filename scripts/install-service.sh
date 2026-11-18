#!/bin/bash
# Install SeeedJiggler's idle-aware service as a per-user macOS LaunchAgent.
# Starts at login, restarts if it dies. Re-run to apply new settings or after moving the repo.
#   IDLE_SECS=180 JIGGLE_EVERY=60 scripts/install-service.sh
set -euo pipefail

LABEL="com.seeedjiggler"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(command -v python3)" || { echo "python3 not found" >&2; exit 1; }
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/SeeedJiggler.log"
DOMAIN="gui/$(id -u)"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>-I</string>
    <string>$REPO/host/idlejiggle.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>IDLE_SECS</key><string>${IDLE_SECS:-120}</string>
    <key>JIGGLE_EVERY</key><string>${JIGGLE_EVERY:-45}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PL

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"
echo "Installed $LABEL (idle ${IDLE_SECS:-120}s, jiggle every ${JIGGLE_EVERY:-45}s)"
echo "Log: $LOG"

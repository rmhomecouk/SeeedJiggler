#!/bin/bash
# Build and install SeeedJiggler's idle-aware service as a per-user macOS LaunchAgent.
# Starts at login, restarts if it dies. Re-run to apply new settings or after moving the repo.
#   IDLE_SECS=180 JIGGLE_EVERY=60 scripts/install-service.sh
set -euo pipefail

LABEL="com.seeedjiggler"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/build/seeedjiggler"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

"$REPO/scripts/build.sh"
mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# No StandardOutPath/StandardErrorPath log files: output goes to /dev/null, nothing is written at runtime.
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
  <key>EnvironmentVariables</key>
  <dict>
    <key>IDLE_SECS</key><string>${IDLE_SECS:-120}</string>
    <key>JIGGLE_EVERY</key><string>${JIGGLE_EVERY:-45}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>Nice</key><integer>10</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PL

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"
echo "Installed $LABEL (idle ${IDLE_SECS:-120}s, jiggle every ${JIGGLE_EVERY:-45}s). No logs are written."

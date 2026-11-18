#!/bin/bash
# Create ~/Applications/SeeedJiggler.app so SeeedJiggler can be started from Spotlight, Launchpad or Finder.
# The bundle is only a launcher: it starts the login-item job if there is one, else the installed program (so
# updates keep working), and has no Dock icon.
#   scripts/make-app.sh /path/to/the/program      (install.sh does this for you)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROG="${1:?usage: make-app.sh /path/to/SeeedJiggler}"
APP="$HOME/Applications/SeeedJiggler.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.seeedjiggler.launcher</string>
  <key>CFBundleName</key><string>SeeedJiggler</string>
  <key>CFBundleDisplayName</key><string>SeeedJiggler</string>
  <key>CFBundleExecutable</key><string>SeeedJiggler</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
# Launcher: start the real program as a separate background process and finish. (exec-ing into it would leave a program
# that LaunchServices does not know, and it would get no menu bar icon.) If it is missing, say so.
cat > "$APP/Contents/MacOS/SeeedJiggler" <<SH
#!/bin/sh
# If the login item is set up but not running (e.g. after Quit), start that job so launchd supervises the program.
JOB="gui/\$(id -u)/com.seeedjiggler"
if launchctl print "\$JOB" >/dev/null 2>&1 && ! launchctl print "\$JOB" 2>/dev/null | grep -q "state = running"; then
  launchctl kickstart "\$JOB" >/dev/null 2>&1 && exit 0
fi
if [ -x "$PROG" ]; then
  nohup "$PROG" "\$@" >/dev/null 2>&1 &
  exit 0
fi
osascript -e 'display alert "SeeedJiggler is not installed" message "Run scripts/install.sh in the SeeedJiggler repository."' >/dev/null 2>&1
SH
chmod 755 "$APP/Contents/MacOS/SeeedJiggler"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$REPO/app/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
touch "$APP"
echo "Created $APP"

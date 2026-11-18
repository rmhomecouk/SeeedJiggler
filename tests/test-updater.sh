#!/bin/bash
# Exercises the app's update path against a local fake of the GitHub API (no network, nothing real is touched).
# Builds two test copies of the app with different embedded versions, lets the old one "update" to the new one,
# and checks: the file was replaced, the process re-executed as the new version, and a bad checksum is refused.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill $SRV 2>/dev/null || true; rm -rf "$T"' EXIT

build() {  # build NAME VERSION
  cat > "$T/$1.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$2</string><key>CFBundleVersion</key><string>test</string></dict></plist>
PL
  swiftc -O -DTESTPORT -o "$T/$1" "$REPO/app/SeeedJiggler.swift" -framework AppKit -framework IOKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$T/$1.plist"
}
build old aaaaaaa
build new bbbbbbb
SHA40=bbbbbbb$(printf '0%.0s' $(seq 1 33))
export SJ_PORT=/dev/null SJ_API=http://127.0.0.1:18765 SJ_AUTO_INSTALL=1 SJ_RESTART=exec

python3 "$REPO/tests/fake_github.py" 18765 "$T/new" "$SHA40" & SRV=$!; sleep 1
cp "$T/old" "$T/app"
echo "--- update old (aaaaaaa) to new (bbbbbbb)"
OUT="$(perl -e 'alarm 60; exec @ARGV' "$T/app" 2>&1 || true)"; echo "$OUT"
cmp "$T/app" "$T/new" && echo "PASS: binary replaced"
echo "$OUT" | grep -q "check: available" && echo "PASS: update offered"
echo "$OUT" | grep -q "check: upToDate" && echo "PASS: re-executed as the new version (now up to date)"
[ "$(SJ_AUTO_INSTALL=0 SJ_PRINT_VERSION=1 "$T/app")" = "bbbbbbb" ] && echo "PASS: new version reported"
kill $SRV; wait $SRV 2>/dev/null || true

echo "--- corrupt checksum must be refused"
python3 "$REPO/tests/fake_github.py" 18765 "$T/new" "$SHA40" corrupt & SRV=$!; sleep 1
cp "$T/old" "$T/app2"
OUT="$(perl -e 'alarm 60; exec @ARGV' "$T/app2" 2>&1 || true)"; echo "$OUT"
cmp "$T/app2" "$T/old" && echo "PASS: binary untouched"
echo "$OUT" | grep -q "checksum" && echo "PASS: refused for checksum"

kill $SRV; wait $SRV 2>/dev/null || true
echo "--- matching checksum but a program that cannot run must be refused"
head -c 300000 /dev/urandom > "$T/garbage"
python3 "$REPO/tests/fake_github.py" 18765 "$T/garbage" "$SHA40" & SRV=$!; sleep 1
cp "$T/old" "$T/app3"
OUT="$(perl -e 'alarm 60; exec @ARGV' "$T/app3" 2>&1 || true)"; echo "$OUT"
cmp "$T/app3" "$T/old" && echo "PASS: binary untouched"
[ ! -e "$T/app3.new" ] && [ ! -e "$T/app3.old" ] && echo "PASS: no leftovers"
echo "$OUT" | grep -q "does not run" && echo "PASS: refused because it cannot run"

kill $SRV; wait $SRV 2>/dev/null || true
echo "--- release replaced between check and download must be refused with an explanation"
OTHER40=ccccccc$(printf '0%.0s' $(seq 1 33))
python3 "$REPO/tests/fake_github.py" 18765 "$T/new" "$OTHER40" & SRV=$!; sleep 1
cp "$T/old" "$T/app4"
OUT="$(perl -e 'alarm 60; exec @ARGV' "$T/app4" 2>&1 || true)"; echo "$OUT"
cmp "$T/app4" "$T/old" && echo "PASS: binary untouched"
echo "$OUT" | grep -q "newer release was published" && echo "PASS: explained as a changed release"

kill $SRV; wait $SRV 2>/dev/null || true
echo "--- restart without exec: the old copy exits and the NEW program is started (not under launchd)"
python3 "$REPO/tests/fake_github.py" 18765 "$T/new" "$SHA40" & SRV=$!; sleep 1
cp "$T/old" "$T/app5"
OUT="$(SJ_RESTART=spawn perl -e 'alarm 60; exec @ARGV' "$T/app5" 2>&1 || true)"; sleep 6; echo "$OUT"
cmp "$T/app5" "$T/new" && echo "PASS: replaced"
echo "$OUT" | grep -q "check: upToDate" && echo "PASS: new program was started"

echo "--- restart under launchd: exit with failure so KeepAlive starts the new program"
cp "$T/old" "$T/app6"
cat > "$T/ld.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>Label</key><string>sjtest.updater</string><key>ProgramArguments</key><array><string>$T/app6</string></array>
<key>EnvironmentVariables</key><dict><key>SJ_PORT</key><string>/dev/null</string><key>SJ_AUTO_INSTALL</key><string>1</string><key>SJ_RESTART</key><string>launchd</string><key>SJ_API</key><string>$SJ_API</string></dict>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>$T/ld.out</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$T/ld.plist"; sleep 20; launchctl bootout "gui/$(id -u)/sjtest.updater" 2>/dev/null || true
cat "$T/ld.out"
cmp "$T/app6" "$T/new" && echo "PASS: replaced"
[ "$(grep -c 'check: upToDate' "$T/ld.out")" -ge 1 ] && echo "PASS: launchd started the new program"

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
export SJ_PORT=/dev/null SJ_API=http://127.0.0.1:18765 SJ_AUTO_INSTALL=1 SJ_NO_GUARD=1

python3 "$REPO/tests/fake_github.py" 18765 "$T/new" "$SHA40" & SRV=$!; sleep 1
cp "$T/old" "$T/app"
echo "--- update old (aaaaaaa) to new (bbbbbbb)"
OUT="$(perl -e 'alarm 60; exec @ARGV' "$T/app" 2>&1 || true)"; echo "$OUT"
cmp "$T/app" "$T/new" && echo "PASS: binary replaced"
echo "$OUT" | grep -q "check: available" && echo "PASS: update offered"
echo "$OUT" | grep -q "check: upToDate" && echo "PASS: the new program was started (now up to date)"
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
echo "--- restart under launchd: exit with failure so KeepAlive starts the new program"
python3 "$REPO/tests/fake_github.py" 18765 "$T/new" "$SHA40" & SRV=$!; sleep 1
cp "$T/old" "$T/app6"
cat > "$T/ld.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>Label</key><string>sjtest.updater</string><key>ProgramArguments</key><array><string>$T/app6</string></array>
<key>EnvironmentVariables</key><dict><key>SJ_PORT</key><string>/dev/null</string><key>SJ_AUTO_INSTALL</key><string>1</string><key>SJ_RESTART</key><string>launchd</string><key>SJ_NO_GUARD</key><string>1</string><key>SJ_API</key><string>$SJ_API</string></dict>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>$T/ld.out</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$T/ld.plist"; sleep 20; launchctl bootout "gui/$(id -u)/sjtest.updater" 2>/dev/null || true
cat "$T/ld.out"
cmp "$T/app6" "$T/new" && echo "PASS: replaced"
[ "$(grep -c 'check: upToDate' "$T/ld.out")" -ge 1 ] && echo "PASS: launchd started the new program"

kill $SRV; wait $SRV 2>/dev/null || true
echo "--- one-instance check with the real guard: the copy that is being replaced must not block its replacement"
if pgrep -x SeeedJiggler >/dev/null; then
  echo "SKIP: a SeeedJiggler is running (stop it first: the test programs are named like the real one)"
else
  mkdir -p "$T/g"; cp "$T/old" "$T/g/SeeedJiggler"
  python3 "$REPO/tests/fake_github.py" 18765 "$T/new" "$SHA40" & SRV=$!; sleep 1
  OUT="$(env -u SJ_NO_GUARD perl -e 'alarm 60; exec @ARGV' "$T/g/SeeedJiggler" 2>&1 || true)"; echo "$OUT"
  cmp "$T/g/SeeedJiggler" "$T/new" && echo "PASS: replaced"
  echo "$OUT" | grep -q "check: upToDate" && echo "PASS: new copy started (no already-running refusal)"
  kill $SRV; wait $SRV 2>/dev/null || true
fi

echo "--- keep-awake and pause are restored after a restart"
cp "$T/old" "$T/ka_probe"; export SJ_PORT=/dev/null; unset SJ_AUTO_INSTALL
defaults delete ka_probe 2>/dev/null || true
SJ_SET_AWAKE=forever SJ_QUIT_AFTER=2 "$T/ka_probe" >/dev/null 2>&1 || true
OUT="$(SJ_PRINT_MODE=1 "$T/ka_probe" 2>&1)"; echo "$OUT"
echo "$OUT" | grep -q "awake forever" && echo "PASS: keep-awake (until I turn it off) restored"
SJ_SET_AWAKE=hours QUIT=1 SJ_QUIT_AFTER=2 "$T/ka_probe" >/dev/null 2>&1 || true
OUT="$(SJ_PRINT_MODE=1 "$T/ka_probe" 2>&1)"; echo "$OUT"
echo "$OUT" | grep -q "awake hours(1) until true" && echo "PASS: timed keep-awake restored with its end time"
defaults delete ka_probe 2>/dev/null || true

# SeeedJiggler

[![release](https://github.com/rmhomecouk/SeeedJiggler/actions/workflows/release.yml/badge.svg)](https://github.com/rmhomecouk/SeeedJiggler/actions/workflows/release.yml)

A tiny hardware mouse jiggler built from a **Seeeduino XIAO (SAMD21)**, plus a macOS **menu bar app** that only jiggles when you are actually idle, shows whether the board is connected, and can keep the Mac awake. The app is one Swift file: no logging, and nothing written to disk while it runs apart from its saved settings.

The XIAO shows up to the computer as a genuine USB mouse, so the activity is real HID input: it keeps chat/presence status "Available" and stops screen lock/sleep timers. Apple silicon Macs, macOS 13 or later.

> **Use responsibly.** Check your employer's acceptable-use policy before using any jiggler on a work machine. This project is provided for personal use and learning.

## How it works (30 seconds)

```
 macOS host                                   XIAO board
 ┌──────────────────────┐   USB serial (CDC)  ┌────────────────────────────┐
 │ SeeedJiggler app     │ ── "H" heartbeat ─▶ │ LED: app heard in 30s?     │
 │  reads HIDIdleTime   │ ── "M 8 0 / M -8 0"▶│ Mouse.move()  ──USB HID──▶ host
 │  idle ≥ 120s? jiggle │                     │ LEDs: link / activity      │
 └──────────────────────┘                     └────────────────────────────┘
```

* **Normal mode** – the app watches macOS idle time. After 120 s with no real input it nudges the cursor 8 px and back every 45 s. Real input from you resets everything. 
* **The app is in charge** – it sends a heartbeat every 5 s, and the board does nothing on its own: **it never moves the mouse unless the app tells it to**. If the board hears no heartbeat for 30 s (app quit, crashed, not started after a reboot) it only blinks its yellow LED, so you can see the app is gone. Quit the app and jiggling stops.
* **LEDs** – solid yellow: connected and app healthy · slow blink: connected but app silent (board idle) · off: no USB host · TX LED flashes on mouse moves.

Full details: [docs/how-it-works.md](docs/how-it-works.md).

## Quick start

Requirements: a Seeeduino XIAO (SAMD21), macOS, [`arduino-cli`](https://arduino.github.io/arduino-cli/), Xcode command line tools (`swiftc`), Python 3 (only for the optional `hid.py` CLI).

```bash
# 1. toolchain
brew install arduino-cli
arduino-cli config add board_manager.additional_urls https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
arduino-cli core update-index
arduino-cli core install Seeeduino:samd
arduino-cli lib install Mouse

# 2. flash (board plugged in, see docs/hardware-and-flashing.md if it won't enter the bootloader)
arduino-cli compile --fqbn Seeeduino:samd:seeed_XIAO_m0 firmware/SeeedJiggler
arduino-cli upload  -p /dev/cu.usbmodem* --fqbn Seeeduino:samd:seeed_XIAO_m0 firmware/SeeedJiggler

# 3. build the app and run it once (menu bar icon appears)
scripts/build.sh && build/SeeedJiggler

# 4. ...or install it to start at every login (builds it; replaces the login copy)
scripts/install.sh
```

Click the menu bar icon to pause or resume jiggling; right-click for the menu. The idle threshold (default 2 minutes), keep-awake, updates and start at login are in the app's menu; jiggles repeat every 45 s. A launcher app is created in `~/Applications` so it can be started from Spotlight. Details: [docs/app.md](docs/app.md).

## Repository layout

| Path | What it is |
|------|------------|
| `firmware/SeeedJiggler/SeeedJiggler.ino` | XIAO firmware: USB HID mouse only, serial command parser, app-presence LED |
| `app/SeeedJiggler.swift` | The macOS app: idle-aware jiggle engine, board detection, menu bar UI, keep-awake, start-at-login |
| `tools/hid.py` | Optional Python CLI: check the board status, move the mouse |
| `.github/workflows/release.yml` | Builds the app on every push to `main` and publishes it as the rolling `latest` release that the app's update checker reads |
| `scripts/make-app.sh`, `app/make_icon.swift` | Create `~/Applications/SeeedJiggler.app`, a launcher with an icon for Spotlight/Launchpad (`install.sh` runs it) |
| `scripts/build.sh`, `scripts/install.sh`, `scripts/uninstall.sh` | Compile the app; install/remove the login LaunchAgent |
| `docs/` | Hardware & flashing, the app, serial protocol, design notes, memory/leak testing, troubleshooting |

## Checking the board

```bash
python3 -B -I tools/hid.py status          # SEEEDJIGGLER 2 app=1 age=1234 hb=57 mv=12
python3 -B -I tools/hid.py move 100 0      # relative mouse move
```

`status` shows what the board actually received: `app=0` means it has heard no heartbeat for 30 s, `hb` counts heartbeats and `mv` counts mouse-move commands.

**Security note.** The firmware is mouse-only: it has no keyboard interface and no typing, key or click commands (`T`, `K`, `C` answer `ERR`). Any local process that can open the board's serial port can still move the mouse.

Protocol reference: [docs/protocol.md](docs/protocol.md).

## Status & limitations

* Tested with one XIAO (SAMD21). The mouse is **relative only** (no absolute positioning).
* The app must be running for anything to jiggle: after a reboot, until you log in, or after Quit, nothing does. Turn on *Start at login* (or run `scripts/install.sh`). The board no longer covers for a stopped or hung app.
* What has and has not been verified on hardware (heartbeats, jiggle delivery, pause, unplug/replug, real-input detection, leak tests) is listed in [docs/how-it-works.md](docs/how-it-works.md#verification-status) and [docs/testing.md](docs/testing.md).
* The board's USB core never issues a remote-wake request, so it should not wake a sleeping computer; this was not tested empirically.

## License

MIT — see [LICENSE](LICENSE).

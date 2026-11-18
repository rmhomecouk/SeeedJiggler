# SeeedJiggler

A tiny hardware mouse jiggler built from a **Seeeduino XIAO (SAMD21)**, plus a tiny native macOS service (~3.5 MB, no logging, no disk writes) that only jiggles when you are actually idle.

The XIAO shows up to the computer as a genuine USB keyboard + mouse, so the activity is real HID input — it keeps chat/presence status "Available" and stops screen lock/sleep timers, with nothing to install on the target machine except the optional host service.

> **Use responsibly.** Check your employer's acceptable-use policy before using any jiggler on a work machine. This project is provided for personal use and learning.

## How it works (30 seconds)

```
 macOS host                                   XIAO board
 ┌──────────────────────┐   USB serial (CDC)  ┌────────────────────────────┐
 │ seeedjiggler (C)     │ ── "H" heartbeat ─▶ │ watchdog: heard in 30s? ok │
 │  reads HIDIdleTime   │ ── "M 8 0 / M -8 0"▶│ Mouse.move()  ──USB HID──▶ host
 │  idle ≥ 120s? jiggle │                     │ LEDs: link / activity      │
 └──────────────────────┘                     └────────────────────────────┘
```

* **Normal mode** – the host script watches macOS idle time. After 120 s with no real input it nudges the cursor 8 px and back every 45 s. Real input from you resets everything. The service logs nothing and writes nothing to disk.
* **Fallback mode** – the script sends a heartbeat every 5 s. If the board hears nothing for 30 s (script stopped, crashed, not started after a reboot) it jiggles **by itself** every 45 s, and stops the moment the heartbeat returns. In fallback the board cannot tell whether you are using the computer, so you may see an occasional 8 px twitch while you work.
* **LEDs** – solid yellow: connected and service healthy · slow blink: connected but service silent (fallback) · off: no USB host · TX LED flashes on mouse moves · RX LED flashes on keystrokes.

Full details: [docs/how-it-works.md](docs/how-it-works.md).

## Quick start

Requirements: a Seeeduino XIAO (SAMD21), macOS, [`arduino-cli`](https://arduino.github.io/arduino-cli/), Xcode command line tools (`clang`), Python 3 (only for the optional `hid.py` CLI).

```bash
# 1. toolchain
brew install arduino-cli
arduino-cli config add board_manager.additional_urls https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
arduino-cli core update-index
arduino-cli core install Seeeduino:samd
arduino-cli lib install Keyboard Mouse

# 2. flash (board plugged in, see docs/hardware-and-flashing.md if it won't enter the bootloader)
arduino-cli compile --fqbn Seeeduino:samd:seeed_XIAO_m0 firmware/SeeedJiggler
arduino-cli upload  -p /dev/cu.usbmodem* --fqbn Seeeduino:samd:seeed_XIAO_m0 firmware/SeeedJiggler

# 3. build and try the idle-aware service in the foreground (-v prints jiggles)
scripts/build.sh && build/seeedjiggler -v

# 4. ...or install it to start at login (builds it for you)
scripts/install-service.sh
```

Defaults can be changed with environment variables: `IDLE_SECS` (default 120) and `JIGGLE_EVERY` (default 45).

## Repository layout

| Path | What it is |
|------|------------|
| `firmware/SeeedJiggler/SeeedJiggler.ino` | XIAO firmware: USB HID keyboard+mouse, serial command parser, watchdog fallback, LEDs |
| `host/seeedjiggler.c` | macOS idle-aware service in C (heartbeat + jiggle logic, survives unplug/replug, no logging) |
| `host/hid.py` | Optional Python CLI to send keystrokes / mouse actions to the board |
| `scripts/build.sh`, `scripts/install-service.sh`, `scripts/uninstall-service.sh` | Compile the service; install/remove the macOS LaunchAgent so it starts at login |
| `docs/` | Hardware & flashing, running as a service, serial protocol, design notes, memory/leak testing, troubleshooting |

## Using the board as a general keyboard/mouse

```bash
python3 -B -I host/hid.py type "hello"
python3 -B -I host/hid.py key cmd+space
python3 -B -I host/hid.py move 100 0
python3 -B -I host/hid.py click r
```

Protocol reference: [docs/protocol.md](docs/protocol.md).

## Status & limitations

* Tested on macOS with one XIAO (SAMD21). The mouse is **relative only** (no absolute positioning).
* Install the LaunchAgent for start-at-login ([docs/service.md](docs/service.md)). Until the service is running (e.g. just after a reboot), the board's fallback mode keeps jiggling.
* Fallback-mode behaviour was only partially verified (see [docs/how-it-works.md](docs/how-it-works.md#verification-status)).
* The board's USB core never issues a remote-wake request, so it should not wake a sleeping computer; this was not tested empirically.

## License

MIT — see [LICENSE](LICENSE).

# How it works

## Why a hardware board?

Software jigglers synthesise events inside the OS. A board plugged into USB generates **real HID reports**, which the OS cannot tell apart from a physical mouse. It works on any machine, and survives the host script dying.

## Idle detection (host)

The board cannot see the computer's input, so the app (`app/SeeedJiggler.swift`) reads macOS's `HIDIdleTime` (nanoseconds since last input) every 5 s, directly from the `IOHIDSystem` service via IOKit — no subprocess, no files.

**Problem:** the jiggle itself is HID input, so it resets `HIDIdleTime` and the app would think you came back. **Solution:** the app keeps `lastReal`, the time of the last *genuine* input, and the time of its own last jiggle. If `HIDIdleTime` is smaller than "time since my last jiggle" (minus 2 s slack), input arrived *after* the jiggle, so it must be you — `last_real` is updated and jiggling stops. Otherwise the idle clock keeps counting from `last_real`.

Defaults: idle threshold 120 s (menu: 1/2/5/10/15 min), jiggle every 45 s. A jiggle is `M 8 0` then `M -8 0`.

Every 5 s the app also sends `H` (heartbeat).

**Finding the board.** The app never writes to "the first `/dev/cu.usbmodem*`". It scans IOKit for the serial device whose USB parent has Seeed's vendor ID `0x2886` and the firmware's product ID `0x802F`, opens it in raw mode at 115200 baud, and sends `?`. Only if the reply starts with `SEEEDJIGGLER` is the port used. Other USB serial devices (printer boards, other Arduinos) are never written to. The port is then **held open** between cycles; if a write fails (unplug) the port is closed and the whole find/verify step runs again on the next cycle. The app never logs and never writes to disk while running (it stores only your menu choices: idle threshold, paused, automatic update check; plus the start-at-login plist if you enable that. The update check uses an ephemeral network session, so no HTTP cache is written).

**Footprint:** about 12 MB physical footprint (AppKit), one wake-up every 5 s, no child processes. The earlier C service was ~3.5 MB; the engine was moved into the app so there is one thing to install and control.

## App presence (firmware)

The firmware records the time of the last received command (the `?` status query is deliberately excluded, so checking status can never mask a dead app). If connected over USB but more than **30 s** pass without a command, the yellow LED blinks and `?` reports `app=0`. **That is all it does: the board never moves the mouse by itself.** The app has full control, so quitting or crashing the app stops all jiggling. (Earlier firmware jiggled on its own when the heartbeat stopped; that was removed on request.)

## LEDs (active-low on the XIAO)

| LED | Meaning |
|-----|---------|
| Yellow (user), solid | USB configured, app heartbeat OK |
| Yellow, blinking 1 Hz | USB configured, **no heartbeat for 30 s** (board idle) |
| Yellow, off | No USB host / not enumerated |
| TX | Flashes (80 ms) on mouse move |
| RX | Off |

## Verification status

Checked on real hardware (Seeeduino XIAO M0, macOS 27) with the current firmware and the Swift app, on 2026-11-18, using the firmware's `?` counters as ground truth for what the board actually received:

| Check | Evidence |
|-------|----------|
| Current firmware flashed and answering | `SEEEDJIGGLER 2 app=… age=… hb=… mv=…` |
| Board never moves the mouse by itself | app stopped, board silent for 137 s: `app=0`, `mv=0`, and macOS HID idle time rose without a single reset for 120 s (the removed self-jiggle fired every 45 s after 30 s) |
| Mouse-only firmware | flashed 2026-11-18: macOS lists a single HID interface (mouse), `T hello` and `K enter` answer `ERR`, `M 0 0` answers `OK` |
| Silent start | right after boot, before any heartbeat: `app=0 hb=0` |
| App finds and verifies the board | after starting the app, `app=1`; also found it on hot-plug (the board showed `hb=15` from a 75 s run that began when it was plugged in) |
| Heartbeats reach the board | `hb` 7 → 17 in about 50 s (one per 5 s) |
| Jiggles reach the board | `mv` 2 → 4 about 45 s apart (each jiggle is two `M` commands) |
| Real input holds jiggling off | with the Mac in active use right after launch, `mv` stayed 0 for 12 s (short observation) |
| Pause on the real board | paused at t = 20 s with the jiggle threshold at 1 s: `hb` kept rising (348 → 367 over 90 s), `mv` stayed at 4 while two jiggles would have fallen due |
| Board re-enumeration with the app running | reflashed the firmware with the app running: the port vanished and returned, the **same app process** reconnected within 3 s (`hb` restarted at 2, `app=1`). This is a reflash, not a pulled cable |
| Only one copy runs | a second launch showed "already running" and exited (screenshot); the first kept the board |
| Live menu bar item | seen in a screenshot of the real menu bar on a dark wallpaper: legible white glyph |
| Memory | `leaks` 0, about 12 MB physical footprint ([testing.md](testing.md)) |

Observed earlier with the previous C engine and old firmware, not repeated with the current code: recovery after the board re-enumerates (reflashing twice under a running process, same pid recovered), real input stopping a jiggle that was already running.

Not verified with the current code:

* **Physically pulling the USB cable** with the app running (re-enumeration by reflashing was verified), and clicking Pause in the menu itself (the same code path was driven by a test hook).
* **The no-heartbeat LED blink**, and the other LED behaviours of the new firmware, by eye.
* **A second physical XIAO**: the app uses the first board that answers; this was not tested with two real boards.
* **A sleeping Mac**: the firmware never requests USB remote wake-up, so it should not wake a sleeping host; not tested.
* **Keep-awake preventing the lock**: see [app.md](app.md).
* **Start-up stall:** a LaunchAgent whose binary is under `~/Documents` hung inside `open()` of its own executable before `main` (stack: `dyld … open`, ~144 KB footprint). The same binary run from `/private/tmp` under launchd started in under 4 s. The suspect is macOS file-access protection for background processes; no consent dialog or `tccd` entry was seen, so that is an inference. The installer and the *Start at login* item therefore run a copy from `~/.local/bin` when the repo is under Documents, Desktop or Downloads.

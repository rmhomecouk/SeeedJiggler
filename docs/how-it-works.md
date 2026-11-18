# How it works

## Why a hardware board?

Software jigglers synthesise events inside the OS. A board plugged into USB generates **real HID reports**, which the OS cannot tell apart from a physical mouse. It works on any machine, and survives the host script dying.

## Idle detection (host)

The board cannot see the computer's input, so the app (`app/SeeedJiggler.swift`) reads macOS's `HIDIdleTime` (nanoseconds since last input) every 5 s, directly from the `IOHIDSystem` service via IOKit — no subprocess, no files.

**Problem:** the jiggle itself is HID input, so it resets `HIDIdleTime` and the app would think the user came back. **Solution:** the app keeps `lastReal`, the time of the last *genuine* input, and the time of its own last jiggle. If `HIDIdleTime` is smaller than "time since my last jiggle" (minus 2 s slack), input arrived *after* the jiggle, so it must be a person — `lastReal` is updated and jiggling stops. Otherwise the idle clock keeps counting from `lastReal`.

Defaults: idle threshold 120 s (menu: 1/2/5/10/15 min), jiggle every 45 s. A jiggle is `M 8 0` then `M -8 0`.

Every 5 s the app also sends `H` (heartbeat).

**Finding the board.** The app never writes to "the first `/dev/cu.usbmodem*`". It scans IOKit for the serial device whose USB parent has Seeed's vendor ID `0x2886` and the firmware's product ID `0x802F`, opens it in raw mode at 115200 baud, and sends `?`. Only if the reply starts with `SEEEDJIGGLER` is the port used. Other USB serial devices (printer boards, other Arduinos) are never written to. The port is then **held open** between cycles; if a write fails (unplug) the port is closed and the whole find/verify step runs again on the next cycle. The app never logs and never writes to disk while running (it stores only menu choices: idle threshold, paused, keep-awake, automatic update check; plus the start-at-login plist if enabled. The update check uses an ephemeral network session, so no HTTP cache is written).

**Footprint:** about 13 MB physical footprint (AppKit) and one wake-up every 5 s. The only child processes are short-lived ones during an update.

## App presence (firmware)

The firmware records the time of the last received command (the `?` status query is deliberately excluded, so checking status can never mask a dead app). If connected over USB but more than **30 s** pass without a command, the yellow LED blinks and `?` reports `app=0`. **That is all it does: the board never moves the mouse by itself.** The app has full control, so quitting or crashing the app stops all jiggling. (A board still on older firmware jiggles by itself when the heartbeat stops; reflash it.)

## LEDs (active-low on the XIAO)

| LED | Meaning |
|-----|---------|
| Yellow (user), solid | USB configured, app heartbeat OK |
| Yellow, blinking 1 Hz | USB configured, **no heartbeat for 30 s** (board idle) |
| Yellow, off | No USB host / not enumerated |
| TX | Flashes (80 ms) on mouse move |
| RX | Off |

## Verification status

Checked on real hardware (Seeeduino XIAO M0, macOS 27) with the current firmware and app on 2026-11-18, using the firmware's `?` counters as ground truth for what the board actually received:

| Check | Evidence |
|-------|----------|
| Board never moves the mouse by itself | app stopped, board silent for 137 s: `app=0`, `mv=0`, and macOS HID idle time rose without a single reset for 120 s (the removed self-jiggle fired every 45 s after 30 s) |
| Mouse-only firmware | macOS lists a single HID interface (mouse); `T hello` and `K enter` answer `ERR`; `M 0 0` answers `OK` |
| Silent start | right after boot, before any heartbeat: `app=0 hb=0` |
| App finds and verifies the board | `app=1` after starting the app; also found on hot-plug |
| Heartbeats reach the board | `hb` 7 → 17 in about 50 s (one per 5 s) |
| Jiggles reach the board | `mv` 2 → 4 about 45 s apart (each jiggle is two `M` commands) |
| Real input holds jiggling off | with the Mac in active use right after launch, `mv` stayed 0 for 12 s (short observation) |
| Pause | paused at t = 20 s with the jiggle threshold at 1 s: `hb` kept rising (348 → 367 over 90 s), `mv` stayed at 4 while two jiggles would have fallen due |
| Re-enumeration with the app running | firmware reflashed with the app running: the port vanished and returned, the same app process reconnected within 3 s (`hb` restarted at 2, `app=1`) |
| Physical unplug and replug | recovered (reported by the maintainer, not measured) |
| Launcher app | started the app from `~/Applications` (reported by the maintainer; also tested with `open`, see [testing.md](testing.md)) |
| One copy only | a second launch showed "already running" and exited; the first kept the board |
| Update through the real menu | confirmation shown, Install and Restart: launchd restarted the app, new version running, board active, icon normal ([testing.md](testing.md)) |
| Live menu bar item | screenshots of the real menu bar on a dark wallpaper: legible white glyph |
| Memory | 0 leaks, about 13 MB physical footprint ([testing.md](testing.md)) |

Not verified:

* **The no-heartbeat LED blink**, and the other LED behaviours, by eye.
* **A second physical XIAO**: the app uses the first board that answers; not tested with two real boards.
* **A sleeping Mac**: the firmware never requests USB remote wake-up, so it should not wake a sleeping host; not tested.
* **Keep-awake preventing the lock**: see [app.md](app.md).
* **Start-up stall (cause inferred):** a LaunchAgent whose binary is under `~/Documents` hung inside `open()` of its own executable before `main` (stack: `dyld … open`, ~144 KB footprint). The same binary run from `/private/tmp` under launchd started in under 4 s. The suspect is macOS file-access protection for background processes; no consent dialog or `tccd` entry was seen. The installer and the *Start at login* item therefore run a copy from `~/.local/bin` when the repository is under Documents, Desktop or Downloads.

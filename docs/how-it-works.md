# How it works

## Why a hardware board?

Software jigglers synthesise events inside the OS. A board plugged into USB generates **real HID reports**, which the OS cannot tell apart from a physical mouse. It works on any machine, and survives the host script dying.

## Idle detection (host)

The board cannot see the computer's input, so `host/seeedjiggler.c` reads macOS's `HIDIdleTime` (nanoseconds since last input) every 5 s, directly from the `IOHIDSystem` service via IOKit — no subprocess, no files.

**Problem:** the jiggle itself is HID input, so it resets `HIDIdleTime` and the service would think you came back. **Solution:** the service keeps `last_real`, the time of the last *genuine* input, and the time of its own last jiggle. If `HIDIdleTime` is smaller than "time since my last jiggle" (minus 2 s slack), input arrived *after* the jiggle, so it must be you — `last_real` is updated and jiggling stops. Otherwise the idle clock keeps counting from `last_real`.

Defaults: idle threshold 120 s (`IDLE_SECS`), jiggle every 45 s (`JIGGLE_EVERY`). A jiggle is `M 8 0` then `M -8 0`.

Every 5 s the service also sends `H` (heartbeat).

**Finding the board.** The service never writes to "the first `/dev/cu.usbmodem*`". It scans IOKit for the serial device whose USB parent has Seeed's vendor ID `0x2886` and the firmware's product ID `0x802F`, opens it in raw mode at 115200 baud, and sends `?`. Only if the reply starts with `SEEEDJIGGLER` is the port used. Other USB serial devices (printer boards, other Arduinos) are never written to. The port is then **held open** between cycles; if a write fails (unplug) the port is closed and the whole find/verify step runs again on the next cycle. The service never logs and never writes to disk (run it in the foreground with `-v` to see jiggle events on stderr).

**Footprint:** ~3.5 MB resident (measured), one wake-up every 5 s, no child processes.

## Watchdog fallback (firmware)

The firmware records the time of the last received command (the `?` status query is deliberately excluded, so checking status can never mask a dead service). If connected over USB but more than **30 s** pass without a command, it enters fallback: it blinks the yellow LED and jiggles by itself (8 px out and back) every **45 s**. As soon as the host sends anything again, fallback ends and the host service is in charge.

Trade-off: in fallback the board has no idea whether you are active, so it may twitch the cursor while you work. This is intentional — better a harmless twitch than losing "Available" status because a script crashed.

A sleeping host: the firmware never calls the SAMD21's remote-wakeup, so jiggles sent while the bus is suspended should not wake the machine (not empirically tested).

## LEDs (active-low on the XIAO)

| LED | Meaning |
|-----|---------|
| Yellow (user), solid | USB configured, service heartbeat OK |
| Yellow, blinking 1 Hz | USB configured, **no heartbeat** → fallback jiggling |
| Yellow, off | No USB host / not enumerated |
| TX | Flashes (80 ms) on mouse move/click |
| RX | Flashes (80 ms) on keyboard output |

## Verification status

Everything below was observed on real hardware (Seeeduino XIAO M0, macOS), using the firmware's `?` status counters as ground truth for what the board actually received:

| Check | Evidence |
|-------|----------|
| Heartbeats reach the board | `hb` counter rose by exactly 1 per 5 s cycle (`hb=1…9`), `fb=0` throughout |
| Jiggles reach the board | each jiggle raised the board's `mv` counter by exactly 2 (`mv=2→4→6→…`) |
| Real input stops jiggling | after an injected input event the service logged `real input detected`, jiggling stopped, and its idle clock restarted from the real input (effective idle 1.6 s, then resumed only after the threshold) |
| Fallback engages when the service is silent | 36 s with no service: board reported `fb=1` |
| Fallback clears when the service returns | first heartbeat after restart: `fb=0`, `age=1` |
| Port selection by USB IDs + `SEEEDJIGGLER` reply | board found and verified on every start |
| Memory | flat 2.5–3.7 MB RSS, constant fd count, `leaks` reports 0 (see [testing.md](testing.md)) |

Not verified:

* **Replug with the new code**: the held-open-port / re-find logic after a physical unplug and replug has not been exercised since the rewrite (the earlier Python version's replug was).
* **One unexplained start-up stall**: once, right after heavy stress testing, a freshly (re)installed service delivered no heartbeats for its first ~25 s while the process showed a ~144 KB footprint, i.e. it appeared not to have reached `main` yet. It could not be reproduced in five further attempts (including back-to-back installs and clean-environment launches). Suspected cause is a delayed launch of a freshly built binary while the machine was heavily loaded, not the service logic; unconfirmed. Even if it recurs, the board's watchdog covers the gap (it only starts jiggling after 30 s of silence).
* **Fallback cadence**: the 45 s self-jiggle interval was not measured precisely (the `?` counters do not count fallback moves).
* **A sleeping Mac**: the firmware never requests USB remote wake-up, so it should not wake a sleeping host; not tested.
* **Typing/key commands** (`T`, `K`, `C`, …): only lightly tested; US keyboard layout assumed.

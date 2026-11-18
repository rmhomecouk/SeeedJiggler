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

Observed on real hardware (Seeeduino XIAO M0, macOS), using the firmware's `?` status counters as ground truth for what the board actually received:

| Check | Evidence |
|-------|----------|
| Heartbeats reach the board | `hb` counter rose by exactly 1 per 5 s cycle, `fb=0` throughout |
| Jiggles reach the board | each jiggle raised the board's `mv` counter by exactly 2 (`mv=2→4→6→…`) |
| Real input stops jiggling | after an injected input event the service logged `real input detected`, stopped jiggling, and restarted its idle clock from the real input |
| Fallback engages when the service is silent | 36 s with no service: board reported `fb=1` |
| Fallback clears when the service returns | first heartbeat after restart: `fb=0` |
| **Recovery after the board re-enumerates, with the port held open** | Reflashed the board twice while the service was running (the board drops off USB and returns). The *same* service process (same pid) reconnected on its own; `hb` restarted from ~1 and `fb=0` at +5 s, +15 s and +30 s each time |
| Port selection by USB IDs + `SEEEDJIGGLER` reply | board found and verified on every start in these tests (but see the stall below) |
| Jiggler-only build | flashed: board exposes no keyboard interface (usage pairs only mouse/pointer), `T`/`K` commands answer `ERR`, `M` and heartbeats work |
| Full build | flashed back: keyboard + mouse + pointer interfaces present; unknown commands answer `ERR` |
| Memory | flat ~2.5–3.8 MB RSS, constant fd count, `leaks` 0 (see [testing.md](testing.md)) |

Not verified:

* **A physical USB unplug/replug with the current code.** Reflashing re-enumerates the board (the strongest substitute available without touching the cable), but it is not the same event as pulling the cable.
* **The LEDs.** Nobody has looked at them since the firmware changes. In particular, a bug where the TX LED would not light during fallback (a stale `millis()` value) was found by code review and fixed, but the fix was not observed on the board.
* **Fallback cadence**: the 45 s self-jiggle interval was not measured (the `?` counters do not count fallback moves).
* **A second XIAO plugged in at the same time**: the service now tries every device with the board's USB IDs and uses the first that answers as SeeedJiggler, but this was not tested with two boards. (Until a device answers `?` correctly it is sent that one line.)
* **A sleeping Mac**: the firmware never requests USB remote wake-up, so it should not wake a sleeping host; not tested.
* **Typing/key commands** (`T`, `K`, `C`, …): only lightly tested; US keyboard layout assumed.
* **One unexplained start-up stall.** Once, right after heavy stress testing, a freshly reinstalled service delivered no heartbeats for at least ~25 s (the board's `age` kept growing) while the process showed a ~144 KB footprint and had no serial port open. It was stopped at that point, so how long it would have lasted is unknown, and the stack sample taken was filtered so aggressively that it shows nothing about where the process was. It did **not** recur in several further attempts, including the same precondition (stop service → heavy stress → install immediately) and back-to-back installs. Cause unknown; a delayed launch of a freshly built binary under load is a guess. If it happens, the board's watchdog covers the gap (it only starts jiggling after 30 s of silence).

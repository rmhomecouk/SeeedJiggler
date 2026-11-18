# How it works

## Why a hardware board?

Software jigglers synthesise events inside the OS. A board plugged into USB generates **real HID reports**, which the OS cannot tell apart from a physical mouse. It works on any machine, and survives the host script dying.

## Idle detection (host)

The board cannot see the computer's input, so `host/idlejiggle.py` reads macOS's `HIDIdleTime` (nanoseconds since last input) from `ioreg -c IOHIDSystem` every 5 s.

**Problem:** the jiggle itself is HID input, so it resets `HIDIdleTime` and the script would think you came back. **Solution:** the script keeps `last_real`, the time of the last *genuine* input, and the time of its own last jiggle. If `HIDIdleTime` is smaller than "time since my last jiggle" (minus 2 s slack), input arrived *after* the jiggle, so it must be you — `last_real` is updated and jiggling stops. Otherwise the idle clock keeps counting from `last_real`.

Defaults: idle threshold 120 s (`IDLE_SECS`), jiggle every 45 s (`JIGGLE_EVERY`). A jiggle is `M 8 0` then `M -8 0`.

Every 5 s the script also sends `H` (heartbeat). If the board is unplugged it logs "board unavailable, will keep retrying" once and keeps looping; the serial port is re-resolved on each send, so it logs "board reconnected" when the board returns.

## Watchdog fallback (firmware)

The firmware records the time of the last received line. If connected over USB but more than **30 s** pass without any line, it enters fallback: it blinks the yellow LED and jiggles by itself (8 px out and back) every **45 s**. As soon as the host sends anything again, fallback ends and the host service is in charge.

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

What was actually tested while building this:

* Flashing and HID: cursor moved and returned exactly on command ✔
* Idle service: with a short threshold it jiggled on schedule and stopped on real input ✔
* Presence status stayed "Available" through 15 min of idle with the service running (45/45 samples) ✔
* Unplug/replug: board re-enumerates on the same port and responds ✔; the daemon's "unavailable/reconnected" log path was **not** exercised end-to-end (error path unit-checked only)
* Watchdog fallback: the board produced jiggles with the service off, but the observation was made while the computer was also in use, so cadence was not cleanly confirmed ⚠
* Stopping of fallback when the service returns: **not yet confirmed**

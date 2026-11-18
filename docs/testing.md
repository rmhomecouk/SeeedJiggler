# Memory and leak testing

The app is meant to run for months, so it is checked for leaks and unbounded growth.

## What the engine holds

| Resource | Lifetime |
|----------|----------|
| `IOHIDSystem` service (idle time) | opened once, held for the process lifetime |
| `HIDIdleTime` property object | one per 5 s cycle, ARC-managed |
| IOKit serial-device iterator and services (board lookup) | per lookup (every cycle while no port is open, and on hot-plug), released on every path |
| Serial port file descriptor | opened when the board is found, held; closed on any write error or failed verification |
| Hot-plug notification port and its two iterators | created once at launch |
| Power assertions (keep-awake) | created on demand, released on Off, timer end or quit |

## Tools

```bash
leaks $(pgrep -x SeeedJiggler)                    # expect: "0 leaks for 0 total leaked bytes"
ps -o pid,rss,command -p $(pgrep -x SeeedJiggler) # rss in KB (includes shared AppKit pages)
lsof -p $(pgrep -x SeeedJiggler) | wc -l          # open file descriptors should stay constant
```

## Emulated-board test

`app/SeeedJiggler.swift` has test-only hooks (`SJ_PORT`, `SJ_PAUSE_AFTER`, `SJ_TOGGLE_LOGIN`), compiled in with `-DTESTPORT`, that makes the app use the pseudo-terminal named in `SJ_PORT` instead of looking for USB hardware. `tests/fakeboard.py <seconds>` opens a pty pair, prints the slave name, answers `?` with a `SEEEDJIGGLER` status line, answers `M` with `OK`, and records every command with a timestamp:

```bash
swiftc -O -DTESTPORT -o /tmp/sjtest app/SeeedJiggler.swift -framework AppKit -framework IOKit
SJ_PORT=/dev/ttysNNN /tmp/sjtest      # NNN printed by the emulator
```

Result (60 s, Mac already idle > 2 min): the board was verified with `?`, heartbeats arrived every 5.0 s (t = 7.3, 12.3, 17.3 …), jiggles (`M 8 0`, `M -8 0`, 0.1–0.2 s apart) at t = 1.3 s and t = 47.3 s, i.e. 46 s apart (45 s cadence plus the 5 s tick). A few extra heartbeats at start-up come from the hot-plug notifications triggering an immediate cycle.

Other test hooks: `SJ_PAUSE_AFTER=<s>` toggles "Jiggle when idle" after that many seconds, `SJ_QUIT_AFTER=<s>` quits, `SJ_TOGGLE_LOGIN=1` runs the *Start at login* toggle once and exits (use with `CFFIXED_USER_HOME=<temp home>` so nothing real is touched).

## Results (2026-11-18, Apple silicon, macOS)

Against the emulated board:

* **Pause** (`SJ_PAUSE_AFTER=20`, 52 s run): heartbeats continued every 5 s through and after the pause (t = 22.3 … 47.4); the jiggle that would have come at ~47 s did not (2 `M` lines in total, both at start).
* **Start at login toggle** (fake home, executable under its `Documents`): the binary was copied to `~/.local/bin/SeeedJiggler` (byte-identical), the plist points at the copy, and toggling again removed the plist. (A first run failed to copy because `/tmp` and `/private/tmp` compared unequal; fixed with `realpath`.)
* **One instance:** a second launch of `build/SeeedJiggler` beside the running login item showed "SeeedJiggler is already running" (screenshot) and did not start a second app. (Earlier, several instances were allowed and each locked its board; that was tested and then reverted at your request.)
* **launchd `KeepAlive = {SuccessfulExit = false}`** (test job from `/private/tmp`): after the app quit normally (`NSApp.terminate`) it was not restarted (1 run); after `kill -9` it was restarted with a new pid within 9 s.


Installed final build (version `5eb09eb-dirty`), 45 s after launch so the first update check had run, board attached: `leaks` reports 0 leaks, physical footprint 13.3 MB (peak 13.5 MB), 34 open file descriptors (AppKit's own). An earlier build wrote `~/Library/Caches/com.seeedjiggler*/Cache.db` and `HTTPStorages` from the update check (the shared URL session caches to disk); the updater now uses an ephemeral session and after the check no such files exist.

* **17-minute run under launchd** (test build from `/private/tmp` via `launchctl submit`, emulated board, screen locked): 208 heartbeats, largest gap 6.0 s (the board's LED timeout is 30 s), 21 jiggles 50 s apart. This was done to look for App Nap throttling; the app held a `ProcessInfo` activity then; it was later removed (see below). It does not reproduce "user busy in another app".
* **Keep-awake (`pmset`):** with the assertions held for 26 minutes (display sleep setting 20 min), no "Display is turned off" event occurred after the display was woken. The session was already locked when the test began, so this shows display sleep is prevented, not that the lock is.

* **Updater** (`tests/test-updater.sh`, local fake GitHub): update offered, binary replaced, process re-executed as the new version; refused with the binary untouched for a corrupted checksum, a program that cannot run, and a release that changed between check and download.

* **No App Nap token:** the app used to hold a `ProcessInfo` activity against App Nap. A test build without it, run under launchd for 18 minutes while the Mac was in use for other things, still sent 233 heartbeats with a largest gap of 6.0 s, so the token was removed.
* **Pause survives restart:** pausing, quitting and relaunching shows paused; unpausing, quitting and relaunching shows not paused (`SJ_PRINT_MODE`).
* **Pause on the real board and re-enumeration:** see [how-it-works.md](how-it-works.md#verification-status).

## Not covered

* A multi-hour or multi-day memory watch of the app (the earlier C engine had a 15-minute watch with flat memory; that does not transfer to the Swift app).
* A long run with the jiggle path active against the real board, and board re-enumeration with the app running.

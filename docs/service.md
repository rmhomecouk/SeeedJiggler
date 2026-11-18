# Running as a service (macOS LaunchAgent)

The host service is a small **native C program** (`host/seeedjiggler.c`). It is built for low overhead:

* ~3.5 MB resident (measured), negligible CPU (wakes once every 5 s)
* **No logging and no disk writes at runtime** — output goes to `/dev/null`, no log files, no caches
* No child processes — the idle time is read directly from IOKit (no `ioreg` spawns)
* Runs at background priority (`Nice 10`, `ProcessType Background`, `LowPriorityIO`)

## Install

```bash
scripts/install-service.sh
```

Optional settings (baked into the agent; re-run to change them):

```bash
IDLE_SECS=180 JIGGLE_EVERY=60 scripts/install-service.sh
```

What the script does:

1. Compiles `host/seeedjiggler.c` to `build/seeedjiggler` (needs the Xcode command line tools: `xcode-select --install`).
2. Writes `~/Library/LaunchAgents/com.seeedjiggler.plist`, pointing at that binary.
3. Loads it into your GUI session (`launchctl bootstrap gui/<uid>`) and starts it immediately.

The agent uses `RunAtLoad` (start at login) and `KeepAlive` (restart on exit, throttled to once per 10 s).

> It must be a **LaunchAgent** (per-user, GUI session), not a LaunchDaemon: idle time is read from the logged-in user's HID system.

## Check it

```bash
launchctl print gui/$(id -u)/com.seeedjiggler | grep -E "state|pid|runs|last exit"
ps -o pid,rss,command -p $(pgrep seeedjiggler)        # rss is in KB
```

There is no log. To see what it is doing, stop the service and run it in the foreground with `-v`:

```bash
launchctl bootout gui/$(id -u)/com.seeedjiggler
IDLE_SECS=10 JIGGLE_EVERY=10 build/seeedjiggler -v    # prints "jiggled" lines to the terminal
```

On the board, the TX LED flashes on every jiggle, and the yellow LED is solid while the service's heartbeat is being received. `python3 -B -I host/hid.py status` reports what the board has received (`hb` heartbeats, `mv` moves, `fb=0` when the service is healthy); with `-v` the foreground service prints the same status line every cycle.

## Stop temporarily

```bash
launchctl bootout gui/$(id -u)/com.seeedjiggler     # stop
scripts/install-service.sh                          # start again
```

While the service is stopped, the board's watchdog notices the missing heartbeat after 30 s and jiggles by itself (yellow LED blinks). See [how-it-works.md](how-it-works.md#watchdog-fallback-firmware).

## Uninstall

```bash
scripts/uninstall-service.sh
```

## Notes

* **Moved or renamed the repo?** Re-run `scripts/install-service.sh`; the plist stores an absolute path to `build/seeedjiggler`.
* **Board unplugged?** The service stays alive and silently retries every 5 s. It finds the board by USB vendor/product ID (`0x2886`/`0x802F`) and confirms it with the firmware's `SEEEDJIGGLER` reply before sending anything, so other USB serial devices are never touched.
* Don't run the service and a manual foreground copy at the same time.

# Running as a service (macOS LaunchAgent)

By default `host/idlejiggle.py` only runs while a terminal is open. Install it as a per-user **LaunchAgent** so it starts at login and is restarted if it ever exits.

## Install

```bash
scripts/install-service.sh
```

Optional settings (written into the agent, re-run to change them):

```bash
IDLE_SECS=180 JIGGLE_EVERY=60 scripts/install-service.sh
```

What the script does:

1. Writes `~/Library/LaunchAgents/com.seeedjiggler.plist`, pointing at **this checkout's** `host/idlejiggle.py` and your `python3` (`python3 -I`).
2. Loads it into your GUI session (`launchctl bootstrap gui/<uid>`) and starts it immediately.
3. Logs to `~/Library/Logs/SeeedJiggler.log`.

The agent uses `RunAtLoad` (start at login) and `KeepAlive` (restart on exit, throttled to once per 10 s).

> It must be a **LaunchAgent** (per-user, GUI session), not a LaunchDaemon: idle time is read from the logged-in user's HID system.

## Check it

```bash
launchctl print gui/$(id -u)/com.seeedjiggler | grep -E "state|pid|last exit"
tail -f ~/Library/Logs/SeeedJiggler.log
```

Log lines: `jiggled` (a jiggle was sent), `board unavailable, will keep retrying` / `board reconnected` (unplug/replug).

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

* **Moved or renamed the repo?** Re-run `scripts/install-service.sh`; the plist stores an absolute path.
* **Changed Python (e.g. new Homebrew version)?** The script records `command -v python3` at install time (normally the stable `/opt/homebrew/bin/python3` symlink); re-run if it breaks.
* Don't run the service and a manual `python3 host/idlejiggle.py` at the same time.

# Testing

## Memory and leaks

The app is meant to run for months, so it is checked for leaks and unbounded growth.

| Resource | Lifetime |
|----------|----------|
| `IOHIDSystem` service (idle time) | opened once, held for the process lifetime |
| `HIDIdleTime` property object | one per 5 s cycle, ARC-managed |
| IOKit serial-device iterator and services (board lookup) | per lookup (every cycle while no port is open, and on hot-plug), released on every path |
| Serial port file descriptor | opened when the board is found, held; closed on any write error or failed verification |
| Hot-plug notification port and its two iterators | created once at launch |
| Power assertions (keep-awake) | created on demand, released on Off, timer end, restart or quit |

```bash
leaks $(pgrep -x SeeedJiggler)                    # expect: "0 leaks for 0 total leaked bytes"
ps -o pid,rss,command -p $(pgrep -x SeeedJiggler) # rss in KB (includes shared AppKit pages)
lsof -p $(pgrep -x SeeedJiggler) | wc -l          # open file descriptors should stay constant
```

Result (installed build, 45 s after launch so the first update check had run, board attached): 0 leaks, physical footprint 13.3 MB (peak 13.5 MB), 34 open file descriptors (AppKit's own). The update check uses an ephemeral URL session; with the shared session it wrote `~/Library/Caches/com.seeedjiggler*/Cache.db`, and after the change no such files exist.

## Test builds and hooks

`app/SeeedJiggler.swift` compiles test-only hooks in with `-DTESTPORT`; they are environment variables and are not in release builds:

| Variable | Effect |
|----------|--------|
| `SJ_PORT` | use this pseudo-terminal instead of looking for the USB board |
| `SJ_NO_GUARD=1` | skip the one-instance check (test programs run beside the real app) |
| `SJ_IDLE=<s>` | idle threshold |
| `SJ_PAUSE_AFTER=<s>`, `SJ_QUIT_AFTER=<s>` | toggle pause / quit after that many seconds |
| `SJ_SET_AWAKE=forever\|hours` | turn keep-awake on at launch |
| `SJ_TOGGLE_LOGIN=1` | run the *Start at login* toggle once and exit (use with `CFFIXED_USER_HOME=<temp home>`) |
| `SJ_API`, `SJ_AUTO_INSTALL=1`, `SJ_RESTART=launchd` | point the updater at a fake GitHub, run check + install without asking, restart the launchd way |
| `SJ_PRINT_MODE=1`, `SJ_PRINT_VERSION=1` | print state / version and exit |

`tests/fakeboard.py <seconds>` opens a pty pair, prints the slave name, answers `?` with a `SEEEDJIGGLER` status line and `M` with `OK`, and records every command with a timestamp. `tests/fake_github.py` fakes the three GitHub endpoints the updater uses.

```bash
python3 tests/fakeboard.py 60 &                 # prints /dev/ttysNNN
swiftc -O -DTESTPORT -o /tmp/sjtest app/SeeedJiggler.swift -framework AppKit -framework IOKit
SJ_PORT=/dev/ttysNNN SJ_NO_GUARD=1 /tmp/sjtest
tests/test-updater.sh                           # updater, restart and persistence cases (stop the real app first)
```

## Results (2026-11-18, Apple silicon, macOS 27)

Against the emulated board:

* **Engine** (60 s, Mac already idle > 2 min): the board was verified with `?`, heartbeats arrived every 5.0 s, jiggles (`M 8 0`, `M -8 0`, 0.1–0.2 s apart) at t = 1.3 s and t = 47.3 s.
* **Pause** (`SJ_PAUSE_AFTER=20`): heartbeats continued through and after the pause; the jiggle due at about 47 s did not happen.
* **Pause and keep-awake survive a restart** (`SJ_PRINT_MODE`): paused/not paused, keep-awake "until I turn it off", and a timed choice with its end time are restored.
* **Start at login toggle** (fake home, program under its `Documents`): copied byte-identically to `~/.local/bin/SeeedJiggler`, the plist points at the copy, toggling again removes the plist.
* **launchd `KeepAlive = {SuccessfulExit = false}`:** after a normal quit the job was not restarted; after `kill -9` it was restarted with a new pid within 9 s.
* **17-minute and 18-minute runs under launchd** (emulated board, with and without an `ProcessInfo` activity token against App Nap, the second while the Mac was in use for other things): 208 and 233 heartbeats, largest gap 6.0 s in both (the board's LED timeout is 30 s). The token was removed.
* **Updater** (`tests/test-updater.sh`, local fake GitHub): update offered; program replaced; the new program started both by hand (spawned) and under launchd (`KeepAlive` restart); refused with the program untouched for a corrupted checksum, a program that cannot run, and a release that changed between check and download; the one-instance check (real guard) does not block the copy that is being replaced.
* **Keep-awake (`pmset`):** both assertions appear while on and none after Off; in a 26-minute test (display sleep 20 min) no "Display is turned off" event occurred after the display was woken. The session was already locked at the start, so this shows display sleep is prevented, not that the lock is.

On the real machine:

* **Real GitHub:** the workflow built and published the release; the downloaded asset matched its checksum, ran, reported its commit and targets macOS 13. A test copy with an older version updated itself from the real release (offered, downloaded, verified, vetted, replaced; byte-identical to the asset).
* **Update through the real menu** (accessibility scripting): "Check for updates…" showed the confirmation dialog with the right text; "Install and Restart" made launchd restart the app (exit 75), with a new pid and version, no `.old` or `.new` files left, board `app=1` and a normal menu bar icon.
* **One instance:** a second launch of the program beside the running login item shows "SeeedJiggler is already running" and exits.
* **Launcher app:** `open ~/Applications/SeeedJiggler.app` with nothing running started the program (parent launchd, board `app=1`, one status item, mouse icon in the menu bar); Spotlight finds it; with the program already running the second launch shows the dialog. The launcher starts the program as a separate process (running it in place left no menu bar icon) and the dialog is shown by `osascript` (an app-owned alert stayed hidden when started from Finder).
* Pause, re-enumeration and the unplug/replug result are in [how-it-works.md](how-it-works.md#verification-status).

## Not covered

* A multi-hour or multi-day memory watch of the app.
* A long run with the jiggle path active against the real board.
* The update feedback lines ("Updating…", "✓ Updated to …"), the launcher's login-item start, and the hand-started update restart through the real menu are covered by the tests above only in part; see the open list in [app.md](app.md#not-verified).

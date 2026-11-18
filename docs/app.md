# The app

`menubar/SeeedJiggler.swift` is the whole host side in one file: the idle-aware jiggle engine, board detection, the menu bar UI, keep-awake and start-at-login. It replaced a separate native C service plus a menu bar front end.

## Install

```bash
scripts/install.sh     # builds build/SeeedJiggler, starts it, and starts it at every login
scripts/uninstall.sh   # quit it, remove the login item (and the run-from copy, if one was made)
scripts/build.sh       # build only; run build/SeeedJiggler by hand
```

Needs the Xcode command line tools. No logs are written. When the repo is under `~/Documents`, `~/Desktop` or `~/Downloads`, the installer and the *Start at login* menu item run a **copy** of the binary from `~/.local/bin` (`BIN_DIR=... scripts/install.sh` to choose elsewhere), because a LaunchAgent started from those folders hung here before `main` (see [how-it-works.md](how-it-works.md)). Re-run `scripts/install.sh` after rebuilding to refresh the copy.

## Auto-start

*Start at login* in the menu adds or removes `~/Library/LaunchAgents/com.seeedjiggler.menu.plist` (`RunAtLoad`, `KeepAlive` only after a crash so Quit stays quit, output to `/dev/null`). Turning it off removes the plist for the next login; it does not quit the running app. `scripts/install.sh` does the same thing and also starts the app immediately.

## Quit means no jiggling

The app has full control of the board. The firmware never moves the mouse by itself, so after **Quit** (or a crash, until launchd restarts the app about 10 s later) nothing jiggles. With no heartbeat for 30 s the board only blinks its yellow LED. This needs the current firmware: a board still on the older firmware jiggles by itself 30 s after the app stops, so reflash it ([hardware-and-flashing.md](hardware-and-flashing.md)).

## Icon states

| Icon | Meaning |
|---|---|
| Mouse with green dot | Board plugged in and verified, watching, Mac in use |
| Cursor with motion lines | Mac idle, jiggling |
| Grey slashed mouse | Paused from the menu (heartbeats continue, no jiggling) |
| Orange slashed mouse | Board not found (unplugged, or in bootloader mode) |
| Orange mouse with dot | Board present but not answering as SeeedJiggler |
| Cup | Keep Mac awake is on |

Priority when several apply: no board, not responding, paused, keep-awake, jiggling, watching.

## Menu

* **Jiggle when idle**: tick to jiggle, untick to pause. While paused the app still sends heartbeats, so the board shows the app is present.
* **Keep Mac awake**: Off, 1 hour, 4 hours, Until I turn it off. Holds two power assertions (prevent idle display sleep and idle system sleep), so the screen stays on and the screen saver / inactivity lock do not start. Released when the timer ends, when set to Off, or when the app quits. It does **not** stop a manual lock (Ctrl-Cmd-Q), closing the lid, or a lock enforced by a policy. Jiggling already counts as user activity, so keep-awake matters mainly while paused, quit, or with the board unplugged.
* **Idle threshold**: 1, 2, 5, 10 or 15 minutes (default 2). Stored as the app's only preference, written when you change it.
* **Start at login**: see above.
* **Quit**.

## How it stays light

No polling for the board's presence: IOKit hot-plug notifications. One timer, every 5 s with 1 s leeway, on a background queue: heartbeat, read `HIDIdleTime`, maybe jiggle. The serial port is held open. About 12 MB physical footprint (AppKit).

## Not verified

Real-board checks that passed are listed in [how-it-works.md](how-it-works.md#verification-status). Still unverified:

* Pause from the menu on the real board (emulator only), unplug/replug with the app running, and the Jiggling, paused and "not responding" icons beyond the one seen (jiggling, on a dark wallpaper). Light-wallpaper colour and the look of the menu itself were not seen.
* Keep-awake: `pmset -g assertions` shows both assertions while on and none after Off, and in a 26-minute test the display did not sleep (20-minute setting). The Mac was already locked when that test began, so preventing the *lock* is not established.
* Start at login: `scripts/install.sh` and the menu item's code path (via a test hook in a fake home) were tested; the menu item itself was not clicked.
* Nothing jiggles between a reboot and login, and a hung app leaves nothing jiggling (the board no longer covers for it).

# The app

`app/SeeedJiggler.swift` is the whole host side in one file: the idle-aware jiggle engine, board detection, the menu bar UI, keep-awake, updates and start-at-login. Apple silicon Macs running macOS 13 or later (the build is arm64 only).

## Install

```bash
scripts/install.sh     # builds build/SeeedJiggler, starts it, starts it at every login, creates the launcher app
scripts/uninstall.sh   # quit it; remove the login item, the launcher and the run-from copy (if one was made)
scripts/build.sh       # build only; run build/SeeedJiggler by hand
```

Needs the Xcode command line tools. No logs are written. When the repository is under `~/Documents`, `~/Desktop` or `~/Downloads`, the installer and the *Start at login* menu item run a **copy** of the program from `~/.local/bin` (`BIN_DIR=... scripts/install.sh` chooses another folder), because a LaunchAgent started from those folders was seen to hang before `main` ([how-it-works.md](how-it-works.md)). Re-run `scripts/install.sh` after rebuilding to refresh the copy.

## Starting it

* **Login item** (*Start at login*, or `scripts/install.sh`): `~/Library/LaunchAgents/com.seeedjiggler.plist` with `RunAtLoad` and `KeepAlive` only after a crash, so Quit stays quit. Turning the menu option off removes the plist for the next login; it does not quit the running app.
* **Launcher app** (`~/Applications/SeeedJiggler.app`, made by `scripts/install.sh`; rebuild just it with `scripts/make-app.sh /path/to/program`): start the app from Spotlight, Launchpad or Finder, for example after Quit. It has its own icon and no Dock icon. If the login item is set up but not running, the launcher starts that job (so launchd supervises the program); otherwise it starts the installed program directly. The launcher holds no copy of the program, so updates keep applying.
* **One instance only.** Two copies would both drive the board, so a second launch shows "SeeedJiggler is already running" and exits without creating an icon or touching the board. The check looks for another process named `SeeedJiggler` owned by the same user, and ignores the copy that started it during an update restart.

A copy started directly (not through launchd) is not restarted after a crash; the login item is the supervised one.

## Quit means no jiggling

The app has full control of the board. The firmware never moves the mouse by itself, so after **Quit** (or a crash, until launchd restarts the app, about 10 s) nothing jiggles. With no heartbeat for 30 s the board only blinks its yellow LED. This needs the current firmware; a board still on the older firmware jiggles by itself 30 s after the app stops, so reflash it ([hardware-and-flashing.md](hardware-and-flashing.md)).

## Updates

Every push to `main` that touches the app triggers `.github/workflows/release.yml`, which builds the app on a GitHub macOS (Apple silicon) runner, checks that the built program reports the commit it was built from, and replaces the rolling **latest** release with `SeeedJiggler-macos-arm64`, its `.sha256`, and notes containing the full commit hash.

The app:

* checks that release 30 s after launch and then daily (*Check for updates automatically*, on by default). A check is one small HTTPS request to `api.github.com` with the generic User-Agent `SeeedJiggler`, over an ephemeral session (nothing is cached or logged on disk). *Check for updates…* does it on demand.
* shows **⬆ Update available (abc1234)…** under the status lines when the release is ahead of the running commit (it asks GitHub, so older or identical releases are not offered).
* installs **only after Install and Restart is confirmed**. Clicking the menu item or *Check for updates…* checks again first, so the confirmation never shows a stale release. It then downloads the program, requires its SHA-256 to match the published one, runs it with `--version` (it must start within 20 s and report the release's commit; the "latest" release is replaced on every push, so if it changed since the check the update is refused with that explanation), keeps the old program as `.old` while it atomically replaces its own executable, and restarts. While installing, the menu shows "Updating…"; after the restart it shows "✓ Updated to <version>".
* restarts under launchd by exiting with a failure status so `KeepAlive` starts the new program (within about 10 s); otherwise it starts the new program itself and exits. If starting fails, the old program is put back. Keep-awake and pause are saved and are restored by the new program.

Limits: the board's firmware is not updated (reflash with `arduino-cli upload`; the app does not check it). The checksum comes from the same release, so it only catches corrupted downloads; it does not protect against a compromised GitHub account. A build with uncommitted changes (`-dirty`) gets a warning in the confirmation; a build from an unpushed or diverged commit is offered the release without one. About shows the commit the program was built from, so builds not made by `scripts/build.sh` show as unknown and are always offered the latest release.

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

**Click the icon** to pause or resume jiggling (the same as the *Jiggle when idle* item; the icon changes at once). **Right-click** it, or Control-click or Option-click, to open the menu. The tooltip says so.

* **SeeedJiggler** (the bold title): About box with the version (short commit, `-dirty` if built with uncommitted changes), build date and the GitHub address, with an *Open on GitHub* button. The version is embedded by `scripts/build.sh` as the program's Info.plist.
* **Status lines**: board connected or not, and Watching / Jiggling / Paused; an update line when one is available, being installed, or just installed.
* **Jiggle when idle**: tick to jiggle, untick to pause. While paused the app still sends heartbeats, so the board shows the app is present. Saved across restarts.
* **Keep Mac awake**: Off, 1 hour, 4 hours, Until I turn it off. Holds two power assertions (prevent idle display sleep and idle system sleep), so the screen stays on and the screen saver / inactivity lock do not start. The choice (and a timed choice's end time) is saved and restored after a restart, login or update; assertions are released when the app quits. It does **not** stop a manual lock (Ctrl-Cmd-Q), closing the lid, or a lock enforced by a policy. Jiggling already counts as user activity, so keep-awake matters mainly while paused, quit, or with the board unplugged.
* **Idle threshold: 2 minutes**: 1, 2, 5, 10 or 15 minutes (default 2); the current value is in the title. Saved when changed.
* **Check for updates… / Check for updates automatically**: see Updates.
* **Start at login**, **Quit**.

## How it stays light

No polling for the board's presence: IOKit hot-plug notifications. One timer, every 5 s with 1 s leeway, on a background queue: heartbeat, read `HIDIdleTime`, maybe jiggle. The serial port is held open. About 13 MB physical footprint (AppKit).

## Not verified

Checks that passed are listed in [how-it-works.md](how-it-works.md#verification-status) and [testing.md](testing.md). Still open:

* **Keep-awake against the lock.** `pmset -g assertions` shows both assertions while on and none after Off, and in a 26-minute test the display did not sleep (20-minute setting), but the Mac was already locked when that test began, so preventing the *lock* is not established. To test it (25+ minutes with the Mac untouched): turn *Keep Mac awake* on (Until I turn it off), untick *Jiggle when idle*, and leave the Mac alone for longer than the display-sleep time (System Settings, Lock Screen). On return, see whether it locked. Then turn keep-awake off, wait the same time, and confirm it does lock, so the Mac is known to lock otherwise.
* The paused and "not responding" icons on screen, and the icons on a light wallpaper.
* A second physical board.
* Nothing jiggles between a reboot and login, and a hung app leaves nothing jiggling (the board no longer covers for it).

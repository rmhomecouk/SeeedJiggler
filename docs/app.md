# The app

`app/SeeedJiggler.swift` is the whole host side in one file: the idle-aware jiggle engine, board detection, the menu bar UI, keep-awake and start-at-login. It replaced a separate native C service plus a menu bar front end.

## Install

```bash
scripts/install.sh     # builds build/SeeedJiggler, starts it, and starts it at every login
scripts/uninstall.sh   # quit it, remove the login item (and the run-from copy, if one was made)
scripts/build.sh       # build only; run build/SeeedJiggler by hand
```

Needs the Xcode command line tools. No logs are written. When the repo is under `~/Documents`, `~/Desktop` or `~/Downloads`, the installer and the *Start at login* menu item run a **copy** of the binary from `~/.local/bin` (`BIN_DIR=... scripts/install.sh` to choose elsewhere), because a LaunchAgent started from those folders hung here before `main` (see [how-it-works.md](how-it-works.md)). Re-run `scripts/install.sh` after rebuilding to refresh the copy.

## More than one instance

You can start as many copies as you like (for example one per board). Each copy takes an advisory lock (`flock`) on the board's serial port while it holds it open, and claims the first board it can lock; a copy that finds every board already claimed shows an orange icon and "Board is used by another SeeedJiggler" until the board frees up. So two copies never drive the same board, and two boards get one copy each. Each copy has its own menu bar icon and its own settings while running; pause and idle threshold are saved in the app's shared preferences and only read at launch, so changing them in one copy does not change another copy that is already running. Only one login item exists. `tools/hid.py` is not blocked by the lock.

## Auto-start

*Start at login* in the menu adds or removes `~/Library/LaunchAgents/com.seeedjiggler.plist` (`RunAtLoad`, `KeepAlive` only after a crash so Quit stays quit, output to `/dev/null`). Turning it off removes the plist for the next login; it does not quit the running app. `scripts/install.sh` does the same thing and also starts the app immediately.

## Quit means no jiggling

The app has full control of the board. The firmware never moves the mouse by itself, so after **Quit** (or a crash, until launchd restarts the app about 10 s later) nothing jiggles. With no heartbeat for 30 s the board only blinks its yellow LED. This needs the current firmware: a board still on the older firmware jiggles by itself 30 s after the app stops, so reflash it ([hardware-and-flashing.md](hardware-and-flashing.md)).

## Updates

Every push to `main` that touches the app triggers `.github/workflows/release.yml`, which builds the app on a GitHub macOS (Apple silicon) runner and replaces the rolling **latest** release with `SeeedJiggler-macos-arm64`, its `.sha256`, and notes containing the full commit hash. The app:

* checks that release 30 s after launch and then daily (menu: *Check for updates automatically*, on by default; it is one small HTTPS request to `api.github.com` with the generic User-Agent `SeeedJiggler`, nothing is logged). *Check for updates…* does it on demand.
* shows **⬆ Update available (abc1234)…** at the top of the menu when the release is newer than the running commit (it asks GitHub whether the release is ahead of this build, so older or identical releases are not offered).
* installs **only after you click Install and Restart**: it downloads the binary, requires its SHA-256 to match the published `.sha256`, runs it with `--version` (it must start on this Mac and report the release's commit), keeps the old program as `.old` while it atomically replaces its own executable (the `~/.local/bin` copy if that is what runs), releases keep-awake, and re-executes itself (same process, launchd keeps supervising); if the re-exec fails the old program is put back. Jiggling pauses for a moment, and a paused state is not remembered across the restart. The release is built for macOS 13 or later.

What this does **not** do: update the board's firmware (reflash with `arduino-cli upload`; the app does not check it), or protect you from a compromised GitHub account: the checksum comes from the same release, so it only catches corrupted downloads. Intel Macs are not supported (the release is arm64 only). A build with uncommitted changes (`-dirty`) gets a warning in the confirmation text; a build from an unpushed or diverged commit is offered the release without one. The *version* shown by About is the commit the binary was built from, so builds not made by `scripts/build.sh` show as unknown and are always offered the latest release.

Tested: `tests/test-updater.sh` runs the whole check, download, verify, replace and re-exec path against a local fake of the API (including a corrupted checksum and a non-running program being refused). On GitHub the workflow built and published the release (the first run was cancelled because no macOS runner was ever assigned; a re-run succeeded), the downloaded asset matched its checksum, ran, reported its commit and targets macOS 13. A test copy with an older version then updated itself from the real release (offered, downloaded, verified, vetted, replaced; the result is byte-identical to the asset). Not tested: the confirmation dialogs on screen, and an update of the installed app (it needs a release newer than the installed build).

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

* **SeeedJiggler** (the bold title): About box with the version (short commit, `-dirty` if built with uncommitted changes), build date and the GitHub address, with an *Open on GitHub* button. The version is embedded by `scripts/build.sh` as the binary's Info.plist.
* **Jiggle when idle**: tick to jiggle, untick to pause. While paused the app still sends heartbeats, so the board shows the app is present.
* **Keep Mac awake**: Off, 1 hour, 4 hours, Until I turn it off. Holds two power assertions (prevent idle display sleep and idle system sleep), so the screen stays on and the screen saver / inactivity lock do not start. Released when the timer ends, when set to Off, or when the app quits. It does **not** stop a manual lock (Ctrl-Cmd-Q), closing the lid, or a lock enforced by a policy. Jiggling already counts as user activity, so keep-awake matters mainly while paused, quit, or with the board unplugged.
* **Idle threshold**: 1, 2, 5, 10 or 15 minutes (default 2). Stored as the app's only preference, written when you change it.
* **Check for updates… / Check for updates automatically**: see Updates.
* **Start at login**: see above.
* **Quit**.

## How it stays light

No polling for the board's presence: IOKit hot-plug notifications. One timer, every 5 s with 1 s leeway, on a background queue: heartbeat, read `HIDIdleTime`, maybe jiggle. The serial port is held open. About 12 MB physical footprint (AppKit).

## Not verified

Real-board checks that passed are listed in [how-it-works.md](how-it-works.md#verification-status). Still unverified:

* The About box was seen in a screenshot (version, build date, address, both buttons; that capture predates the mouse icon, which replaced a generic folder icon). The update dialogs have not been seen.
* The Jiggling, paused, "not responding" and "in use" icons beyond the one seen (jiggling, on a dark wallpaper), light-wallpaper colour, and the look of the menu itself.
* Keep-awake: `pmset -g assertions` shows both assertions while on and none after Off, and in a 26-minute test the display did not sleep (20-minute setting). The Mac was already locked when that test began, so preventing the *lock* is not established.
* Start at login: `scripts/install.sh` and the menu item's code path (via a test hook in a fake home) were tested; the menu item itself was not clicked.
* Nothing jiggles between a reboot and login, and a hung app leaves nothing jiggling (the board no longer covers for it).

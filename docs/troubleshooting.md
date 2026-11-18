# Troubleshooting

**Board not found / `SeeedJiggler board not found`** — Check `ioreg -p IOUSB -l -w0 | grep "USB Product"`: a working board is "Seeed XIAO M0" (vendor `0x2886`, product `0x802F`). "Seeeduino XIAO" means it is sitting in the bootloader — reflash it or power-cycle. The host tools only talk to a port that answers `?` with `SEEEDJIGGLER`, so a board still running other firmware is (correctly) ignored. Try another cable (many are charge-only). `python3 -B -I tools/hid.py status` tests the whole path.

**Yellow LED blinking** — The board is connected but hearing no heartbeats: the app is not running. The board does nothing on its own in that state. Start the app (or `scripts/install.sh`); `hid.py status` shows `app=0` until a heartbeat arrives. (A board still on the old firmware also jiggles by itself here; reflash it.)

**Won't enter bootloader** — Double-tap RST→GND (see [hardware-and-flashing.md](hardware-and-flashing.md)). The bootloader shows as "Seeeduino XIAO".

**Compile error `Mouse.h: No such file`** — `arduino-cli lib install Mouse`.

**macOS asks about a new keyboard** — Only with older full firmware. The current firmware has no keyboard, so this should not appear.

**Cursor twitches while I'm working** — You have been idle longer than the threshold (raise it in the app's menu), or the board is still on the old firmware that jiggles by itself when the app is not running: reflash it.

**Status still goes "Away"** — Lower the idle threshold in the app's menu; confirm the TX LED flashes on each jiggle, or check `hid.py status`: `mv` should rise by 2 per jiggle (the app keeps no log).

**The app is not running after reboot/logout** — Tick *Start at login* in its menu (or run `scripts/install.sh`). Until then nothing jiggles.

**Serial port busy during upload** — Quit the app while flashing (menu → Quit), then start it again.


**App never appears / no heartbeats (≈144 KB footprint)** — A LaunchAgent started from a binary in `~/Documents`, `~/Desktop` or `~/Downloads` can hang before `main` (see [how-it-works.md](how-it-works.md)). `scripts/install.sh` and the *Start at login* item run a copy from `~/.local/bin` for that reason.

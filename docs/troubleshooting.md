# Troubleshooting

**Board not found / `XIAO not found`** — Check `ls /dev/cu.usbmodem*` and `ioreg -p IOUSB -l -w0 | grep "USB Product"`. A working board is "Seeed XIAO M0". Try another cable (many are charge-only).

**Won't enter bootloader** — Double-tap RST→GND (see [hardware-and-flashing.md](hardware-and-flashing.md)). The bootloader shows as "Seeeduino XIAO".

**Compile error `Keyboard.h: No such file`** — `arduino-cli lib install Keyboard Mouse`.

**macOS asks about a new keyboard** — Expected on first connect (Keyboard Setup Assistant). You can close it.

**Cursor twitches while I'm working** — Either you've been idle ≥ 120 s (raise `IDLE_SECS`), or the service isn't running and the board is in fallback (yellow LED blinking). Start `host/idlejiggle.py`.

**Status still goes "Away"** — Raise jiggle frequency (`JIGGLE_EVERY`) or lower `IDLE_SECS`; confirm the TX LED flashes on each jiggle and `jiggle.log` shows "jiggled".

**Service stops after reboot/logout** — It is not installed as a LaunchAgent by this repo. Add your own, or rely on the board's fallback.

**Serial port busy during upload** — Stop `idlejiggle.py` while flashing.

**Verifying with Teams** — `host/teamswatch.py <window-id>` samples the status badge by screen-capturing the Teams window (`screencapture -l`). The pixel offsets are tuned to one Retina layout and the window id changes when Teams restarts; treat it as an experiment.

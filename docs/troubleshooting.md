# Troubleshooting

**Board not found / `XIAO not found`** — Check `ls /dev/cu.usbmodem*` and `ioreg -p IOUSB -l -w0 | grep "USB Product"`. A working board is "Seeed XIAO M0". Try another cable (many are charge-only).

**Won't enter bootloader** — Double-tap RST→GND (see [hardware-and-flashing.md](hardware-and-flashing.md)). The bootloader shows as "Seeeduino XIAO".

**Compile error `Keyboard.h: No such file`** — `arduino-cli lib install Keyboard Mouse`.

**macOS asks about a new keyboard** — Expected on first connect (Keyboard Setup Assistant). You can close it.

**Cursor twitches while I'm working** — Either you've been idle ≥ 120 s (raise `IDLE_SECS`), or the service isn't running and the board is in fallback (yellow LED blinking). Start the service (`scripts/install-service.sh`, or `build/seeedjiggler -v` in a terminal).

**Status still goes "Away"** — Raise jiggle frequency (`JIGGLE_EVERY`) or lower `IDLE_SECS`; confirm the TX LED flashes on each jiggle, or run `build/seeedjiggler -v` in a terminal (the service itself keeps no log) to see "jiggled" lines.

**Service stops after reboot/logout** — Install the LaunchAgent: see [service.md](service.md). Until then the board's fallback keeps jiggling.

**Serial port busy during upload** — Stop the service while flashing (`scripts/uninstall-service.sh`, or `launchctl bootout gui/$(id -u)/com.seeedjiggler`), then reinstall.


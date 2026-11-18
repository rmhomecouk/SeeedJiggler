# Serial protocol

The firmware exposes a USB CDC serial port (115200 baud) alongside the HID keyboard and mouse (a composite USB device). One command per line, newline-terminated; the board replies `OK`.

| Command | Meaning | Example |
|---------|---------|---------|
| `H` | Heartbeat — no action, resets the watchdog | `H` |
| `T <text>` | Type text | `T hello world` |
| `K <combo>` | Key combo, `+`-separated | `K cmd+space`, `K ctrl+shift+t` |
| `M <dx> <dy>` | Move mouse relatively (any size, chunked to ±127 steps) | `M 100 -40` |
| `S <n>` | Scroll wheel (+up / −down) | `S -3` |
| `C <l\|r\|m>` | Click | `C r` |
| `D <l\|r\|m>` | Press and hold | `D l` |
| `U <l\|r\|m>` | Release | `U l` |

Key names: `ctrl shift alt/opt cmd/gui/win enter/return esc tab backspace delete space up down left right home end pageup pagedown f1`–`f12`, or any single character.

**Any** received line (not just `H`) counts as a heartbeat for the watchdog.

From the host use `host/hid.py` (or `host/seeedjiggler.c`, which speaks the same protocol), which finds the port by globbing `/dev/cu.usbmodem*` on every call (so it survives unplug/replug).

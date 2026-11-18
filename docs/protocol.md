# Serial protocol

The firmware exposes a USB CDC serial port (115200 baud) alongside the HID keyboard and mouse (a composite USB device). One command per line, newline-terminated; the board replies `OK`.

| Command | Meaning | Example |
|---------|---------|---------|
| `H` | Heartbeat — resets the watchdog; **no reply** | `H` |
| `?` | Status query. Replies `SEEEDJIGGLER 1 fb=<0\|1> age=<ms> hb=<n> mv=<n>`: ID + protocol version, fallback flag, ms since the last command, heartbeats and `M` commands received. **Does not** feed the watchdog | `?` |
| `T <text>` | Type text | `T hello world` |
| `K <combo>` | Key combo, `+`-separated | `K cmd+space`, `K ctrl+shift+t` |
| `M <dx> <dy>` | Move mouse relatively (any size, chunked to ±127 steps) | `M 100 -40` |
| `S <n>` | Scroll wheel (+up / −down) | `S -3` |
| `C <l\|r\|m>` | Click | `C r` |
| `D <l\|r\|m>` | Press and hold | `D l` |
| `U <l\|r\|m>` | Release | `U l` |

Key names: `ctrl shift alt/opt cmd/gui/win enter/return esc tab backspace delete space up down left right home end pageup pagedown f1`–`f12`, or any single character.

**Any** received line other than `?` counts as a heartbeat for the watchdog. Commands other than `H` and `?` are acknowledged with `OK`.

`T`, `K`, `S`, `C`, `D`, `U` exist only in the **full** firmware build; the [jiggler-only build](hardware-and-flashing.md#jiggler-only-build) accepts just `H`, `?` and `M`.

`T` and `K` use the Arduino `Keyboard` library, which assumes a **US keyboard layout**; they have had only light testing.

From the host use `host/hid.py` (`hid.py status` prints the `?` line) or `host/seeedjiggler.c`, which speaks the same protocol. Both open the port in **raw mode** at 115200 baud — never 1200, which resets the board into its bootloader.

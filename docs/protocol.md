# Serial protocol

The firmware exposes a USB CDC serial port (115200 baud) alongside the HID mouse (a composite USB device; the firmware has no keyboard). One command per line, newline-terminated; the board replies `OK`.

| Command | Meaning | Example |
|---------|---------|---------|
| `H` | Heartbeat — drives the "app present" LED; **no reply** | `H` |
| `?` | Status query. Replies `SEEEDJIGGLER 2 app=<0\|1> age=<ms> hb=<n> mv=<n>`: ID + protocol version, app-present flag (`app=0`: no heartbeat for 30 s), ms since the last command, heartbeats and `M` commands received. **Does not** feed the watchdog | `?` |
| `M <dx> <dy>` | Move mouse relatively (any size, chunked to ±127 steps) | `M 100 -40` |

**Any** received line other than `?` counts as a heartbeat. Commands other than `H` and `?` are acknowledged with `OK`.

Anything else, including `T`, `K`, `S`, `C`, `D`, `U` from earlier firmware, answers `ERR`.

From the host use `host/hid.py` (`hid.py status` prints the `?` line) or the app (`menubar/SeeedJiggler.swift`), which speaks the same protocol. Both open the port in **raw mode** at 115200 baud — never 1200, which resets the board into its bootloader.

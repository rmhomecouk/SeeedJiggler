#!/usr/bin/env python3
"""Talk to the SeeedJiggler board.

  hid.py status                 board status line (does not feed the watchdog)
  hid.py move 100 0             relative mouse move
  hid.py click [l|r|m]          (full firmware build only)
  hid.py type "text"            (full firmware build only; US keyboard layout assumed)
  hid.py key cmd+space          (full firmware build only)
  hid.py scroll -3 | down l | up l | raw "M 5 5"

The board is the first /dev/cu.usbmodem* that answers "?" with SEEEDJIGGLER. Set HID_PORT=/dev/cu.usbmodemXXXX
to skip probing (probing sends a harmless "?" line to each candidate serial port).
"""
import glob, os, select, sys, termios, time, tty

ID = b"SEEEDJIGGLER"


def _open(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    a = termios.tcgetattr(fd)
    a[2] |= termios.CLOCAL | termios.CREAD
    a[4] = a[5] = termios.B115200  # never 1200: that baud rate resets the board into its bootloader
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def _read(fd, wait):
    out = b""
    end = time.time() + wait
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            break
        chunk = os.read(fd, 256)
        if not chunk:
            break
        out += chunk
        end = min(end, time.time() + 0.05)  # got data: only wait briefly for the rest
    return out


def open_board():
    paths = [os.environ["HID_PORT"]] if os.environ.get("HID_PORT") else sorted(glob.glob("/dev/cu.usbmodem*"))
    for p in paths:
        try:
            fd = _open(p)
        except OSError:
            continue
        os.write(fd, b"?\n")
        if ID in _read(fd, 0.5):  # stale "OK" replies may precede the status line
            return fd
        os.close(fd)
    raise FileNotFoundError("SeeedJiggler board not found")


def send(lines, wait=0.3):
    """Send command lines, return the board's reply lines."""
    fd = open_board()
    try:
        for l in lines:
            os.write(fd, (l + "\n").encode())
            time.sleep(0.05)
        termios.tcdrain(fd)
        return _read(fd, wait).decode(errors="replace").split()
    finally:
        os.close(fd)


def status():
    fd = open_board()
    try:
        os.write(fd, b"?\n")
        for ln in _read(fd, 0.5).decode(errors="replace").splitlines():
            if ln.startswith(ID.decode()):
                return ln.strip()
        return ""
    finally:
        os.close(fd)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    c, *r = sys.argv[1:]
    m = {"type": "T", "key": "K", "move": "M", "click": "C", "scroll": "S", "down": "D", "up": "U"}
    arg = " ".join(r)
    try:
        if c == "status":
            print(status())
        elif c == "raw":
            print(" ".join(send([arg])))
        elif c in m:
            print(" ".join(send([(m[c] + " " + arg).strip()])) or "(no reply)")
        else:
            sys.exit(__doc__)
    except OSError as e:
        sys.exit(str(e))

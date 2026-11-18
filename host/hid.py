#!/usr/bin/env python3
"""Send HID commands to the XIAO. Usage: hid.py type "text" | key cmd+space | move 100 0 | click [l|r|m] | scroll -3 | raw "M 5 5" """
import sys, glob, termios, os, time
def port():
    p = glob.glob('/dev/cu.usbmodem*')
    if not p: raise FileNotFoundError("XIAO not found")
    return p[0]
def send(lines):
    fd = os.open(port(), os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd); a[4] = a[5] = termios.B115200; termios.tcsetattr(fd, termios.TCSANOW, a)
    for l in lines:
        os.write(fd, (l + "\n").encode())
        time.sleep(0.05)
    time.sleep(0.2); os.close(fd)
if __name__ == "__main__":
    c, *r = sys.argv[1:]
    m = {"type": "T", "key": "K", "move": "M", "click": "C", "scroll": "S", "down": "D", "up": "U", "raw": ""}
    arg = " ".join(r)
    try:
        send([(m[c] + " " + arg).strip() if c != "raw" else arg])
    except OSError as e:
        sys.exit(str(e))

#!/usr/bin/env python3
"""Jiggle the mouse via the XIAO when the Mac has been idle. Env: IDLE_SECS (default 120), JIGGLE_EVERY (default 45)."""
import subprocess, re, time, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hid
IDLE = float(os.environ.get("IDLE_SECS", 120)); EVERY = float(os.environ.get("JIGGLE_EVERY", 45))
def idle_secs():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    return int(re.search(r'"HIDIdleTime" = (\d+)', out).group(1)) / 1e9
down = False
last_jiggle = None   # monotonic time of our last jiggle
last_real = time.monotonic()  # monotonic time of last REAL user input
while True:
    try:
        hid.send(["H"])   # heartbeat: tells the board the service is alive (keeps its fallback off)
        if down: print(time.strftime("%H:%M:%S"), "board reconnected", flush=True); down = False
    except Exception as e:
        if not down: print(time.strftime("%H:%M:%S"), "board unavailable, will keep retrying:", e, flush=True)
        down = True
    now = time.monotonic(); idle = idle_secs()
    # idle < time since our jiggle means genuine input arrived after it
    if last_jiggle is None or idle < (now - last_jiggle) - 2:
        last_real = now - idle; last_jiggle = None
    if now - last_real >= IDLE and (last_jiggle is None or now - last_jiggle >= EVERY):
        try:
            hid.send(["M 8 0", "M -8 0"]); last_jiggle = time.monotonic()
            print(time.strftime("%H:%M:%S"), "jiggled", flush=True)
            if down: print(time.strftime("%H:%M:%S"), "board reconnected", flush=True); down = False
        except Exception as e:
            if not down: print(time.strftime("%H:%M:%S"), "board unavailable, will keep retrying:", e, flush=True)
            down = True
    time.sleep(5)

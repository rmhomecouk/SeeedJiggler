# Memory and leak testing

The service is meant to run for months, so it is checked for leaks and unbounded growth.

## Code audit

There is **no heap allocation** in `host/seeedjiggler.c` apart from two short-lived resources, both released on every path:

| Resource | Created | Released |
|----------|---------|----------|
| `CFTypeRef` from `IORegistryEntryCreateCFProperty` (idle time) | every 5 s | `CFRelease` before returning (all branches reach it) |
| `glob_t` (serial port lookup) | every 5 s | `globfree` unconditionally, including the no-match (board unplugged) path |
| serial port file descriptor | every send | `close` on every path, including write failure |

The `io_service_t` for `IOHIDSystem` is opened once at start and held for the process lifetime.

## Tools

Live check of the running service (works on the installed LaunchAgent):

```bash
leaks $(pgrep -x seeedjiggler)      # expect: "0 leaks for 0 total leaked bytes"
ps -o pid,rss,command -p $(pgrep -x seeedjiggler)     # rss in KB
lsof -p $(pgrep -x seeedjiggler) | wc -l              # open file descriptors should stay constant
```

## Accelerated stress test

Two compile-time macros make the loop run far faster than production so growth shows up in minutes:

* `-DPOLL_SECS=0` — no 5 s sleep between cycles
* `-DPORT_GLOB='"/dev/cu.nonexistent*"'` — simulates an unplugged board (exercises the failure path every cycle)

```bash
clang -O1 -g -DPOLL_SECS=0 -o /tmp/stress_plugged host/seeedjiggler.c -framework IOKit -framework CoreFoundation
clang -O1 -g -DPOLL_SECS=0 -DPORT_GLOB='"/dev/cu.nonexistent*"' -o /tmp/stress_unplugged host/seeedjiggler.c -framework IOKit -framework CoreFoundation
IDLE_SECS=100000 /tmp/stress_plugged &       # IDLE_SECS huge so the cursor is never jiggled
IDLE_SECS=100000 /tmp/stress_unplugged &
# sample: ps -o rss= -p <pid> every 15 s, then: leaks <pid>
```

Stop the LaunchAgent first (`launchctl bootout gui/$(id -u)/com.seeedjiggler`) so the board is not driven by two programs.

## Results (2026-11-18, Apple silicon, macOS)

| Test | Result |
|------|--------|
| `leaks` on the live service | 0 leaks, 872 allocations / 82 KB (all system framework) |
| Stress, board present, 120 s (~500 cycles, 20× production rate) | RSS 2672 → 2688 KB (flat after start-up page-in) |
| Stress, board absent, 120 s (tight loop, millions of cycles) | RSS 2592 KB constant |
| `leaks` after each stress run | 0 leaks, 0 bytes |
| Live service RSS | ~2.7 MB steady |

Not covered: multi-day soak (the stress runs simulate roughly 40 minutes of production cycles for the plugged path and far more for the unplugged path), and the jiggle-send path under stress (not forced, to avoid moving the cursor).

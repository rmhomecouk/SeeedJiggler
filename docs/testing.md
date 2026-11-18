# Memory and leak testing

The service is meant to run for months, so it is checked for leaks and unbounded growth.

## Code audit

There is **no heap allocation** in `host/seeedjiggler.c` apart from short-lived system resources, each released on every path:

| Resource | Created | Released |
|----------|---------|----------|
| `CFTypeRef` from `IORegistryEntryCreateCFProperty` (idle time) | every 5 s | `CFRelease` before returning |
| IOKit serial-device iterator, its services, and the property objects read while matching the board | only when the port is not open (start-up, after unplug) | `IOObjectRelease` / `CFRelease` on every path |
| serial port file descriptor | when the board is (re)found | held open; `close` on any write error or failed verification |

The `io_service_t` for `IOHIDSystem` is opened once at start and held for the process lifetime.

## Tools

Live check of the installed service:

```bash
leaks $(pgrep -x seeedjiggler)      # expect: "0 leaks for 0 total leaked bytes"
ps -o pid,rss,command -p $(pgrep -x seeedjiggler)     # rss in KB
lsof -p $(pgrep -x seeedjiggler) | wc -l              # open file descriptors should stay constant
```

## Accelerated stress test

Compile-time macros make the loop run far faster than production and exercise the rarely-run paths:

| Macro | Effect |
|-------|--------|
| `-DPOLL_SECS=0` | no 5 s sleep between cycles |
| `-DFORCE_REOPEN` | close the port after every send, so **each cycle re-runs the IOKit scan, open and `?` verification** |
| `-DSEEED_VID=0x1L` | simulate an absent board: the IOKit scan runs every cycle and finds nothing |

```bash
F="-O1 -g -DPOLL_SECS=0"; L="-framework IOKit -framework CoreFoundation"
clang $F                       host/seeedjiggler.c $L -o /tmp/s_steady   # held-open port, steady state
clang $F -DFORCE_REOPEN        host/seeedjiggler.c $L -o /tmp/s_reopen   # find/open/verify every cycle
clang $F -DSEEED_VID=0x1L      host/seeedjiggler.c $L -o /tmp/s_absent   # board absent
IDLE_SECS=100000 /tmp/s_steady &    # IDLE_SECS huge so the cursor is never jiggled
# sample: ps -o rss= -p <pid>; lsof -p <pid> | wc -l; finally: leaks <pid>
```

Stop the LaunchAgent first (`launchctl bootout gui/$(id -u)/com.seeedjiggler`) so the board is not driven by several programs at once.

## Results (2026-11-18, Apple silicon, macOS)

Stress runs of the current code, 100 s each, run concurrently:

| Test | RSS (after warm-up) | fds | `leaks` |
|------|---------------------|-----|---------|
| Steady state, held-open port, no sleep | 2784 → 2832 KB, flat from t=60 s | 8, constant | 0 leaks, 0 bytes |
| Forced re-find/open/verify every cycle | 2768 KB, flat | 8, constant | 0 leaks, 0 bytes |
| Board absent, IOKit scan every cycle | 2784 KB, flat | 7, constant | 0 leaks, 0 bytes |

(The first sample of each run is higher, ~3.5 MB, because start-up pages are later compressed.)

Installed service, current build, 15-minute watch (31 samples, one every 30 s, one process for the whole run, never restarted): RSS 3568 KB at start, 2512 KB after the first two minutes, then 2448–2464 KB for the rest; **8 open fds in every sample**. `leaks` on the live service reports 0 leaks, and afterwards the board still reported `fb=0` with a fresh heartbeat. Other testing (the three stress processes above, doc edits) ran on the same machine during the watch.

An earlier ~9-minute watch of the previous build held at 2672 → 2656 KB with 7 fds; it was cut short when the service was stopped for firmware work, so it is not counted here.

Not covered: a multi-day soak, and the jiggle-send path under stress (not forced, to avoid moving the cursor).

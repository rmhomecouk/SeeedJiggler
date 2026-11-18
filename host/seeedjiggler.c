/*
 * SeeedJiggler host service (macOS). Native, no logging, no disk writes, no child processes.
 *
 * Every 5 s: send a heartbeat ("H") to the XIAO, read the HID idle time straight from IOKit,
 * and if the user has been idle >= IDLE_SECS send a small mouse jiggle every JIGGLE_EVERY s.
 * Our own jiggles reset the HID idle clock, so we track the last *real* input time separately.
 *
 * The board is located by USB vendor/product ID through IOKit (never "the first usbmodem"), and
 * confirmed by its "SEEEDJIGGLER" reply to the "?" status command before anything else is sent.
 * The serial port is held open between cycles and re-found automatically after unplug/replug.
 *
 * Env: IDLE_SECS (default 120), JIGGLE_EVERY (default 45).
 * Flag: -v prints events, raw idle time and the board's own status to stderr (foreground debugging).
 * Build: scripts/build.sh
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* USB IDs of the board. Test hooks: -DSEEED_VID=0x1L simulates an absent board (IOKit scan finds nothing);
 * -DFORCE_REOPEN closes the port after every send so each cycle re-runs find/open/verify. */
#ifndef SEEED_VID
#define SEEED_VID 0x2886L /* Seeed Studio */
#endif
#ifndef SEEED_PID
#define SEEED_PID 0x802FL /* Seeed XIAO M0 running SeeedJiggler (the bootloader has a different PID) */
#endif

/* Poll interval in seconds; overridable at compile time (e.g. -DPOLL_SECS=0 for leak stress tests). */
#ifndef POLL_SECS
#define POLL_SECS 5
#endif

static double mono(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + t.tv_nsec / 1e9;
}

static double env_secs(const char *name, double def) {
    const char *v = getenv(name);
    double d = v ? atof(v) : 0;
    return d > 0 ? d : def;
}

/* Seconds since the last HID input event (keyboard/mouse), or -1 on failure. */
static double idle_secs(io_service_t svc) {
    CFTypeRef p = IORegistryEntryCreateCFProperty(svc, CFSTR("HIDIdleTime"), kCFAllocatorDefault, 0);
    if (!p) return -1;
    uint64_t ns = 0;
    int ok = 0;
    if (CFGetTypeID(p) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue((CFNumberRef)p, kCFNumberSInt64Type, &ns);
    } else if (CFGetTypeID(p) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)p) >= 8) {
        CFDataGetBytes((CFDataRef)p, CFRangeMake(0, 8), (UInt8 *)&ns);
        ok = 1;
    }
    CFRelease(p);
    return ok ? (double)ns / 1e9 : -1;
}

/* ---- Serial port: found by USB IDs, confirmed by ID reply, held open, raw mode ---- */

static int port_fd = -1;

/* Numeric property searched up the IOKit parent chain (the USB device is a parent of the tty node). */
static int parent_num(io_service_t s, const char *key, long *out) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!k) return 0;
    CFTypeRef p = IORegistryEntrySearchCFProperty(s, kIOServicePlane, k, kCFAllocatorDefault,
                                                  kIORegistryIterateRecursively | kIORegistryIterateParents);
    CFRelease(k);
    if (!p) return 0;
    int ok = CFGetTypeID(p) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)p, kCFNumberLongType, out);
    CFRelease(p);
    return ok;
}

/* Fill path with the callout device (/dev/cu.*) of the which-th device (0-based) with our VID/PID. 0 = found. */
static int find_board(char *path, size_t n, int which) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &it) != KERN_SUCCESS)
        return -1;
    int found = -1;
    io_object_t s;
    while (found < 0 && (s = IOIteratorNext(it)) != 0) {
        long vid = -1, pid = -1;
        if (parent_num(s, "idVendor", &vid) && parent_num(s, "idProduct", &pid) && vid == SEEED_VID && pid == SEEED_PID &&
            which-- == 0) {
            CFTypeRef cp = IORegistryEntryCreateCFProperty(s, CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0);
            if (cp && CFGetTypeID(cp) == CFStringGetTypeID() &&
                CFStringGetCString((CFStringRef)cp, path, (CFIndex)n, kCFStringEncodingUTF8))
                found = 0;
            if (cp) CFRelease(cp);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}

static void close_port(void) {
    if (port_fd >= 0) close(port_fd);
    port_fd = -1;
}

/* Read whatever is pending (non-blocking) into buf, NUL-terminated; returns bytes read. */
static int read_pending(char *buf, size_t n, int wait_ms) {
    size_t got = 0;
    struct pollfd p = {.fd = port_fd, .events = POLLIN};
    while (got + 1 < n && poll(&p, 1, wait_ms) > 0) {
        ssize_t r = read(port_fd, buf + got, n - 1 - got);
        if (r <= 0) break;
        got += (size_t)r;
        wait_ms = 20; /* after the first bytes, only wait briefly for the rest of the line */
    }
    buf[got] = 0;
    return (int)got;
}

static int write_all(const char *s) {
    size_t len = strlen(s);
    return write(port_fd, s, len) == (ssize_t)len ? 0 : -1;
}

/* Return an open, verified port fd, or -1 if the board is absent. Cheap when already open. */
static int ensure_port(void) {
    if (port_fd >= 0) return port_fd;
    char path[256];
    /* Try every device with our VID/PID (a second XIAO may exist); the first that answers as SeeedJiggler wins. */
    for (int which = 0; find_board(path, sizeof path, which) == 0; which++) {
        int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
        if (fd < 0) continue;
        struct termios t;
        if (tcgetattr(fd, &t) != 0) { close(fd); continue; }
        cfmakeraw(&t);                /* no echo, no line editing, no CR/LF mangling */
        t.c_cflag |= CLOCAL | CREAD;
        t.c_cc[VMIN] = 0;
        t.c_cc[VTIME] = 0;
        cfsetspeed(&t, B115200);      /* never 1200: that is the bootloader-reset baud rate */
        if (tcsetattr(fd, TCSANOW, &t) != 0) { close(fd); continue; }
        tcflush(fd, TCIOFLUSH);
        port_fd = fd;
        /* Confirm it really is our firmware before sending anything else. Stale replies (e.g. "OK")
         * may precede ours, so look for the ID anywhere in the reply. */
        char buf[256];
        if (write_all("?\n") == 0 && read_pending(buf, sizeof buf, 500) > 0 && strstr(buf, "SEEEDJIGGLER") != NULL)
            return port_fd;
        close_port();
    }
    return -1;
}

/* Send lines with gap_us between them; discard replies; drop the port on any error. */
static int send_lines(const char *const *lines, int n, useconds_t gap_us) {
    if (ensure_port() < 0) return -1;
    char sink[256];
    for (int i = 0; i < n; i++) {
        if (write_all(lines[i]) != 0) { close_port(); return -1; }
        if (i + 1 < n) usleep(gap_us);
    }
    read_pending(sink, sizeof sink, 0); /* keep the receive buffer empty */
#ifdef FORCE_REOPEN
    close_port();
#endif
    return 0;
}

/* -v only: ask the board for its own status line. Does not feed its watchdog. */
static void print_board_status(void) {
    char buf[160];
    if (ensure_port() < 0) { fprintf(stderr, "board: not found\n"); return; }
    if (write_all("?\n") != 0) { close_port(); fprintf(stderr, "board: write failed\n"); return; }
    if (read_pending(buf, sizeof buf, 300) > 0) {
        char *id = strstr(buf, "SEEEDJIGGLER"); /* skip any stale "OK" lines before the status line */
        if (!id) id = buf;
        id[strcspn(id, "\r\n")] = 0;
        fprintf(stderr, "board: %s\n", id);
    } else {
        fprintf(stderr, "board: no reply\n");
    }
}

int main(int argc, char **argv) {
    const int verbose = argc > 1 && strcmp(argv[1], "-v") == 0;
    const double IDLE = env_secs("IDLE_SECS", 120), EVERY = env_secs("JIGGLE_EVERY", 45);
    static const char *const HB[] = {"H\n"};
    static const char *const JIGGLE[] = {"M 8 0\n", "M -8 0\n"};

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"));
    if (!svc) return 1;

    double last_real = mono(), last_jiggle = -1;
    for (;;) {
        send_lines(HB, 1, 0); /* heartbeat: keeps the board's own fallback jiggle off */
        double now = mono(), idle = idle_secs(svc);
        if (idle >= 0) {
            /* idle smaller than the time since our jiggle => genuine input arrived after it */
            if (last_jiggle >= 0 && idle < (now - last_jiggle) - 2) {
                if (verbose) fprintf(stderr, "real input detected (idle %.1fs < %.1fs since jiggle): jiggling stops\n",
                                     idle, now - last_jiggle);
                last_jiggle = -1;
            }
            if (last_jiggle < 0) last_real = now - idle;
            if (verbose) fprintf(stderr, "idle=%.1fs effective_idle=%.1fs\n", idle, now - last_real);
            if (now - last_real >= IDLE && (last_jiggle < 0 || now - last_jiggle >= EVERY)) {
                if (send_lines(JIGGLE, 2, 50000) == 0) {
                    last_jiggle = mono();
                    if (verbose) fprintf(stderr, "jiggled (effective idle %.0fs)\n", now - last_real);
                } else if (verbose) {
                    fprintf(stderr, "jiggle NOT sent (board unavailable)\n");
                }
            }
        }
        if (verbose) print_board_status();
        sleep(POLL_SECS);
    }
}

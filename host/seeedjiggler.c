/*
 * SeeedJiggler host service (macOS). Native, no logging, no disk writes, no child processes.
 *
 * Every 5 s: send a heartbeat ("H") to the XIAO, read the HID idle time straight from IOKit,
 * and if the user has been idle >= IDLE_SECS send a small mouse jiggle every JIGGLE_EVERY s.
 * Our own jiggles reset the HID idle clock, so we track the last *real* input time separately.
 *
 * Env: IDLE_SECS (default 120), JIGGLE_EVERY (default 45).   Flag: -v prints events to stderr.
 * Build: scripts/build.sh
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <fcntl.h>
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

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

/* Open the board's serial port fresh each time, so unplug/replug just works. */
static int send_lines(const char *const *lines, int n) {
    glob_t g;
    if (glob("/dev/cu.usbmodem*", 0, NULL, &g) != 0) return -1;
    int fd = open(g.gl_pathv[0], O_RDWR | O_NOCTTY | O_NONBLOCK);
    globfree(&g);
    if (fd < 0) return -1;
    struct termios t;
    if (tcgetattr(fd, &t) == 0) {
        cfsetspeed(&t, B115200);
        tcsetattr(fd, TCSANOW, &t);
    }
    int rc = 0;
    for (int i = 0; i < n; i++) {
        size_t len = strlen(lines[i]);
        if (write(fd, lines[i], len) != (ssize_t)len) { rc = -1; break; }
        usleep(50000);
    }
    usleep(200000); /* let the board consume the bytes before we close */
    close(fd);
    return rc;
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
        send_lines(HB, 1); /* heartbeat: keeps the board's own fallback jiggle off */
        double now = mono(), idle = idle_secs(svc);
        if (idle >= 0) {
            /* idle smaller than the time since our jiggle => genuine input arrived after it */
            if (last_jiggle < 0 || idle < (now - last_jiggle) - 2) {
                last_real = now - idle;
                last_jiggle = -1;
            }
            if (now - last_real >= IDLE && (last_jiggle < 0 || now - last_jiggle >= EVERY)) {
                if (send_lines(JIGGLE, 2) == 0) {
                    last_jiggle = mono();
                    if (verbose) fprintf(stderr, "jiggled (idle %.0fs)\n", now - last_real);
                }
            }
        }
        sleep(5);
    }
}

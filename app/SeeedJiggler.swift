// SeeedJiggler: menu bar app that is the whole product. It talks to the XIAO board directly, jiggles the mouse
// when the Mac has been idle, and offers keep-awake and start-at-login.
//
// - Engine: every 5 s send a heartbeat to the board (drives the board's app-present LED), read the HID idle
//   time from IOKit, and if the user has been idle for the threshold send a small jiggle every 45 s. The app's own
//   jiggles reset the HID idle clock, so the time of the last *real* input is tracked separately.
// - The board is found by USB vendor/product ID and confirmed by its "SEEEDJIGGLER" reply to "?" before use.
// - No logging, no polling for hot-plug (IOKit notifications), nothing written to disk except the optional
//   start-at-login plist and a few preferences (idle threshold, paused, auto-update-check) when you change them.
//
// Build: scripts/build.sh

import AppKit
import Darwin
import IOKit
import IOKit.pwr_mgt
import IOKit.serial
import CryptoKit

let boardVID = 0x2886, boardPID = 0x802F
let agentLabel = "com.seeedjiggler"
let repoSlug = "rmhomecouk/SeeedJiggler"
let repoURL = URL(string: "https://github.com/\(repoSlug)")!
let releaseAsset = "SeeedJiggler-macos-arm64"
let idleChoices: [(String, Double)] = [("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900)]
let defaultIdle = 120.0, jiggleEvery = 45.0, pollSecs = 5.0

// MARK: - Board discovery

func parentNum(_ s: io_object_t, _ key: String) -> Int? {
    guard let v = IORegistryEntrySearchCFProperty(
        s, kIOServicePlane, key as CFString, kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) else { return nil }
    return (v as? NSNumber)?.intValue
}

/// Callout device paths (/dev/cu.*) of every serial device with the board's USB IDs. Looks only; opens nothing.
func boardPaths() -> [String] {
#if TESTPORT  // test build only (-DTESTPORT): use a pseudo-terminal that emulates the board
    if let p = ProcessInfo.processInfo.environment["SJ_PORT"] { return [p] }
#endif
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &it) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(it) }
    var out: [String] = []
    var s = IOIteratorNext(it)
    while s != 0 {
        if parentNum(s, "idVendor") == boardVID && parentNum(s, "idProduct") == boardPID,
           let p = IORegistryEntryCreateCFProperty(s, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
               .takeRetainedValue() as? String { out.append(p) }
        IOObjectRelease(s)
        s = IOIteratorNext(it)
    }
    return out
}

// MARK: - Engine

func realPath(_ p: String) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(p, &buf) != nil ? String(cString: buf) : p
}

func mono() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

/// Runs on its own serial queue; reports (boardReady, mode) to the main queue. mode: 0 watching, 1 jiggling, 2 paused.
final class Engine {
    private let q = DispatchQueue(label: "seeedjiggler.engine", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var fd: Int32 = -1
    private let hid = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    private var paused = false
    private var idleThreshold: Double
    private var lastReal = mono(), lastJiggle = -1.0
    var onUpdate: ((Bool, Int) -> Void)?  // (board ready, mode)

    init(idle: Double, paused: Bool) { idleThreshold = idle; self.paused = paused }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: pollSecs, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }
    func setPaused(_ p: Bool) { q.async { self.paused = p; self.tick() } }
    func setIdle(_ s: Double) { q.async { self.idleThreshold = s } }
    func kick() { q.async { self.tick() } }  // e.g. right after a hot-plug

    /// Seconds since the last HID input event, or -1.
    private func idleSecs() -> Double {
        guard hid != 0, let p = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return -1 }
        if let n = p as? NSNumber { return Double(n.uint64Value) / 1e9 }
        if let d = p as? Data, d.count >= 8 { return Double(d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 1e9 }
        return -1
    }

    private func tick() {
        _ = send(["H\n"], gapUs: 0)  // heartbeat
        let now = mono()
        if paused {
            lastJiggle = -1
        } else {
            let idle = idleSecs()
            if idle >= 0 {
                // idle smaller than the time since our jiggle => genuine input arrived after it
                if lastJiggle >= 0 && idle < (now - lastJiggle) - 2 { lastJiggle = -1 }
                if lastJiggle < 0 { lastReal = now - idle }
                if now - lastReal >= idleThreshold && (lastJiggle < 0 || now - lastJiggle >= jiggleEvery) {
                    if send(["M 8 0\n", "M -8 0\n"], gapUs: 50_000) { lastJiggle = mono() }
                }
            }
        }
        let ready = fd >= 0, mode = paused ? 2 : (lastJiggle >= 0 ? 1 : 0)
        DispatchQueue.main.async { self.onUpdate?(ready, mode) }
    }

    // MARK: Serial

    private func closePort() { if fd >= 0 { close(fd) }; fd = -1 }

    private func readPending(waitMs: Int32) -> String {
        var out = [UInt8](), wait = waitMs
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buf = [UInt8](repeating: 0, count: 256)
        while out.count < 255 && poll(&pfd, 1, wait) > 0 {
            let r = read(fd, &buf, buf.count)
            if r <= 0 { break }
            out += buf[0..<r]
            wait = 20  // after the first bytes, only wait briefly for the rest of the line
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func writeAll(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return write(fd, b, b.count) == b.count
    }

    /// Open (if needed) and verify a board. Cheap when already open.
    private func ensurePort() -> Bool {
        if fd >= 0 { return true }
        for path in boardPaths() {  // a second XIAO may exist; the first that answers as SeeedJiggler wins
            let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)  // not inherited across the update re-exec
            if f < 0 { continue }
            var t = termios()
            if tcgetattr(f, &t) != 0 { close(f); continue }
            cfmakeraw(&t)
            t.c_cflag |= tcflag_t(CLOCAL | CREAD)
            cfsetspeed(&t, speed_t(B115200))  // never 1200: that is the bootloader-reset baud rate
            if tcsetattr(f, TCSANOW, &t) != 0 { close(f); continue }
            tcflush(f, TCIOFLUSH)
            fd = f
            if writeAll("?\n"), readPending(waitMs: 500).contains("SEEEDJIGGLER") { return true }
            closePort()
        }
        return false
    }

    private func send(_ lines: [String], gapUs: UInt32) -> Bool {
        guard ensurePort() else { return false }
        for (i, l) in lines.enumerated() {
            if !writeAll(l) { closePort(); return false }
            if i + 1 < lines.count { usleep(gapUs) }
        }
        _ = readPending(waitMs: 0)  // keep the receive buffer empty
        return true
    }
}

// MARK: - Keep awake

enum Awake: Equatable { case off, hours(Int), forever }

final class KeepAwake {
    private var ids: [IOPMAssertionID] = []
    private var timer: Timer?
    private(set) var mode: Awake = .off
    private(set) var until: Date?
    var onChange: (() -> Void)?

    func set(_ m: Awake) {
        release()
        mode = m
        guard m != .off else { onChange?(); return }
        for type in [kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertPreventUserIdleSystemSleep] {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "SeeedJiggler keep awake" as CFString, &id)
            if r == kIOReturnSuccess { ids.append(id) }
        }
        if ids.isEmpty { mode = .off }  // could not hold an assertion: do not claim to be awake
        if case .hours(let h) = mode {
            until = Date().addingTimeInterval(Double(h) * 3600)
            let t = Timer(timeInterval: Double(h) * 3600, repeats: false) { [weak self] _ in self?.set(.off) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        onChange?()
    }

    private func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids = []
        timer?.invalidate(); timer = nil
        until = nil
    }
}

// MARK: - Updates

/// Update checker for the rolling "latest" GitHub release (built by .github/workflows/release.yml).
/// Checks only compare commit hashes; nothing is installed without the user confirming, and the download must
/// match the SHA-256 published next to it.
struct Release { let sha: String; let binary: URL; let checksum: URL }

enum UpdateState: Equatable { case unknown, upToDate, available(String), failed(String) }

final class Updater {
    /// Ephemeral: no HTTP cache, cookies or credential storage on disk (the shared session writes Cache.db).
    static let session = URLSession(configuration: .ephemeral)
    var state = UpdateState.unknown
    var release: Release?
    private var apiBase: String {
#if TESTPORT
        return ProcessInfo.processInfo.environment["SJ_API"] ?? "https://api.github.com"
#else
        return "https://api.github.com"
#endif
    }

    static func version() -> String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" }
    /// The commit hash part of the version ("abc1234-dirty" -> "abc1234"), or nil for unknown builds.
    static func baseSha(_ v: String) -> String? {
        let b = v.replacingOccurrences(of: "-dirty", with: "")
        return b.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil ? b : nil
    }

    private func get(_ path: String, _ done: @escaping (Data?, Int) -> Void) {
        guard let url = URL(string: apiBase + path) else { return done(nil, -1) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SeeedJiggler", forHTTPHeaderField: "User-Agent")  // GitHub requires a User-Agent; nothing identifying
        Updater.session.dataTask(with: req) { d, r, _ in
            let code = (r as? HTTPURLResponse)?.statusCode ?? -1
            DispatchQueue.main.async { done(d, code) }
        }.resume()
    }

    func check(_ done: @escaping (UpdateState) -> Void) {
        get("/repos/\(repoSlug)/releases/tags/latest") { [self] data, code in
            func finish(_ s: UpdateState) { state = s; done(s) }
            if code == 404 { return finish(.failed("No release has been published yet")) }
            guard code == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return finish(.failed("Could not reach GitHub"))
            }
            let body = obj["body"] as? String ?? ""
            let assets = obj["assets"] as? [[String: Any]] ?? []
            func url(_ name: String) -> URL? {
                assets.first { $0["name"] as? String == name }.flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
            }
            guard let r = body.range(of: "commit: [0-9a-f]{40}", options: .regularExpression),
                  let bin = url(releaseAsset), let sum = url(releaseAsset + ".sha256") else {
                return finish(.failed("The latest release is incomplete"))
            }
            let latest = String(body[r].dropFirst("commit: ".count))
            release = Release(sha: latest, binary: bin, checksum: sum)
            guard let cur = Updater.baseSha(Updater.version()) else { return finish(.available(String(latest.prefix(7)))) }
            if latest.hasPrefix(cur) || cur.hasPrefix(latest) { return finish(.upToDate) }
            // Different commit: only offer it if it is actually ahead of this build.
            get("/repos/\(repoSlug)/compare/\(cur)...\(latest)") { d, c in
                let status = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["status"] as? String
                if c == 200, status == "behind" || status == "identical" { return finish(.upToDate) }
                finish(.available(String(latest.prefix(7))))  // ahead, diverged, or this commit is unknown to GitHub
            }
        }
    }

    /// Runs `program --version` (20 s limit: the first run of a new program can be slow while macOS checks it).
    /// Returns its output, or nil plus a reason if it cannot run.
    static func reportedVersion(_ path: String) -> (version: String?, why: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = ["--version"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, "could not start it: \(error.localizedDescription)") }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + 20) == .timedOut { p.terminate(); return (nil, "it did not answer within 20 s") }
        guard p.terminationStatus == 0 else {
            let how = p.terminationReason == .uncaughtSignal ? "killed by signal" : "exit status"
            return (nil, "\(how) \(p.terminationStatus)")
        }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? (nil, "it printed nothing") : (out, "")
    }

    /// Download, verify, replace the running binary, and re-exec. Returns an error message, or never returns on success.
    func install(_ rel: Release, beforeRestart: @escaping () -> Void, failed: @escaping (String) -> Void) {
        func fail(_ m: String) { DispatchQueue.main.async { failed(m) } }
        Updater.session.dataTask(with: rel.checksum) { sumData, _, _ in
            Updater.session.dataTask(with: rel.binary) { bin, resp, _ in
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let bin = bin, bin.count > 100_000,
                      let sumData = sumData,
                      let want = String(decoding: sumData, as: UTF8.self).split(whereSeparator: { " \t\n".contains($0) }).first
                else { return fail("The download failed") }
                let have = SHA256.hash(data: bin).map { String(format: "%02x", $0) }.joined()
                guard have == want.lowercased() else { return fail("The download did not match its checksum, so it was not installed") }
                guard let exe = Bundle.main.executablePath.map(realPath) else { return fail("Cannot locate the running program") }
                let tmp = exe + ".new", old = exe + ".old"
                do {
                    try bin.write(to: URL(fileURLWithPath: tmp))
                    chmod(tmp, 0o755)
                } catch { return fail("Cannot write next to \(exe): \(error.localizedDescription)") }
                // Run the download before trusting it: it must start on this Mac and report the release's commit.
                let vet = Updater.reportedVersion(tmp)
                guard let v = vet.version else {
                    unlink(tmp); return fail("The downloaded program does not run on this Mac (\(vet.why)), so it was not installed")
                }
                guard rel.sha.hasPrefix(v) else {
                    // The "latest" release is replaced on every push, so it can change between the check and the download.
                    unlink(tmp); return fail("A newer release was published while downloading (it is \(v), the check saw \(rel.sha.prefix(7))). Nothing was installed; choose Check for updates again.")
                }
                unlink(old)
                guard rename(exe, old) == 0, rename(tmp, exe) == 0 else {
                    rename(old, exe); unlink(tmp)
                    return fail("Cannot replace \(exe): \(String(cString: strerror(errno)))")
                }
                DispatchQueue.main.async {
                    beforeRestart()  // e.g. release keep-awake assertions: they would outlive the exec
                    var args: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
                    execv(exe, &args)  // same pid; launchd keeps supervising it
                    rename(old, exe)   // exec failed: put the working program back
                    failed("The update was installed but the app could not restart; quit and reopen it")
                }
            }.resume()
        }.resume()
    }
}

// MARK: - Icons

enum Icon { case watching, jiggling, paused, noBoard, noReply, awake }

func makeIcon(_ kind: Icon) -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
        let fg = NSColor.labelColor
        let orange = NSColor.systemOrange
        func sym(_ name: String, _ color: NSColor) {
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) else { return }
            let r = NSRect(x: (rect.width - base.size.width) / 2, y: (rect.height - base.size.height) / 2,
                           width: base.size.width, height: base.size.height)
            let tinted = NSImage(size: base.size, flipped: false) { b in
                base.draw(in: b); color.set(); b.fill(using: .sourceIn); return true
            }
            tinted.draw(in: r)
        }
        func slash(_ color: NSColor) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 3, y: 16)); p.line(to: NSPoint(x: 17, y: 2))
            p.lineWidth = 1.6; p.lineCapStyle = .round; color.setStroke(); p.stroke()
        }
        switch kind {
        case .watching:
            sym("computermouse", fg)
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 2, width: 5.5, height: 5.5)).fill()
        case .jiggling: sym("cursorarrow.motionlines", fg)
        case .paused: sym("computermouse", fg.withAlphaComponent(0.4)); slash(fg.withAlphaComponent(0.55))
        case .noBoard: sym("computermouse", orange); slash(orange)
        case .noReply: sym("computermouse", orange)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 2, width: 5.5, height: 5.5)).fill()
        case .awake: sym("cup.and.saucer.fill", fg)
        }
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let awake = KeepAwake()
    let engine: Engine
    let updater = Updater()
    var autoCheck = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
    var notePort: IONotificationPortRef?
    var idleChoice: Double

    var present = false      // a device with the board's USB IDs exists
    var ready = false        // ...and it answered as SeeedJiggler
    var mode = 0             // 0 watching, 1 jiggling, 2 paused

    override init() {
        let stored = UserDefaults.standard.double(forKey: "idleSecs")
        idleChoice = stored > 0 ? stored : defaultIdle
#if TESTPORT
        if let t = ProcessInfo.processInfo.environment["SJ_IDLE"], let v = Double(t), v > 0 { idleChoice = v }
#endif
        let wasPaused = UserDefaults.standard.bool(forKey: "paused")  // pause survives quit, login and updates
        engine = Engine(idle: idleChoice, paused: wasPaused)
        super.init()
        mode = wasPaused ? 2 : 0
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // One copy only: two would both drive the board. A second launch says so and exits (before it creates a menu
        // bar icon or touches the board).
#if !TESTPORT  // test builds run beside the real app
        if otherInstanceRunning() {
            _ = alert("SeeedJiggler is already running", "Look for its icon in the menu bar. Only one copy can run at a time.")
            exit(0)
        }
#endif
        if let exe = Bundle.main.executablePath { unlink(realPath(exe) + ".old") }  // left by a successful update
#if TESTPORT
        if ProcessInfo.processInfo.environment["SJ_TOGGLE_LOGIN"] == "1" { toggleLogin(); exit(0) }
        if let n = ProcessInfo.processInfo.environment["SJ_PAUSE_AFTER"], let secs = Double(n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in self?.toggleJiggle() }
        }
        if ProcessInfo.processInfo.environment["SJ_ABOUT"] == "1" { DispatchQueue.main.async { self.showAbout() } }
        if let n = ProcessInfo.processInfo.environment["SJ_QUIT_AFTER"], let secs = Double(n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
        }
#endif
        item.menu = NSMenu()
        item.menu?.delegate = self
        awake.onChange = { [weak self] in self?.refresh() }
        engine.onUpdate = { [weak self] r, m in  // only on change: the 5 s tick must not redraw anything
            guard let self = self, r != self.ready || m != self.mode else { return }
            self.ready = r; self.mode = m; self.refresh()
        }
        startHotplugWatch()
        engine.start()
        refresh()
        // Daily background check (one small request to GitHub, nothing installed without asking).
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.autoCheckNow() }
        RunLoop.main.add(t, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.autoCheckNow() }
#if TESTPORT
        if ProcessInfo.processInfo.environment["SJ_PRINT_MODE"] == "1" { print("mode", mode, "paused-pref", UserDefaults.standard.bool(forKey: "paused")); fflush(stdout); exit(0) }
        if ProcessInfo.processInfo.environment["SJ_PRINT_VERSION"] == "1" { print(Updater.version()); fflush(stdout); exit(0) }
        if ProcessInfo.processInfo.environment["SJ_AUTO_INSTALL"] == "1" {
            updater.check { [weak self] st in
                print("check:", st); fflush(stdout)
                guard let self = self, let r = self.updater.release, case .available = st else { exit(2) }
                self.updater.install(r, beforeRestart: {}, failed: { print("install failed:", $0); exit(3) })
            }
        }
#endif
    }

    func autoCheckNow() {
        guard autoCheck else { return }
        updater.check { [weak self] _ in self?.refresh() }
    }

    // Hot-plug: IOKit tells us when a serial device appears or disappears.
    func startHotplugWatch() {
        notePort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notePort else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let cb: IOServiceMatchingCallback = { refcon, iter in
            var o = IOIteratorNext(iter)
            while o != 0 { IOObjectRelease(o); o = IOIteratorNext(iter) }  // drain (re-arms the notification)
            guard let refcon = refcon else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                me.refresh(); me.engine.kick()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { me.refresh(); me.engine.kick() }  // registry settles
            }
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, IOServiceMatching(kIOSerialBSDServiceValue), cb, me, &it) == KERN_SUCCESS {
                cb(me, it)  // arm
            }
        }
    }

    /// True if another SeeedJiggler of this user is already running.
    func otherInstanceRunning() -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return false }
        var name = [CChar](repeating: 0, count: 64)
        for p in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where p > 0 && p != getpid() {
            if proc_name(p, &name, UInt32(name.count)) > 0 && String(cString: name) == "SeeedJiggler" {
                var info = proc_bsdshortinfo()
                if proc_pidinfo(p, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0,
                   info.pbsi_uid == getuid() { return true }
            }
        }
        return false
    }

    func refresh() {
        present = !boardPaths().isEmpty
        if !present { ready = false }
        item.button?.image = makeIcon(currentIcon())
        item.button?.toolTip = statusLine()
    }

    func currentIcon() -> Icon {
        if !present { return .noBoard }
        if !ready { return .noReply }
        if mode == 2 { return .paused }
        if awake.mode != .off { return .awake }
        return mode == 1 ? .jiggling : .watching
    }

    func statusLine() -> String {
        if !present { return "Board not found" }
        if !ready { return "Board not responding" }
        switch mode {
        case 2: return "Paused"
        case 1: return "Jiggling (Mac idle)"
        default: return "Watching (Mac in use)"
        }
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        menu.autoenablesItems = false
        func add(_ t: String, _ sel: Selector? = nil, on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off; i.isEnabled = sel != nil
            menu.addItem(i); return i
        }
        let head = NSMenuItem(title: "SeeedJiggler", action: #selector(showAbout), keyEquivalent: "")
        head.target = self
        head.attributedTitle = NSAttributedString(string: "SeeedJiggler", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(head)
        let ok = present && ready
        let dot = NSMenuItem(title: ok ? "● Board connected" : (present ? "● Board not responding" : "● Board not found"), action: nil, keyEquivalent: "")
        dot.attributedTitle = NSAttributedString(string: dot.title, attributes: [
            .foregroundColor: ok ? NSColor.systemGreen : NSColor.systemOrange])
        menu.addItem(dot)
        _ = add(statusLine())
        if case .available(let v) = updater.state {
            let u = NSMenuItem(title: "⬆ Update available (\(v))…", action: #selector(checkUpdatesNow), keyEquivalent: "")  // re-checks first: the release may have changed since the last check
            u.target = self
            menu.addItem(u)
        }
        menu.addItem(.separator())

        _ = add("Jiggle when idle", #selector(toggleJiggle), on: mode != 2)

        let awakeItem = NSMenuItem(title: "Keep Mac awake", action: nil, keyEquivalent: "")
        awakeItem.state = awake.mode == .off ? .off : .on
        let sub = NSMenu(); sub.autoenablesItems = false
        for (title, m) in [("Off", Awake.off), ("1 hour", .hours(1)), ("4 hours", .hours(4)), ("Until I turn it off", .forever)] {
            let mi = NSMenuItem(title: title, action: #selector(setAwake(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = AwakeBox(m); mi.state = awake.mode == m ? .on : .off
            sub.addItem(mi)
        }
        awakeItem.submenu = sub
        menu.addItem(awakeItem)
        if awake.mode != .off {
            var t = "Display stays awake"
            if let u = awake.until {
                let f = DateFormatter(); f.timeStyle = .short
                t += " · until \(f.string(from: u))"
            }
            let d = NSMenuItem(title: t, action: nil, keyEquivalent: ""); d.isEnabled = false
            d.attributedTitle = NSAttributedString(string: t, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11)])
            menu.addItem(d)
        }
        let idleItem = NSMenuItem(title: "Idle threshold", action: nil, keyEquivalent: "")
        let idleSub = NSMenu(); idleSub.autoenablesItems = false
        for (title, secs) in idleChoices {
            let mi = NSMenuItem(title: title, action: #selector(setIdle(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = Int(secs); mi.state = idleChoice == secs ? .on : .off
            idleSub.addItem(mi)
        }
        idleItem.submenu = idleSub
        menu.addItem(idleItem)
        menu.addItem(.separator())
        _ = add("Check for updates…", #selector(checkUpdatesNow))
        _ = add("Check for updates automatically", #selector(toggleAutoCheck), on: autoCheck)
        _ = add("Start at login", #selector(toggleLogin), on: loginEnabled())
        menu.addItem(.separator())
        let q = add("Quit", #selector(quit)); q.keyEquivalent = "q"
    }

    final class AwakeBox: NSObject { let m: Awake; init(_ m: Awake) { self.m = m } }

    @objc func setAwake(_ s: NSMenuItem) { if let b = s.representedObject as? AwakeBox { awake.set(b.m) } }

    @objc func setIdle(_ s: NSMenuItem) {
        idleChoice = Double(s.tag)
        UserDefaults.standard.set(idleChoice, forKey: "idleSecs")
        engine.setIdle(idleChoice)
    }

    @objc func toggleJiggle() {
        mode = mode == 2 ? 0 : 2
        UserDefaults.standard.set(mode == 2, forKey: "paused")
        engine.setPaused(mode == 2); refresh()
    }

    @objc func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown (not built with scripts/build.sh)"
        let built = info?["CFBundleVersion"] as? String ?? "unknown"
        let alert = NSAlert()
        alert.messageText = "SeeedJiggler"
        alert.icon = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))  // otherwise a generic folder icon
        alert.informativeText = "Version \(version)\nBuilt \(built)\n\n\(repoURL.absoluteString)"
        alert.addButton(withTitle: "Open on GitHub")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)  // an accessory app is not frontmost by default
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(repoURL) }
    }

    @objc func toggleAutoCheck() {
        autoCheck.toggle()
        UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck")
    }

    func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.icon = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        buttons.forEach { a.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc func checkUpdatesNow() {
        updater.check { [weak self] st in
            guard let self = self else { return }
            self.refresh()
            switch st {
            case .available: self.confirmInstall()
            case .upToDate: _ = self.alert("SeeedJiggler is up to date", "Version \(Updater.version())")
            case .failed(let m): _ = self.alert("Could not check for updates", m)
            case .unknown: break
            }
        }
    }

    /// Asks before installing. Uses the release from the check that has just run, never a stale one.
    func confirmInstall() {
        guard let rel = updater.release else { return }
        let dirty = Updater.version().contains("dirty") ? "\n\nThis build has local changes; they will be replaced." : ""
        let go = alert("Install the update?",
                       "You have \(Updater.version()). Latest on GitHub is \(rel.sha.prefix(7)).\n\nThe app downloads it, checks its SHA-256, replaces itself and restarts. Jiggling pauses for a moment.\(dirty)",
                       buttons: ["Install and Restart", "Cancel"])
        guard go else { return }
        updater.install(rel, beforeRestart: { [weak self] in self?.awake.set(.off) },
                        failed: { [weak self] m in _ = self?.alert("Update failed", m) })
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Start at login

    var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
    func loginEnabled() -> Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Binary the login item should run. From ~/Documents, ~/Desktop or ~/Downloads, launchd agents have been seen to hang
    /// at launch (macOS file-access protection), so a copy in ~/.local/bin is used instead.
    func loginBinary() -> String? {
        guard let rawExe = Bundle.main.executablePath else { return nil }
        let home = realPath(NSHomeDirectory()), exe = realPath(rawExe)  // compare like with like (/tmp vs /private/tmp)
        guard ["Documents", "Desktop", "Downloads"].contains(where: { exe.hasPrefix("\(home)/\($0)/") }) else { return exe }
        let dir = "\(NSHomeDirectory())/.local/bin", dest = "\(dir)/SeeedJiggler"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dest)
        do { try FileManager.default.copyItem(atPath: exe, toPath: dest) } catch { return nil }
        return dest
    }

    @objc func toggleLogin() {
        if loginEnabled() {
            try? FileManager.default.removeItem(at: plistURL)  // takes effect at next login; the running app is not stopped
            return
        }
        guard let exe = loginBinary() else { return }
        let plist: [String: Any] = [
            "Label": agentLabel, "ProgramArguments": [exe], "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],  // restart after a crash; Quit (exit 0) stays quit
            "ProcessType": "Interactive", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
        ]
        if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: plistURL)
        }
    }
}

if CommandLine.arguments.contains("--version") { print(Updater.version()); exit(0) }  // used to vet a downloaded update
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

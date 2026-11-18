// SeeedJiggler: menu bar app that is the whole product. It talks to the XIAO board directly, jiggles the mouse
// when the Mac has been idle, and offers keep-awake and start-at-login.
//
// - Engine: every 5 s send a heartbeat to the board (drives the board's app-present LED), read the HID idle
//   time from IOKit, and if the user has been idle for the threshold send a small jiggle every 45 s. The app's own
//   jiggles reset the HID idle clock, so the time of the last *real* input is tracked separately.
// - The board is found by USB vendor/product ID and confirmed by its "SEEEDJIGGLER" reply to "?" before use.
// - No logging, no polling for hot-plug (IOKit notifications), nothing written to disk except the optional
//   start-at-login plist and one stored preference (idle threshold) when you change it.
//
// Build: scripts/build.sh

import AppKit
import Darwin
import IOKit
import IOKit.pwr_mgt
import IOKit.serial

let boardVID = 0x2886, boardPID = 0x802F
let agentLabel = "com.seeedjiggler.menu"
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
    var onUpdate: ((Bool, Int) -> Void)?

    init(idle: Double) { idleThreshold = idle }

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
            let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
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
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let awake = KeepAwake()
    let engine: Engine
    var notePort: IONotificationPortRef?
    var activity: NSObjectProtocol?
    var idleChoice: Double

    var present = false      // a device with the board's USB IDs exists
    var ready = false        // ...and it answered as SeeedJiggler
    var mode = 0             // 0 watching, 1 jiggling, 2 paused

    override init() {
        let stored = UserDefaults.standard.double(forKey: "idleSecs")
        idleChoice = stored > 0 ? stored : defaultIdle
        engine = Engine(idle: idleChoice)
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
#if !TESTPORT
        if otherInstanceRunning() { exit(0) }  // two copies would both drive the board
#endif
        // A window-less accessory app is a candidate for App Nap, which can delay timers (heartbeat and jiggle timing).
        // Hold an activity for the whole lifetime (the system may still idle-sleep). Whether it is needed was not measured.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
                                                         reason: "SeeedJiggler heartbeat")
#if TESTPORT
        if ProcessInfo.processInfo.environment["SJ_TOGGLE_LOGIN"] == "1" { toggleLogin(); exit(0) }
        if let n = ProcessInfo.processInfo.environment["SJ_PAUSE_AFTER"], let secs = Double(n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in self?.toggleJiggle() }
        }
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
        let head = NSMenuItem(title: "SeeedJiggler", action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(string: "SeeedJiggler", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(head)
        let ok = present && ready
        let dot = NSMenuItem(title: ok ? "● Board connected" : (present ? "● Board not responding" : "● Board not found"), action: nil, keyEquivalent: "")
        dot.attributedTitle = NSAttributedString(string: dot.title, attributes: [
            .foregroundColor: ok ? NSColor.systemGreen : NSColor.systemOrange])
        menu.addItem(dot)
        _ = add(statusLine())
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

    @objc func toggleJiggle() { mode = mode == 2 ? 0 : 2; engine.setPaused(mode == 2); refresh() }

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// PulsePopover: a borderless, non-activating panel under the menu bar that
// shows the monitor page. SwiftBar's own webview popover paints a
// "SwiftBar: <plugin>" title bar we cannot remove; this one has no chrome.
//
//   pulse-popover [width] [height]
//
// Resident: the first launch shows the panel; SIGUSR1 toggles it; a click
// outside, Escape, or a second click on the menu bar item hides it. While
// hidden the page is unloaded (no animation, little memory), and after
// PULSE_IDLE_EXIT seconds hidden (default 600) the process exits so nothing
// stays around when you are not looking. Reads ~/.cache/pulse-limits/panel.url
// on every show, so it always opens the latest data the plugin wrote.
//
// While shown it also measures what Claude Code is doing right now, from the
// transcripts Claude Code writes under ~/.claude/projects: output tokens in
// the last minute (deduplicated by message id, since a streaming reply is
// written several times) and seconds since any transcript was last touched.
// Every 2 s it hands that to the page as window.pulse.activity({...}).
// `pulse-popover --activity` prints one measurement as JSON and exits; the
// plugin uses that for the initial value.
//
// It also keeps the numbers live: on show and every 60 s while shown it runs
// `pulse-limits.5m.sh --payload` (a fresh fetch, JSON only) and hands the
// result to window.pulse.usage({...}), so the page updates in place.
// Build: ./build.sh

import Cocoa
import WebKit

let cacheDir  = NSString(string: "~/.cache/pulse-limits").expandingTildeInPath
let urlFile   = cacheDir + "/panel.url"
let pidFile   = cacheDir + "/popover.pid"
let stampFile = cacheDir + "/popover.closed"   // "hidden at" epoch, read by open-monitor.sh
let argv = CommandLine.arguments
let width  = Double(argv.count > 1 ? argv[1] : "") ?? 520
let height = Double(argv.count > 2 ? argv[2] : "") ?? 316
let idleExit = TimeInterval(ProcessInfo.processInfo.environment["PULSE_IDLE_EXIT"] ?? "") ?? 600
let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
let pluginScript = Bundle.main.executableURL!.resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("pulse-limits.5m.sh").path

// ---- activity from the Claude Code transcripts ------------------------------------
let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

func measureActivity() -> [String: Int] {
    let now = Date()
    let fm = FileManager.default
    var newest: Date? = nil
    var recent: [URL] = []
    var sessions = 0
    if let e = fm.enumerator(at: URL(fileURLWithPath: projectsDir), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, let mod = v.contentModificationDate else { continue }
            if newest == nil || mod > newest! { newest = mod }
            let age = now.timeIntervalSince(mod)
            if age <= 300 { sessions += 1 }
            if age <= 120 { recent.append(url) }
        }
    }
    var perMessage: [String: Int] = [:]
    for url in recent {
        guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > 131_072 ? size - 131_072 : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }           // partial first line
        // Only lines stamped within the last minute can count: match the two UTC
        // minute prefixes as plain text before paying for a JSON parse of a big line.
        let m0 = String(isoPlain.string(from: now).prefix(16)), m1 = String(isoPlain.string(from: now.addingTimeInterval(-60)).prefix(16))
        for line in lines where (line.contains(m0) || line.contains(m1))
            && line.contains("\"type\":\"assistant\"") && line.contains("output_tokens") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let when = isoFrac.date(from: ts) ?? isoPlain.date(from: ts),
                  now.timeIntervalSince(when) <= 60,
                  let msg = obj["message"] as? [String: Any],
                  let id = msg["id"] as? String,
                  let usage = msg["usage"] as? [String: Any],
                  let out = usage["output_tokens"] as? Int else { continue }
            perMessage[id] = max(perMessage[id] ?? 0, out)
        }
    }
    let idle = newest.map { Int(now.timeIntervalSince($0)) } ?? 86_400 * 365
    return ["tok_per_min": perMessage.values.reduce(0, +), "idle_s": idle, "sessions": sessions]
}

if argv.count > 1, argv[1] == "--activity" {
    let data = try! JSONSerialization.data(withJSONObject: measureActivity())
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }     // so Escape reaches us without activating the app
}

final class App: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var panel: Panel!
    var web: WKWebView!
    var monitors: [Any] = []
    var signalSource: DispatchSourceSignal?
    var visible = false
    var hiddenAt = Date()
    var activityTimer: Timer?
    var usageTimer: Timer?
    var fetching = false

    func applicationDidFinishLaunching(_: Notification) {
        try? String(getpid()).write(toFile: pidFile, atomically: true, encoding: .utf8)

        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")   // no white flash before the page paints
        web.wantsLayer = true
        web.layer?.cornerRadius = 16
        web.layer?.masksToBounds = true
        web.autoresizingMask = [.width, .height]
        panel.contentView = web

        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { self.toggle() }
        source.resume()
        signalSource = source
        signal(SIGTERM) { _ in unlink(pidFile); exit(0) }

        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            if !self.visible, Date().timeIntervalSince(self.hiddenAt) > idleExit { self.quit() }
        }
        show()
    }

    func toggle() { visible ? hide() : show() }

    func show() {
        guard !visible,
              let text = try? String(contentsOfFile: urlFile, encoding: .utf8),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        // Under the mouse, which is on the menu bar item that asked for us.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let area = screen.visibleFrame
        let x = max(area.minX + 8, min(mouse.x - width / 2, area.maxX - width - 8))
        panel.setFrame(NSRect(x: x, y: area.maxY - 6 - height, width: width, height: height), display: false)
        panel.alphaValue = 0
        web.load(URLRequest(url: url))                  // fades in from didFinish
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        guard !visible, web.url?.isFileURL == true else { return }   // the about:blank unload also lands here
        visible = true
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; self.panel.animator().alphaValue = 1 }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in self.hide() }!,
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { self.hide(); return nil }
                return event
            }!,
        ]
        pushActivity()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.pushActivity() }
        refreshUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.refreshUsage() }
        print("shown"); fflush(stdout)
    }

    func refreshUsage() {
        guard visible, !fetching, FileManager.default.isExecutableFile(atPath: pluginScript) else { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async { self.fetching = false } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pluginScript)
            p.arguments = ["--payload"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let json = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  json.hasPrefix("{") else { return }
            DispatchQueue.main.async {
                guard self.visible else { return }
                self.web.evaluateJavaScript("window.pulse && window.pulse.usage(\(json))", completionHandler: nil)
                print("usage refreshed"); fflush(stdout)
            }
        }
    }

    func pushActivity() {
        guard visible, let data = try? JSONSerialization.data(withJSONObject: measureActivity()),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.pulse && window.pulse.activity(\(json))", completionHandler: nil)
    }

    func hide() {
        guard visible else { return }
        visible = false
        hiddenAt = Date()
        activityTimer?.invalidate(); activityTimer = nil
        usageTimer?.invalidate(); usageTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        // The launcher reads this: a click on the menu bar item both hides us (the
        // global monitor fires first) and re-runs the launcher, which must not toggle us back.
        try? String(Date().timeIntervalSince1970).write(toFile: stampFile, atomically: true, encoding: .utf8)
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; self.panel.animator().alphaValue = 0 },
                                            completionHandler: {
            self.panel.orderOut(nil)
            self.web.load(URLRequest(url: URL(string: "about:blank")!))   // stop the animation, drop the page
            print("hidden"); fflush(stdout)
        })
    }

    func quit() {
        unlink(pidFile)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // no Dock icon, no menu bar of its own
let delegate = App()
app.delegate = delegate
app.run()

import Cocoa
import WebKit
import EventKit

let RES = Bundle.main.resourceURL!
let SUPPORT = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Wormod", isDirectory: true)
let STATE_FILE = SUPPORT.appendingPathComponent("state.json")

func jsString(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)
    return String(data: data, encoding: .utf8)!
}
func jsJSON(_ obj: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8)!
}
func num(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }

// MARK: - Screen geometry

/// Percent frames from the editor map onto the main screen's visible area (below the menu bar, above the Dock).
struct ScreenMap {
    let visible: NSRect
    let primaryHeight: CGFloat

    init() {
        visible = NSScreen.main!.visibleFrame
        primaryHeight = NSScreen.screens[0].frame.height
    }
    /// Top-left-origin rect, as used by Accessibility and AppleScript bounds.
    func topLeft(_ f: [String: Any]) -> CGRect {
        let x = num(f["x"]), y = num(f["y"]), w = num(f["w"]), h = num(f["h"])
        return CGRect(x: (visible.minX + visible.width * x / 100).rounded(),
                      y: (primaryHeight - visible.maxY + visible.height * y / 100).rounded(),
                      width: (visible.width * w / 100).rounded(),
                      height: (visible.height * h / 100).rounded())
    }
    /// Bottom-left-origin rect, as used by NSWindow.
    func cocoa(_ f: [String: Any]) -> NSRect {
        let x = num(f["x"]), y = num(f["y"]), w = num(f["w"]), h = num(f["h"])
        return NSRect(x: visible.minX + visible.width * x / 100,
                      y: visible.maxY - visible.height * (y + h) / 100,
                      width: max(150, visible.width * w / 100),
                      height: max(110, visible.height * h / 100))
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func windows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let all = value as? [AXUIElement] else { return [] }
        let standard = all.filter { w in
            var sub: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            return (sub as? String) == (kAXStandardWindowSubrole as String)
        }
        return standard.isEmpty ? all : standard
    }

    static func place(_ w: AXUIElement, _ r: CGRect) {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        var origin = r.origin, size = r.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // size → position → size: some apps clamp the size until the window has moved
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }
}

// MARK: - Applier

final class Applier {
    let store = EKEventStore()
    var panels: [WidgetPanel] = []
    private var eventsGranted: Bool?
    private var remindersGranted: Bool?

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.panels.forEach { $0.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.panels.forEach { $0.refresh() }
        }
    }

    func apply(_ recipe: [String: Any], done: @escaping (_ ok: Bool, _ message: String) -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            done(false, "Turn on Wormod in System Settings → Privacy & Security → Accessibility, then press Apply again.")
            return
        }
        let name = recipe["name"] as? String ?? "Workspace"
        let modules = recipe["modules"] as? [[String: Any]] ?? []
        let floats = recipe["floats"] as? [[String: Any]] ?? []
        let screen = ScreenMap()

        panels.forEach { $0.dismiss() }
        panels = []

        DispatchQueue.global(qos: .userInitiated).async {
            var usedBundles = Set<String>()
            var placed: [String: [AXUIElement]] = [:]
            var safariWindows: [Int] = []
            var failures: [String] = []
            var frontPid: pid_t?

            let appItems = modules + floats.filter { !($0["path"] as? String ?? "").isEmpty }
            for item in appItems {
                let id = item["id"] as? String ?? ""
                let label = item["name"] as? String ?? id
                let rect = screen.topLeft(item["frame"] as? [String: Any] ?? [:])
                let path = item["path"] as? String ?? ""
                let url = item["url"] as? String ?? ""
                var target = (item["target"] as? String ?? "").trimmingCharacters(in: .whitespaces)

                if !url.isEmpty || id == "safari" {
                    let open = target.isEmpty ? url : self.normalizedURL(target)
                    let host = URL(string: url)?.host ?? ""
                    if let wid = self.placeSafari(url: open, reuseHost: target.isEmpty ? host : "", rect: rect, exclude: safariWindows) {
                        safariWindows.append(wid)
                        usedBundles.insert("com.apple.Safari")
                    } else {
                        failures.append(label)
                    }
                    continue
                }

                guard FileManager.default.fileExists(atPath: path) else { failures.append("\(label) (not installed)"); continue }
                if id == "finder" && target.isEmpty { target = NSHomeDirectory() }
                guard let app = self.launch(path: path, target: target) else { failures.append(label); continue }
                app.unhide()
                if let bid = app.bundleIdentifier { usedBundles.insert(bid) }
                let taken = placed[path] ?? []
                guard let win = self.waitForWindow(app: app, path: path, exclude: taken) else { failures.append("\(label) (no window)"); continue }
                AX.place(win, rect)
                placed[path, default: []].append(win)
                frontPid = app.processIdentifier
            }

            if !safariWindows.isEmpty { self.minimizeOtherSafariWindows(keep: safariWindows) }

            DispatchQueue.main.async {
                for f in floats where (f["path"] as? String ?? "").isEmpty {
                    let panel = WidgetPanel(type: f["id"] as? String ?? "clock",
                                            frame: screen.cocoa(f["frame"] as? [String: Any] ?? [:]),
                                            opacity: num(f["opacity"]) == 0 ? 1 : num(f["opacity"]),
                                            onTop: (f["top"] as? Bool) ?? true,
                                            owner: self)
                    self.panels.append(panel)
                    panel.orderFrontRegardless()
                }
                self.hideOtherApps(keep: usedBundles)
                if let pid = frontPid, let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate(options: [])
                } else if usedBundles.contains("com.apple.Safari") {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.activate(options: [])
                }
                if failures.isEmpty {
                    done(true, "Applied “\(name)”")
                } else {
                    done(false, "Applied “\(name)”, but couldn’t place: " + failures.joined(separator: ", "))
                }
            }
        }
    }

    // MARK: native apps

    private func normalizedURL(_ s: String) -> String {
        if s.contains("://") { return s }
        return "https://" + s
    }

    private func targetURL(_ t: String) -> URL? {
        if t.isEmpty { return nil }
        if t.hasPrefix("/") || t.hasPrefix("~") { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath) }
        if t.contains("://") { return URL(string: t) }
        if t.contains(".") && !t.contains(" ") { return URL(string: "https://" + t) }
        return nil
    }

    private func launch(path: String, target: String) -> NSRunningApplication? {
        let appURL = URL(fileURLWithPath: path)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let sem = DispatchSemaphore(value: 0)
        var result: NSRunningApplication?
        if let t = targetURL(target) {
            NSWorkspace.shared.open([t], withApplicationAt: appURL, configuration: cfg) { app, _ in result = app; sem.signal() }
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { app, _ in result = app; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 20)
        return result
    }

    private func waitForWindow(app: NSRunningApplication, path: String, exclude: [AXUIElement]) -> AXUIElement? {
        let start = Date()
        var reopened = false
        while Date().timeIntervalSince(start) < 15 {
            let free = AX.windows(app.processIdentifier).filter { w in !exclude.contains { CFEqual($0, w) } }
            if let w = free.first { return w }
            if !reopened && Date().timeIntervalSince(start) > 3 {
                // a second open sends a reopen event, which makes most apps create a window
                reopened = true
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    // MARK: Safari (web modules)

    private func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var out: NSAppleEventDescriptor?
        DispatchQueue.main.sync {
            var err: NSDictionary?
            out = NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err { NSLog("AppleScript error: \(err)") }
        }
        return out
    }

    private func placeSafari(url: String, reuseHost: String, rect: CGRect, exclude: [Int]) -> Int? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.unhide()
        let safeURL = url.replacingOccurrences(of: "\"", with: "%22")
        let safeHost = reuseHost.replacingOccurrences(of: "\"", with: "")
        let excluded = "{" + exclude.map(String.init).joined(separator: ", ") + "}"
        let make = safeURL.isEmpty ? "make new document" : "make new document with properties {URL:\"\(safeURL)\"}"
        let source = """
        tell application "Safari"
            set excluded to \(excluded)
            set w to missing value
            if "\(safeHost)" is not "" then
                repeat with x in windows
                    try
                        if (id of x) is not in excluded and (URL of current tab of x) contains "\(safeHost)" then
                            set w to contents of x
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if w is missing value then
                \(make)
                delay 0.4
                set w to front window
            end if
            set miniaturized of w to false
            set bounds of w to {\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.maxX)), \(Int(rect.maxY))}
            set index of w to 1
            return id of w
        end tell
        """
        guard let result = runAppleScript(source) else { return nil }
        return Int(result.int32Value)
    }

    private func minimizeOtherSafariWindows(keep: [Int]) {
        let ids = "{" + keep.map(String.init).joined(separator: ", ") + "}"
        _ = runAppleScript("""
        tell application "Safari"
            repeat with x in windows
                try
                    if (id of x) is not in \(ids) and visible of x then set miniaturized of x to true
                end try
            end repeat
        end tell
        """)
    }

    private func hideOtherApps(keep: Set<String>) {
        let me = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, bid != me, bid != "com.apple.finder", !keep.contains(bid) else { continue }
            app.hide()
        }
    }

    // MARK: Calendar & Reminders

    func access(_ type: EKEntityType, _ done: @escaping (Bool) -> Void) {
        let cached = type == .event ? eventsGranted : remindersGranted
        if let cached { return done(cached) }
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                if type == .event { self.eventsGranted = granted } else { self.remindersGranted = granted }
                done(granted)
            }
        }
        if #available(macOS 14.0, *) {
            if type == .event { store.requestFullAccessToEvents { g, _ in finish(g) } }
            else { store.requestFullAccessToReminders { g, _ in finish(g) } }
        } else {
            store.requestAccess(to: type) { g, _ in finish(g) }
        }
    }

    func data(for type: String, _ done: @escaping ([String: Any]) -> Void) {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let md = DateFormatter(); md.dateFormat = "MMM d"

        switch type {
        case "timeline":
            access(.event) { ok in
                guard ok else { return done(["denied": true]) }
                let pred = self.store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
                let events = self.store.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(12).map { e -> [String: Any] in
                    let state = e.endDate <= now ? "past" : (e.startDate <= now ? "now" : "")
                    return ["time": e.isAllDay ? "all-day" : hm.string(from: e.startDate), "title": e.title ?? "", "state": state]
                }
                done(["date": md.string(from: now), "events": Array(events)])
            }
        case "todo", "deadline":
            access(.reminder) { ok in
                guard ok else { return done(["denied": true]) }
                let pred = self.store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                                      ending: type == "deadline" ? endOfDay : nil,
                                                                      calendars: nil)
                self.store.fetchReminders(matching: pred) { reminders in
                    let sorted = (reminders ?? []).sorted { a, b in
                        let da = a.dueDateComponents.flatMap { cal.date(from: $0) } ?? .distantFuture
                        let db = b.dueDateComponents.flatMap { cal.date(from: $0) } ?? .distantFuture
                        return da < db
                    }
                    let items = sorted.prefix(10).map { r -> [String: Any] in
                        var due = "", late = false
                        if let comps = r.dueDateComponents, let d = cal.date(from: comps) {
                            late = d < startOfDay || (comps.hour != nil && d < now)
                            if d < startOfDay { due = type == "deadline" ? "overdue" : md.string(from: d) }
                            else if d < endOfDay { due = comps.hour != nil ? hm.string(from: d) : "today" }
                            else { due = md.string(from: d) }
                        }
                        return ["id": r.calendarItemIdentifier, "title": r.title ?? "", "due": due, "late": late]
                    }
                    DispatchQueue.main.async { done(["items": Array(items)]) }
                }
            }
        default:
            done([:])
        }
    }

    func completeReminder(_ id: String) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
    }

    func remove(_ panel: WidgetPanel) {
        panels.removeAll { $0 === panel }
    }
}

// MARK: - Floating widget panel

final class DragHandle: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class WidgetPanel: NSPanel, WKScriptMessageHandler {
    let type: String
    let web: WKWebView
    weak var owner: Applier?

    init(type: String, frame: NSRect, opacity: CGFloat, onTop: Bool, owner: Applier) {
        self.type = type
        self.owner = owner
        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.addUserScript(WKUserScript(source: "window.WIDGET_TYPE = \(jsString(type));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = uc
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        uc.add(self, name: "widget")

        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = onTop ? .floating : .normal
        isFloatingPanel = onTop
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alphaValue = opacity

        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(web)
        let handle = DragHandle(frame: NSRect(x: 0, y: frame.height - 28, width: frame.width - 30, height: 28))
        handle.autoresizingMask = [.width, .minYMargin]
        container.addSubview(handle)
        contentView = container
        web.loadFileURL(RES.appendingPathComponent("widget.html"), allowingReadAccessTo: RES)
    }

    override var canBecomeKey: Bool { true }

    func refresh() {
        owner?.data(for: type) { [weak self] d in
            guard let self, !d.isEmpty else { return }
            self.web.evaluateJavaScript("window.setData && setData(\(jsJSON(d)))")
        }
    }

    func dismiss() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "widget")
        orderOut(nil)
        close()
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["type"] as? String else { return }
        switch kind {
        case "ready": refresh()
        case "close": owner?.remove(self); dismiss()
        case "complete":
            if let id = body["id"] as? String {
                owner?.completeReminder(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
            }
        case "pomodoroDone": NSSound(named: "Glass")?.play()
        default: break
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let applier = Applier()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: SUPPORT, withIntermediateDirectories: true)
        buildMenu()

        let uc = WKUserContentController()
        var boot = ""
        if let saved = try? String(contentsOf: STATE_FILE, encoding: .utf8), !saved.isEmpty {
            boot = "window.__SAVED_STATE__ = \(saved);"
        }
        uc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        uc.add(self, name: "native")
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = uc
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Wormod"
        window.backgroundColor = .black
        window.minSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("WorkspaceEditorMain")
        window.makeKeyAndOrderFront(nil)

        web.loadFileURL(RES.appendingPathComponent("index.html"), allowingReadAccessTo: RES)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "save":
            if let s = body["state"] as? String { try? s.write(to: STATE_FILE, atomically: true, encoding: .utf8) }
        case "apply":
            guard let recipe = body["recipe"] as? [String: Any] else { return }
            applier.apply(recipe) { [weak self] ok, msg in
                guard let self else { return }
                self.web.evaluateJavaScript("window.nativeToast && nativeToast(\(jsString(msg)))")
                if ok { self.window.orderOut(nil) } else { self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            }
        default: break
        }
    }

    // JS dialogs (prompt/confirm/alert) need native panels inside WKWebView

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.window.initialFirstResponder = field
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Wormod", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Wormod", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Wormod", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

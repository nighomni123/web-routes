import AppKit
import Darwin

enum Route: String, CaseIterable {
    case wifi = "Wi-Fi"
    case usb = "USB"

    var interface: String {
        let key = self == .wifi ? "WiFiInterface" : "USBInterface"
        let defaultInterface = self == .wifi ? "en0" : "feth7070"
        return UserDefaults.standard.string(forKey: key) ?? defaultInterface
    }
    var port: Int { self == .wifi ? 48771 : 48772 }
    var symbol: String { self == .wifi ? "wifi" : "cable.connector" }
    var theme: String {
        self == .wifi ? "firefox-compact-light@mozilla.org" : "firefox-compact-dark@mozilla.org"
    }

    var connected: Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(first) }
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = next {
            let info = entry.pointee
            next = info.ifa_next
            guard String(cString: info.ifa_name) == interface,
                  info.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = info.ifa_addr,
                  address.pointee.sa_family == AF_INET else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if ipv4 != 0 && ipv4 >> 16 != 0xa9fe { return true }
        }
        return false
    }
}

final class WebRoutes: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var proxy: Process?
    private var proxyReady = false
    private var browsers: [Route: Process] = [:]
    private var terminating = false
    private let safariMenu = NSMenu()
    private let firefoxMenu = NSMenu()

    private let firefox = URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox")
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Web Routes", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Web Routes"
        statusItem.button?.toolTip = "Open a Wi-Fi-only or USB-only Firefox session"
        let menu = NSMenu()
        safariMenu.delegate = self
        firefoxMenu.delegate = self
        menu.delegate = self
        message("Safari windows", in: safariMenu)
        message("Firefox windows", in: firefoxMenu)
        menuNeedsUpdate(menu)
        statusItem.menu = menu
        startProxy()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === safariMenu { fillSafari(menu); return }
        if menu === firefoxMenu { fillFirefox(menu); return }
        for (name, sub) in [("Safari Windows", safariMenu), ("Firefox Windows", firefoxMenu)] {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            menu.addItem(item)
            item.submenu = sub
        }
        menu.addItem(.separator())
        for (index, route) in Route.allCases.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let label = NSMenuItem(title: route.connected ? "\(route.rawValue) connected" : "\(route.rawValue) unavailable",
                                   action: nil, keyEquivalent: "")
            label.image = NSImage(systemSymbolName: route.symbol, accessibilityDescription: nil)
            menu.addItem(label)
            let launch = NSMenuItem(title: "Open \(route.rawValue) Browser", action: #selector(openBrowser(_:)), keyEquivalent: "")
            launch.representedObject = route.rawValue
            launch.target = self
            launch.isEnabled = proxyReady
            menu.addItem(launch)
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        if !proxyReady {
            let retry = NSMenuItem(title: proxy == nil ? "Start Local Proxy" : "Starting Local Proxy…",
                                   action: #selector(startProxy), keyEquivalent: "")
            retry.target = self
            retry.isEnabled = proxy == nil
            menu.addItem(retry)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit Web Routes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)
    }

    @objc private func startProxy() {
        guard proxy == nil else { return }
        guard let source = Bundle.main.url(forResource: "proxy", withExtension: "py") else {
            showError("The local proxy component is missing.")
            return
        }
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        worker.arguments = [
            "-I", source.path, Route.wifi.interface, String(Route.wifi.port),
            Route.usb.interface, String(Route.usb.port), "--parent", String(getpid())
        ]
        let output = Pipe()
        worker.standardOutput = output
        worker.standardError = output
        worker.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.proxy === process else { return }
                self.proxy = nil
                self.proxyReady = false
                if !self.terminating {
                    self.statusItem.button?.toolTip = "Local proxy stopped. Open the menu to retry."
                }
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            if String(data: data, encoding: .utf8)?.contains("ready\n") == true {
                DispatchQueue.main.async {
                    guard let self, self.proxy === worker else { return }
                    self.proxyReady = true
                    self.statusItem.button?.toolTip = "Open a Wi-Fi-only or USB-only Firefox session"
                }
            }
        }
        do {
            try worker.run()
            proxy = worker
        } catch {
            showError("The local proxy could not start. \(error.localizedDescription)")
        }
    }

    @objc private func openBrowser(_ item: NSMenuItem) {
        guard proxyReady, let raw = item.representedObject as? String, let route = Route(rawValue: raw) else { return }
        launchBrowser(route, urls: [])
    }

    private func launchBrowser(_ route: Route, urls: [URL]) {
        guard FileManager.default.isExecutableFile(atPath: firefox.path) else {
            showError("Install Firefox in Applications to open a routed browser.")
            return
        }
        let profile = support.appendingPathComponent(route == .wifi ? "Wi-Fi" : "USB", isDirectory: true)
        do {
            if let pid = browsers[route].flatMap({ $0.isRunning ? $0.processIdentifier : nil }) ?? profileOwner(profile),
               let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "org.mozilla.firefox" {
                for url in urls {
                    let event = NSAppleEventDescriptor(eventClass: 0x4755524c, eventID: 0x4755524c,
                        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: -1, transactionID: 0)
                    event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: 0x2d2d2d2d)
                    let reply = try event.sendEvent(options: [.waitForReply], timeout: 5)
                    if let error = reply.paramDescriptor(forKeyword: 0x6572726e), error.int32Value != 0 {
                        throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
                    }
                }
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return
            }
            let prefsURL = Bundle.main.url(forResource: "firefox-prefs", withExtension: "js")
            guard let prefsURL else { throw CocoaError(.fileNoSuchFile) }
            let prefs = try String(contentsOf: prefsURL, encoding: .utf8)
                .replacingOccurrences(of: "__SOCKS_PORT__", with: String(route.port))
                .replacingOccurrences(of: "__THEME_ID__", with: route.theme)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try prefs.write(to: profile.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)
            let browser = Process()
            browser.executableURL = firefox
            browser.arguments = ["-no-remote", "-profile", profile.path, "-new-window", urls.first?.absoluteString ?? "about:blank"] + urls.dropFirst().flatMap { ["-new-tab", $0.absoluteString] }
            browser.standardOutput = FileHandle.nullDevice
            browser.standardError = FileHandle.nullDevice
            browser.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.browsers[route] === process else { return }
                    self.browsers[route] = nil
                    if process.terminationStatus != 0 && !self.terminating {
                        self.showError("Firefox could not open the \(route.rawValue) profile. If it is already open, quit that Firefox instance and try again.")
                    }
                }
            }
            try browser.run()
            browsers[route] = browser
        } catch {
            showError("The \(route.rawValue) browser could not start. \(error.localizedDescription)")
        }
    }

    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Web Routes"
        alert.informativeText = text
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        if let proxy, proxy.isRunning { proxy.terminate() }
    }
}

let application = NSApplication.shared
let delegate = WebRoutes()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

private extension WebRoutes {
    func profileOwner(_ directory: URL) -> pid_t? {
        let file = Darwin.open(directory.appendingPathComponent(".parentlock").path, O_RDONLY)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(file, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK), lock.l_pid > 0 else { return nil }
        return lock.l_pid
    }

    func message(_ text: String, in menu: NSMenu) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func safari(_ body: String) throws -> [NSAppleEventDescriptor] {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application id \"com.apple.Safari\"\n" + body + "\nend tell")
        guard let reply = script?.executeAndReturnError(&error), error == nil else {
            let detail = error?[NSAppleScript.errorMessage] as? String ?? "Safari automation is unavailable."
            throw NSError(domain: "Safari", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return (0..<reply.numberOfItems).compactMap { reply.atIndex($0 + 1) }
    }

    func windowActions(_ label: String, menu: NSMenu) -> NSMenu {
        let parent = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        menu.addItem(parent)
        let actions = NSMenu()
        actions.autoenablesItems = false
        parent.submenu = actions
        return actions
    }

    func fillSafari(_ menu: NSMenu) {
        menu.autoenablesItems = false
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
            message("Safari is closed", in: menu); return
        }
        do {
            let rows = try safari("""
                set rows to {}
                repeat with w in windows
                    set end of rows to {id of w, name of w}
                end repeat
                return rows
                """)
            if rows.isEmpty { message("No open Safari windows", in: menu) }
            for row in rows {
                guard let id = row.atIndex(1)?.int32Value else { continue }
                let actions = windowActions(row.atIndex(2)?.stringValue ?? "Safari window", menu: menu)
                for route in Route.allCases {
                    let item = NSMenuItem(title: "Reopen Tabs in " + route.rawValue + " Firefox", action: #selector(importSafari(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = Int(id)
                    item.representedObject = route.rawValue
                    item.isEnabled = proxyReady
                    actions.addItem(item)
                }
            }
        } catch { message(error.localizedDescription, in: menu) }
    }

    @objc func importSafari(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let route = Route(rawValue: name) else { return }
        do {
            let tabs = try safari("return URL of every tab of window id " + String(item.tag))
            let urls = tabs.compactMap { $0.stringValue.flatMap(URL.init(string:)) }.filter {
                ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil
            }
            guard !urls.isEmpty else { showError("This window has no web tabs to reopen."); return }
            launchBrowser(route, urls: urls)
        } catch { showError(error.localizedDescription) }
    }

    struct Snapshot: Decodable {
        struct Window: Decodable { let id: Int; let title: String; let route: String }
        let pid: Int32
        let windows: [Window]
    }

    func fillFirefox(_ menu: NSMenu) {
        menu.autoenablesItems = false
        let root = support.appendingPathComponent("Sessions")
        let sessions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var connected = false
        for session in sessions where session.lastPathComponent.hasPrefix("session-") {
            guard let data = try? Data(contentsOf: session.appendingPathComponent("state.json")),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.pid > 0, kill(snapshot.pid, 0) == 0 else { continue }
            connected = true
            for window in snapshot.windows {
                let actions = windowActions(window.title, menu: menu)
                for route in ["Wi-Fi", "USB", "Default"] {
                    let title = route == "Default" ? "Use Firefox Default" : "Use " + route
                    let item = NSMenuItem(title: title, action: #selector(selectFirefox(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = window.id
                    item.representedObject = [session.path, route]
                    item.state = window.route == route ? .on : .off
                    item.isEnabled = proxyReady || route == "Default"
                    actions.addItem(item)
                }
            }
        }
        if menu.items.isEmpty { message(connected ? "No regular Firefox windows" : "Firefox companion is disconnected", in: menu) }
        menu.addItem(.separator())
        let setup = NSMenuItem(title: "Connect Firefox…", action: #selector(setupFirefox), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
    }

    @objc func selectFirefox(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [String], values.count == 2 else { return }
        do {
            let directory = URL(fileURLWithPath: values[0])
            let data = try JSONSerialization.data(withJSONObject: ["id": item.tag, "route": values[1]])
            try data.write(to: directory.appendingPathComponent("cmd-" + UUID().uuidString + ".json"), options: .atomic)
        } catch { showError("Firefox window selection failed. " + error.localizedDescription) }
    }

    @objc func setupFirefox() {
        guard let manifest = Bundle.main.resourceURL?.appendingPathComponent("Companion/manifest.json") else { return }
        let alert = NSAlert()
        alert.messageText = "Connect this Firefox session"
        alert.informativeText = "In the Firefox profile you want to control, open about:debugging#/runtime/this-firefox and choose Load Temporary Add-on. Select the manifest.json shown in Finder. Repeat after Firefox restarts."
        alert.addButton(withTitle: "Show Manifest in Finder")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([manifest]) }
    }
}

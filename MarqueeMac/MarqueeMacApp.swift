import SwiftUI
import WebKit
import Network
import UserNotifications

/// Marquee for Mac.
/// Shows your Marquee server in its own window (no browser tabs or address bar) and adds what a browser tab can't:
/// a Dock icon, new-arrival notifications, the screen staying awake while you watch, menu shortcuts, and
/// "Save file" downloads straight to your Downloads folder.
@main
struct MarqueeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Marquee", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 500)
                .onOpenURL { model.open(url: $0) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Server Addresses…") { model.showSetup = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Back") { model.back() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Home") { model.go("#/") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Search") { model.go("#/search") }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifications = NotificationHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notifications
        // Opened the lid somewhere else? Check the server is still reachable and switch address if not
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000) // give Wi-Fi and Tailscale a moment
                AppModel.shared.becameActive(force: true)
            }
        }
    }

    // One window: closing it quits, like most media apps
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.becameActive()
        MacNotifier.checkNow()
    }
}

/// Tapping a "New on Marquee" notification opens that movie or episode.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let open = (response.notification.request.content.userInfo["open"] as? String) ?? "#/notifications"
        Task { @MainActor in AppModel.shared.go(open) }
        completionHandler()
    }
}

// MARK: - App state

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// The address in use right now — your home one or your away one, whichever answered.
    /// nil while it's still being found. e.g. "http://192.168.80.35:8420" or "https://zimaos.tail1234.ts.net"
    @Published var server: String?
    /// No addresses at all (none built in, none saved): show the "where's your server?" screen.
    @Published var needsSetup = Addresses.current == nil
    @Published var showSetup = false
    @Published var offline = false
    @Published var loading = true

    weak var webView: WKWebView?
    private var pendingHash: String?
    private var timer: Timer?
    private var awake: NSObjectProtocol?
    private var finding = false
    private var findAgain = false
    private var playing = false
    private var lastCheck = Date.distantPast
    private var lastAutoRetry = Date.distantPast
    private let network = NWPathMonitor()
    private var networkSettling: DispatchWorkItem?

    private init() {
        if !needsSetup { find() }
        // Wi-Fi changed (left the house, arrived home, joined a hotspot): check straight away whether to switch address
        network.pathUpdateHandler = { _ in
            Task { @MainActor in AppModel.shared.networkChanged() }
        }
        network.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func networkChanged() {
        guard server != nil || offline else { return }
        networkSettling?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in AppModel.shared.becameActive(force: true) } }
        networkSettling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work) // give the new network (and Tailscale) a moment
    }

    /// Works out which address reaches the server right now — home on your Wi-Fi, away (Tailscale) everywhere
    /// else — and opens the app there, on the page you were on.
    func find(patient: Bool = false) {
        guard !finding else {
            findAgain = true // e.g. new addresses were saved while a search was under way: look again when it ends
            return
        }
        finding = true
        offline = false
        loading = true
        let before = server ?? Addresses.last
        if pendingHash == nil { pendingHash = currentHash() }
        Task { @MainActor in
            let found = await Servers.pick(patient: patient)
            if let url = found { await Servers.copyLogin(from: before, to: url) } // stay signed in at both addresses
            self.finding = false
            if self.findAgain {
                self.findAgain = false
                self.find(patient: true)
                return
            }
            guard let url = found else {
                self.loading = false
                self.offline = true
                return
            }
            if self.server == url { self.reloadPage() } else { self.server = url } // RootView rebuilds the web view at the new address
        }
    }

    private func reloadPage() {
        guard let server = server, let web = webView else { return }
        if let now = web.url, sameOrigin(now, server) {
            web.reload() // once it's loaded, the page that was asked for (if any) is opened
        } else if let url = URL(string: server + "/" + (pendingHash ?? "")) {
            web.load(URLRequest(url: url))
        }
    }

    /// "#/item/4": the page being shown, whichever address it came from.
    private func currentHash() -> String? {
        guard let url = webView?.url, Addresses.isOurs(url, current: server), let f = url.fragment else { return nil }
        return "#" + f
    }

    /// The addresses were typed in (first run, or Marquee → Server Addresses…).
    func save(home: String?, away: String?, working: String) {
        if !Addresses.candidates.contains(working) {
            // A different server: its notifications start afresh, and the old server's sign-in isn't carried over
            UserDefaults.standard.set(0, forKey: "last_note_id")
            pendingHash = nil
            server = nil
        }
        Addresses.set(home: home, away: away)
        Addresses.last = working
        needsSetup = false
        showSetup = false
        keepAwake(false)
        find(patient: true)
    }

    /// A page didn't load. Maybe you just left the house (or came home): look for the other address once before giving up.
    func pageFailed() {
        if finding { return }
        if Date().timeIntervalSince(lastAutoRetry) > 15 {
            lastAutoRetry = Date()
            find()
        } else {
            loading = false
            offline = true
        }
    }

    /// Back in the app (or the Mac just woke). If it couldn't connect before, try again by itself. If the address
    /// in use has stopped answering — you've moved between home and away — switch to the other, on the same page.
    func becameActive(force: Bool = false) {
        if needsSetup { return }
        let now = Date()
        if offline {
            if !finding && now.timeIntervalSince(lastCheck) > 3 {
                lastCheck = now
                find()
            }
            return
        }
        guard let using = server, !loading, !finding, !playing, force || now.timeIntervalSince(lastCheck) > 20 else { return }
        lastCheck = now
        Task { @MainActor in
            if await Servers.probe(using, timeout: 3) != nil { return }
            // Not answering. Patiently look at both addresses (a busy server can be slow) before deciding anything
            let other = await Servers.pick(patient: true)
            guard other != using, self.server == using, !self.finding, !self.playing else { return }
            guard let next = other else {
                self.find() // nothing answers (left home with Tailscale off?): say so, and offer Tailscale
                return
            }
            self.pendingHash = self.currentHash()
            await Servers.copyLogin(from: using, to: next)
            self.loading = true
            self.server = next
        }
    }

    /// Reload (⌘R) and "Try Again".
    func reload() {
        if offline || server == nil { find(patient: true); return }
        webView?.reload()
    }

    func back() {
        webView?.evaluateJavaScript("history.back()", completionHandler: nil)
    }

    /// Open a page of the app, e.g. "#/item/42".
    func go(_ hash: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard let web = webView, !loading, !offline else { pendingHash = hash; return }
        let h = hash.hasPrefix("#") ? String(hash.dropFirst()) : hash
        web.evaluateJavaScript("location.hash = \(jsString(h))", completionHandler: nil)
    }

    /// The page to open once connected. It's kept until a page has really loaded, so a failed try doesn't lose it.
    var startHash: String { pendingHash ?? "" }

    func takePendingHash() -> String? {
        defer { pendingHash = nil }
        return pendingHash
    }

    /// A page finished loading: show it, and open whatever page was asked for in the meantime.
    func pageLoaded() {
        loading = false
        offline = false
        guard let hash = takePendingHash(), let web = webView else { return }
        if let f = web.url?.fragment, "#" + f == hash { return } // already there (it was part of the address)
        let h = hash.hasPrefix("#") ? String(hash.dropFirst()) : hash
        web.evaluateJavaScript("location.hash = \(jsString(h))", completionHandler: nil)
    }

    /// marquee://item/42 → #/item/42
    func open(url: URL) {
        guard url.scheme?.lowercased() == "marquee" else { return }
        go("#/" + (url.host ?? "") + url.path)
    }

    /// Check for "New on Marquee" every 15 minutes while the app is open.
    func startNotifications() {
        guard timer == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in MacNotifier.checkNow() }
        }
        MacNotifier.checkNow()
    }

    /// Keeps the display from sleeping while a video plays.
    func keepAwake(_ on: Bool) {
        let wasPlaying = playing
        playing = on
        if wasPlaying && !on { becameActive() } // moved between home and away while watching? switch address now
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }
}

// MARK: - Screens

enum Theme {
    static let bg = Color(red: 13 / 255, green: 11 / 255, blue: 9 / 255)
    static let panel = Color(red: 22 / 255, green: 19 / 255, blue: 15 / 255)
    static let text = Color(red: 245 / 255, green: 239 / 255, blue: 230 / 255)
    static let muted = Color(red: 169 / 255, green: 157 / 255, blue: 140 / 255)
    static let accent = Color(red: 240 / 255, green: 180 / 255, blue: 41 / 255)
    static let accentInk = Color(red: 26 / 255, green: 18 / 255, blue: 3 / 255)
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if model.needsSetup {
                SetupView(canCancel: false)
            } else {
                if let server = model.server {
                    WebView(server: server, model: model)
                        .id(server) // a different address (home ↔ away) gets a fresh web view
                }
                if model.offline { OfflineView() } else if model.loading || model.server == nil { SplashView() }
            }
        }
        .sheet(isPresented: $model.showSetup) {
            SetupView(canCancel: true)
                .frame(width: 540)
        }
        .preferredColorScheme(.dark)
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.bg
            VStack(spacing: 22) {
                Image("Logo").resizable().frame(width: 84, height: 84)
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct OfflineView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text("Can't reach Marquee")
                    .font(.title.bold())
                    .foregroundColor(Theme.text)
                Text(Addresses.away == nil
                     ? "Your home address didn't answer, and this app doesn't know your away-from-home (Tailscale) address yet.\n\nIt learns it the first time it connects on your home Wi-Fi — or click Server Addresses… and type it in."
                     : "Marquee tried your home address and your away address, and neither answered.\n\nAway from home? Switch Tailscale on and come back — Marquee reconnects by itself.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: 400)
                HStack(spacing: 12) {
                    Button("Server Addresses…") { model.showSetup = true }
                    Button("Open Tailscale") { Tailscale.open() }
                    Button("Try Again") { model.find(patient: true) }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
            .padding(40)
        }
    }
}

/// Your server's two addresses: one for home Wi-Fi, one for away (Tailscale).
/// Usually already filled in — they're built into the app and the server tells the app the rest — so this
/// is mostly for changing them (Marquee → Server Addresses…).
struct SetupView: View {
    let canCancel: Bool
    @EnvironmentObject private var model: AppModel
    @State private var home = Addresses.home ?? ""
    @State private var away = Addresses.away ?? ""
    @State private var problem: String?
    @State private var checking = false

    init(canCancel: Bool) { self.canCancel = canCancel }

    private var empty: Bool {
        home.trimmingCharacters(in: .whitespaces).isEmpty && away.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image("Logo").resizable().frame(width: 64, height: 64)
            Text(canCancel ? "Your server's addresses" : "Welcome to Marquee")
                .font(.largeTitle.bold())
                .foregroundColor(Theme.text)
            Text("Marquee uses the home address when you're on your Wi-Fi and the away address everywhere else. It chooses by itself — you never have to pick.")
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("AT HOME (YOUR WI-FI)").font(.caption.bold()).foregroundColor(Theme.muted).padding(.top, 6)
            TextField("192.168.80.35:8420", text: $home)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .disableAutocorrection(true)
                .onSubmit { tryConnect() }

            Text("AWAY FROM HOME (TAILSCALE)").font(.caption.bold()).foregroundColor(Theme.muted)
            TextField("zimaos.tail1234.ts.net  (optional)", text: $away)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .disableAutocorrection(true)
                .onSubmit { tryConnect() }

            HStack(spacing: 12) {
                Button(action: tryConnect) {
                    Text(checking ? "Checking…" : "Connect").frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checking || empty)
                if canCancel {
                    Button("Cancel") { model.showSetup = false }
                        .keyboardShortcut(.cancelAction)
                }
                if checking { ProgressView().controlSize(.small) }
            }
            .padding(.top, 4)

            if let problem = problem {
                Text(problem)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Home: your ZimaOS box's address on your Wi-Fi, like 192.168.80.35:8420.\n\nAway: the box's Tailscale address, like zimaos.tail1234.ts.net or 100.x.y.z:8420. Leave it empty if you don't know it — once it's saved in Marquee → Settings → Server addresses on any device, this Mac picks it up by itself.\n\nTip: in Tailscale's settings, turn on VPN On Demand and Tailscale switches itself on whenever you leave your Wi-Fi.")
                .font(.callout)
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(36)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.bg)
    }

    private func tryConnect() {
        let h = Addresses.normalise(home)
        let a = Addresses.normalise(away)
        guard !h.isEmpty || !a.isEmpty, !checking else { return }
        checking = true
        problem = nil
        Task { @MainActor in
            // Either address answering is enough — you might be setting this up away from home.
            // (Patient: a server busy scanning a big library can take a while to answer.)
            let found = await Servers.race(home: h.isEmpty ? nil : h, away: a.isEmpty ? nil : a, homeWait: 12, awayWait: 12)
            let working = found?.0
            checking = false
            if let working = working {
                model.save(home: h.isEmpty ? nil : h, away: a.isEmpty ? nil : a, working: working)
            } else {
                problem = "Neither address answered. Check them, and that Tailscale is on if you're away from home. If macOS asked about devices on your local network, choose Allow (System Settings → Privacy & Security → Local Network)."
            }
        }
    }
}

/// Tailscale is the separate (free) app that lets this Mac reach home from anywhere.
enum Tailscale {
    @MainActor static func open() {
        // The version from Tailscale's website, then the Mac App Store one
        for id in ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                return
            }
        }
        if let page = URL(string: "https://tailscale.com/download/mac") { NSWorkspace.shared.open(page) }
    }
}

// MARK: - Helpers

/// Text safely embedded in JavaScript source.
func jsString(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [s]),
          let json = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(json.dropFirst().dropLast()) // strip the [ ]
}

let appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

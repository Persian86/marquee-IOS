import UIKit
import WebKit
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Settings saved on this device

enum Prefs {
    private static let d = UserDefaults.standard

    /// The address in use: whichever of your two addresses (home / away) answered most recently.
    /// e.g. "http://192.168.80.35:8420" or "https://zimaos.tail1234.ts.net"
    static var server: String? {
        get { Addresses.current }
        set {
            Addresses.last = newValue
            SharedStore.server = newValue
        }
    }

    /// Widgets and Siri are separate mini-apps: hand them the addresses so they can find the server too.
    static func publish() {
        if SharedStore.home != Addresses.home { SharedStore.home = Addresses.home }
        if SharedStore.away != Addresses.away { SharedStore.away = Addresses.away }
        if SharedStore.server != Addresses.current { SharedStore.server = Addresses.current }
    }

    /// The newest "New on Marquee" message already shown, so nothing is announced twice.
    static var lastNoteId: Int {
        get { d.integer(forKey: "last_note_id") }
        set { d.set(newValue, forKey: "last_note_id") }
    }

    static func normalise(_ input: String) -> String { Addresses.normalise(input) }
}

// MARK: - Colours (match the web app)

extension UIColor {
    private convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    static let mqBackground = UIColor(hex: 0x0D0B09)
    static let mqPanel = UIColor(hex: 0x16130F)
    static let mqPanel2 = UIColor(hex: 0x211C16)
    static let mqText = UIColor(hex: 0xF5EFE6)
    static let mqMuted = UIColor(hex: 0xA99D8C)
    static let mqAccent = UIColor(hex: 0xF0B429)
    static let mqAccentInk = UIColor(hex: 0x1A1203)
}

extension UIButton {
    /// The gold "primary" and outlined "secondary" buttons used across the app.
    static func marquee(_ title: String, primary: Bool) -> UIButton {
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .large
        config.baseBackgroundColor = primary ? .mqAccent : .mqPanel2
        config.baseForegroundColor = primary ? .mqAccentInk : .mqText
        config.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 20, bottom: 13, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            return a
        }
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

extension UIViewController {
    /// The view controller currently on top, to present things from.
    var topMost: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// Text safely embedded in JavaScript source.
func jsString(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [s]),
          let json = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(json.dropFirst().dropLast()) // strip the [ ]
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

let appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

// MARK: - Sign-in cookies

/// The web app signs in with a cookie. Copying it to the app's shared cookie store means
/// background jobs (notifications, downloads, offline progress) are signed in as the same profile.
enum WebCookies {
    static func sync(_ done: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
                done?()
            }
        }
    }

    static func header(for url: URL) -> String? {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    /// A request to the Marquee server, signed in.
    static func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, timeout: TimeInterval = 15, base: String? = nil) -> URLRequest? {
        guard let server = base ?? Prefs.server, let url = URL(string: server + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let c = header(for: url) { req.setValue(c, forHTTPHeaderField: "Cookie") }
        if let json = json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// For background jobs: sends a signed-in request to whichever address answers — the one used last first,
    /// then the other (you may have left the house since). `done` gets nils when neither answered.
    static func fetch(_ path: String, method: String = "GET", json: [String: Any]? = nil, timeout: TimeInterval = 15,
                      done: @escaping (Data?, HTTPURLResponse?) -> Void) {
        let list = Addresses.candidates
        func attempt(_ i: Int) {
            guard i < list.count else { return done(nil, nil) }
            let wait = i == list.count - 1 ? timeout : min(timeout, 4)
            guard let req = request(path, method: method, json: json, timeout: wait, base: list[i]) else { return attempt(i + 1) }
            URLSession.shared.dataTask(with: req) { data, response, _ in
                guard let http = response as? HTTPURLResponse else { return attempt(i + 1) }
                // Remember which address answered, so follow-ups (like fetching a poster) go to the same one
                if Addresses.last != list[i] { Prefs.server = list[i] }
                done(data, http)
            }.resume()
        }
        attempt(0)
    }
}

// MARK: - Watch progress from offline viewing

/// Where you got to in a downloaded movie is sent to the server, or kept until you're back online.
enum OfflineProgress {
    private static let key = "progress_queue"

    static func send(itemId: Int, position: Double, duration: Double) {
        let body: [String: Any] = ["itemId": itemId, "position": position, "duration": duration, "state": "stopped"]
        post(body) { ok in if !ok { enqueue(body) } }
    }

    static func flush() {
        let queue = (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? []
        guard !queue.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key)
        WebCookies.sync {
            for body in queue { post(body) { ok in if !ok { enqueue(body) } } }
        }
    }

    private static func enqueue(_ body: [String: Any]) {
        DispatchQueue.main.async {
            var queue = (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? []
            // Only the latest position per item matters
            queue.removeAll { ($0["itemId"] as? Int) == (body["itemId"] as? Int) }
            queue.append(body)
            UserDefaults.standard.set(Array(queue.suffix(200)), forKey: key)
        }
    }

    private static func post(_ body: [String: Any], done: @escaping (Bool) -> Void) {
        WebCookies.fetch("/api/progress", method: "POST", json: body) { _, response in
            let code = response?.statusCode ?? 0
            // 404 = that item no longer exists on the server: nothing to retry
            done(code == 200 || code == 404)
        }
    }
}

// MARK: - Widget & Siri key

/// After you pick your profile, the app asks the server for its own key so widgets and Siri work
/// without the web page (it shows in Marquee → Settings → Connected apps; remove it there any time).
enum DeviceKey {
    static func ensure() {
        Prefs.publish()
        guard SharedStore.deviceKey == nil else { return }
        WebCookies.sync {
            let name = "\(UIDevice.current.name) (\(UIDevice.current.model))"
            guard let req = WebCookies.request("/api/app-tokens", method: "POST", json: ["kind": "device", "name": name]),
                  req.value(forHTTPHeaderField: "Cookie")?.contains("mq_session=") == true else { return }
            URLSession.shared.dataTask(with: req) { data, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let token = json["token"] as? String else { return }
                DispatchQueue.main.async {
                    SharedStore.deviceKey = token
                    reloadWidgets()
                }
            }.resume()
        }
    }
}

func reloadWidgets() {
    #if canImport(WidgetKit)
    if #available(iOS 14.0, *) { WidgetCenter.shared.reloadAllTimelines() }
    #endif
}

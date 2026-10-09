import Foundation

/// Settings shared between the Marquee app, its home-screen widgets and Siri.
/// Uses an App Group so the widget (a separate mini-app) can read them.
enum SharedStore {
    static let group = "group.com.adam.marquee"
    /// Falls back to the app's own settings when App Groups aren't available (some sideloading tools).
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    /// The address that worked most recently — home or away.
    static var server: String? {
        get { defaults.string(forKey: "server_url") }
        set { defaults.set(newValue, forKey: "server_url") }
    }
    /// The address on your home Wi-Fi, and the one for away from home (Tailscale). Same server, two ways in.
    static var home: String? {
        get { defaults.string(forKey: "home_url").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: "home_url") }
    }
    static var away: String? {
        get { defaults.string(forKey: "away_url").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: "away_url") }
    }
    /// Every address worth trying, the one that worked last first.
    static var candidates: [String] {
        var out: [String] = []
        for s in [server, home, away] {
            if let s = s, !s.isEmpty, !out.contains(s) { out.append(s) }
        }
        return out
    }
    /// Key the widgets and Siri use to talk to the server (made automatically after you pick your profile).
    static var deviceKey: String? {
        get { defaults.string(forKey: "device_key") }
        set { defaults.set(newValue, forKey: "device_key") }
    }

    /// GET or POST to the Marquee server with the device key.
    static func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, timeout: TimeInterval = 15, base: String? = nil) -> URLRequest? {
        guard let server = base ?? server, let key = deviceKey, let url = URL(string: server + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// Sends a request to whichever address answers — home on your Wi-Fi, away everywhere else — and remembers
    /// which one it was. `done` gets nils when no address answered (or there's no device key yet).
    static func fetch(_ path: String, method: String = "GET", json: [String: Any]? = nil, timeout: TimeInterval = 15,
                      done: @escaping (Data?, HTTPURLResponse?) -> Void) {
        let list = candidates
        func attempt(_ i: Int, checked: Bool) {
            guard i < list.count else { return done(nil, nil) }
            let isLast = i == list.count - 1
            if method != "GET" && !isLast && !checked {
                // A command (like "play…") must never be sent twice, so first see whether this address answers at all
                guard let ping = URL(string: list[i] + "/api/status") else { return attempt(i + 1, checked: false) }
                URLSession.shared.dataTask(with: URLRequest(url: ping, timeoutInterval: 4)) { _, response, _ in
                    if response is HTTPURLResponse { attempt(i, checked: true) } else { attempt(i + 1, checked: false) }
                }.resume()
                return
            }
            // Only an address known to answer (or the last one left) gets the full wait; the rest should fail fast
            let wait = isLast || checked ? timeout : min(timeout, 4)
            guard let req = request(path, method: method, json: json, timeout: wait, base: list[i]) else { return done(nil, nil) }
            URLSession.shared.dataTask(with: req) { data, response, _ in
                guard let http = response as? HTTPURLResponse else {
                    if checked { done(nil, nil) } else { attempt(i + 1, checked: false) }
                    return
                }
                if server != list[i] { server = list[i] }
                done(data, http)
            }.resume()
        }
        attempt(0, checked: false)
    }

    static func fetch(_ path: String, method: String = "GET", json: [String: Any]? = nil, timeout: TimeInterval = 15) async -> (Data?, HTTPURLResponse?) {
        await withCheckedContinuation { c in
            fetch(path, method: method, json: json, timeout: timeout) { data, response in c.resume(returning: (data, response)) }
        }
    }

    static func absolute(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        guard let server else { return nil }
        return URL(string: server + path)
    }
}

/// What the "Continue watching" and "New on Marquee" widgets show (from /ext/v1/widget).
struct WidgetFeed: Codable {
    struct Card: Codable, Hashable {
        let id: Int
        let type: String
        let title: String
        let subtitle: String?
        let progress: Double?
        let image: String?
        let open: String
        let play: String
    }
    let serverName: String?
    let profile: String?
    let continueWatching: [Card]
    let newArrivals: [Card]
}

import Foundation
import WebKit

// Shared by the iPhone/iPad app and the Mac app.

/// Your server's two addresses: one for your home Wi-Fi, one for everywhere else (Tailscale).
/// Both can be built into the app (MARQUEE_HOME / MARQUEE_AWAY in project.yml) and the server tells the app
/// any it's missing, so nobody has to type an address or choose between them.
enum Addresses {
    private static var d: UserDefaults { .standard }

    /// The address on your home Wi-Fi: what you saved (or the server told us), else what was built into the app.
    static var home: String? { saved("home_url") ?? builtIn("MarqueeHome") }

    /// The address away from home (Tailscale).
    static var away: String? { saved("away_url") ?? builtIn("MarqueeAway") }

    private static func saved(_ key: String) -> String? {
        migrate()
        guard let s = d.string(forKey: key), !s.isEmpty else { return nil }
        return s
    }

    /// Set up before there were two addresses? File the single saved one under home or away, once.
    private static func migrate() {
        if d.bool(forKey: "addresses_migrated") { return }
        d.set(true, forKey: "addresses_migrated")
        guard let old = d.string(forKey: "server_url"), !old.isEmpty else { return }
        let key = isAwayStyle(old) ? "away_url" : "home_url"
        if d.string(forKey: key) == nil { d.set(old, forKey: key) }
    }

    /// The address that worked most recently.
    static var last: String? {
        get { d.string(forKey: "server_url") }
        set { d.set(newValue, forKey: "server_url") }
    }

    /// Where to start: the address that worked last time, else home, else away. nil = nothing known, show setup.
    static var current: String? { last ?? home ?? away }

    /// Every address worth trying, the one that worked last first.
    static var candidates: [String] {
        var out: [String] = []
        for s in [last, home, away] {
            if let s = s, !s.isEmpty, !out.contains(s) { out.append(s) }
        }
        return out
    }

    static func set(home: String?, away: String?) {
        setHome(home)
        setAway(away)
    }
    static func setHome(_ url: String?) { d.set(url ?? "", forKey: "home_url") }
    static func setAway(_ url: String?) { d.set(url ?? "", forKey: "away_url") }

    /// Is this page on our server, at either of its addresses?
    static func isOurs(_ url: URL, current: String? = nil) -> Bool {
        [current, home, away].compactMap { $0 }.contains { sameOrigin(url, $0) }
    }

    /// Tailscale addresses are names ending .ts.net, or numbers 100.64.x.x – 100.127.x.x
    static func isAwayStyle(_ address: String) -> Bool {
        guard let host = URLComponents(string: address)?.host?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func builtIn(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String, !raw.contains("$(") else { return nil }
        let s = normalise(raw)
        return s.isEmpty ? nil : s
    }

    /// "zimaos:8420" → "http://zimaos:8420". Tailscale names (.ts.net) get https://.
    /// Plain http with no port gets Marquee's default port 8420. Any path (like "/#/") is dropped.
    static func normalise(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = (lower.contains(".ts.net") ? "https://" : "http://") + s
        }
        guard var parts = URLComponents(string: s), let host = parts.host, !host.isEmpty else { return s }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        if parts.scheme == "http" && parts.port == nil { parts.port = 8420 }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? s
    }
}

/// What a Marquee server says about itself at /api/status.
struct ServerStatus: Sendable {
    /// The addresses the server knows for itself (Marquee → Settings), if any.
    let home: String?
    let away: String?
}

/// Picks the right address by itself: home when you're on your Wi-Fi, away (Tailscale) everywhere else.
enum Servers {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Is there a Marquee server at this address? Gives what it says about itself, or nil.
    static func probe(_ base: String, timeout: TimeInterval) async -> ServerStatus? {
        guard let url = URL(string: base + "/api/status") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: timeout)
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["needsSetup"] != nil else { return nil }
        let a = json["addresses"] as? [String: Any]
        func clean(_ v: Any?) -> String? {
            guard let s = v as? String else { return nil }
            let n = Addresses.normalise(s)
            return n.isEmpty ? nil : n
        }
        return ServerStatus(home: clean(a?["home"]), away: clean(a?["away"]))
    }

    private enum Lane: Sendable { case home, away }

    /// Ask both addresses at once; gives the one to use and what the server said, or nil if neither answered.
    /// Home is always the quicker road when it's open, so if away answers first, home only gets a moment
    /// longer before away wins.
    static func race(home: String?, away awayIn: String?, homeWait: TimeInterval, awayWait: TimeInterval) async -> (String, ServerStatus)? {
        let away = awayIn == home ? nil : awayIn
        if home == nil && away == nil { return nil }
        return await withTaskGroup(of: (Lane, ServerStatus?).self) { group in
            if let h = home {
                group.addTask { (Lane.home, await probe(h, timeout: homeWait)) }
            }
            if let a = away {
                group.addTask {
                    let status = await probe(a, timeout: awayWait)
                    if status != nil && home != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
                    return (Lane.away, status)
                }
            }
            var found: (String, ServerStatus)?
            for await (lane, status) in group {
                guard let status = status, let url = (lane == .home ? home : away) else { continue }
                found = (url, status)
                break
            }
            group.cancelAll()
            return found
        }
    }

    /// Find the address that answers right now, remember it, and pick up any address the server tells us about.
    /// (Away gets longer than home: Tailscale may still be waking up.)
    @MainActor
    static func pick(patient: Bool = false) async -> String? {
        guard let (url, status) = await race(home: Addresses.home, away: Addresses.away,
                                             homeWait: patient ? 6 : 2.5, awayWait: patient ? 12 : 7) else { return nil }
        // The server knows its own addresses; fill in any we don't have yet
        if Addresses.home == nil, let h = status.home { Addresses.setHome(h) }
        if Addresses.away == nil, let a = status.away { Addresses.setAway(a) }
        Addresses.last = url
        return url
    }

    /// Home and away are the same server, so whoever is signed in at the address just used should be signed in
    /// at the other one too. Copies the sign-in cookie across inside the app's web view.
    /// `from` is the address that was in use, so its sign-in is the up-to-date one and wins.
    @MainActor
    static func copyLogin(from: String?, to: String) async {
        // WebKit has been known not to answer cookie requests before its first page: never let that hold the app up
        let once = Once()
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await copyCookies(from: from, to: to)
                if !once.done { once.done = true; waiting.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !once.done { once.done = true; waiting.resume() }
            }
        }
    }

    @MainActor private final class Once { var done = false }

    @MainActor
    private static func copyCookies(from: String?, to: String) async {
        guard let from = from, from != to,
              let fromHost = URLComponents(string: from)?.host?.lowercased(),
              let toHost = URLComponents(string: to)?.host?.lowercased(), fromHost != toHost else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        func host(_ c: HTTPCookie) -> String {
            let d = c.domain.lowercased()
            return d.hasPrefix(".") ? String(d.dropFirst()) : d
        }
        // mq_session = who is signed in; mq_dev = "this is a device the server has seen before"
        for name in ["mq_session", "mq_dev"] {
            guard let theirs = cookies.first(where: { $0.name == name && host($0) == fromHost }),
                  let copy = HTTPCookie(properties: [
                    .name: name, .value: theirs.value, .domain: toHost, .path: "/",
                    .expires: Date().addingTimeInterval(365 * 24 * 60 * 60),
                    HTTPCookiePropertyKey("HttpOnly"): "TRUE",
                  ]) else { continue }
            await store.setCookie(copy)
        }
    }
}

/// WebKit lower-cases host names and drops default ports, so compare the parts of an address, not its text.
func sameOrigin(_ url: URL, _ server: String) -> Bool {
    guard let s = URLComponents(string: server),
          let u = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = s.scheme?.lowercased(), scheme == u.scheme?.lowercased() else { return false }
    let standard = scheme == "https" ? 443 : 80
    return s.host?.lowercased() == u.host?.lowercased() && (s.port ?? standard) == (u.port ?? standard)
}

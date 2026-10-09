import Foundation
import UIKit

// MARK: - What the Marquee server sends

struct TVProfile: Codable, Identifiable, Hashable { let id: Int; let name: String; let color: String; let hasPin: Bool; let isKids: Bool? }
struct TVMe: Codable { let id: Int; let name: String; let color: String; let isKids: Bool?; let serverName: String? }

struct TVProgress: Codable, Hashable { let position: Double?; let watched: Bool?; let duration: Double? }
struct TVShowRef: Codable, Hashable { let id: Int; let title: String; let poster: String?; let backdrop: String? }

struct TVItem: Codable, Identifiable, Hashable {
    let id: Int
    let type: String
    let title: String
    let year: Int?
    let overview: String?
    let tagline: String?
    let poster: String?
    let backdrop: String?
    let still: String?
    let vote: Double?
    let certification: String?
    let genres: [String]?
    let runtime: Int?
    let duration: Double?
    let season: Int?
    let episode: Int?
    let progress: TVProgress?
    let show: TVShowRef?
    let episodeCount: Int?
    let unwatched: Int?

    var displayTitle: String { show?.title ?? title }
    var subtitle: String {
        if let s = season, let e = episode, show != nil { return "S\(s) · E\(e) · \(title)" }
        return [year.map(String.init), runtime.map { "\($0 / 60)h \($0 % 60)m" }].compactMap { $0 }.joined(separator: " · ")
    }
    var fraction: Double? {
        guard let p = progress, p.watched != true, let pos = p.position, pos > 30, let d = p.duration ?? duration, d > 0 else { return nil }
        return min(1, pos / d)
    }
    var resumeAt: Double? { fraction != nil ? progress?.position : nil }
    var wideImage: String? { still ?? backdrop ?? show?.backdrop ?? poster ?? show?.poster }
}

struct TVSeason: Codable, Hashable { let season: Int; let title: String; let episodes: [TVItem] }
struct TVDetail: Codable {
    let id: Int
    let type: String
    let title: String
    let year: Int?
    let overview: String?
    let tagline: String?
    let poster: String?
    let backdrop: String?
    let vote: Double?
    let certification: String?
    let genres: [String]?
    let runtime: Int?
    let duration: Double?
    let progress: TVProgress?
    let seasons: [TVSeason]?
    let nextEpisode: TVItem?
    let nextId: Int?
    let inList: Bool?
}
struct TVHome: Codable {
    let continueWatching: [TVItem]
    let nextUp: [TVItem]
    let myList: [TVItem]
    let recentMovies: [TVItem]
    let recentShows: [TVItem]
    let recentHome: [TVItem]?
    let allMovies: [TVItem]?
    let allShows: [TVItem]?
}
struct TVSearch: Codable { let movies: [TVItem]; let shows: [TVItem]; let episodes: [TVItem] }
struct TVPlay: Codable {
    let mode: String
    let url: String
    let start: Double?
    let resume: Double?
    let duration: Double?
    let sessionId: String?
    let title: String?
    let showTitle: String?
}
struct TVProgressReply: Codable { let stop: String? }
private struct TVError: Codable { let error: String }

// MARK: - Talking to the server (signed in with the normal Marquee cookie)

enum TVAPI {
    static var server: String? {
        get { UserDefaults.standard.string(forKey: "server_url") }
        set { UserDefaults.standard.set(newValue, forKey: "server_url") }
    }
    static let deviceId: String = {
        if let id = UserDefaults.standard.string(forKey: "device_id") { return id }
        let id = "appletv-" + UUID().uuidString.prefix(12).lowercased()
        UserDefaults.standard.set(id, forKey: "device_id")
        return id
    }()

    struct Failure: LocalizedError { let message: String; let status: Int; var errorDescription: String? { message } }

    static func url(_ path: String) -> URL? {
        guard let server else { return nil }
        return URL(string: path.hasPrefix("http") ? path : server + path)
    }

    static func call<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard let u = url(path) else { throw Failure(message: "Set up your server first", status: 0) }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Mozilla/5.0 (AppleTV) MarqueeTV/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpMethod = method == "GET" ? "POST" : method
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw Failure(message: (try? JSONDecoder().decode(TVError.self, from: data))?.error ?? "Marquee said no (\(code))", status: code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct OK: Codable { let ok: Bool? }
    static func send(_ path: String, _ body: [String: Any], method: String = "POST") async { _ = try? await call(path, method: method, body: body) as OK }

    static func checkServer(_ base: String) async -> Bool {
        guard let u = URL(string: base + "/api/status") else { return false }
        guard let result = try? await URLSession.shared.data(from: u), (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else { return false }
        return json["needsSetup"] != nil
    }

    static func normalise(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if !s.lowercased().hasPrefix("http") { s = (s.contains(".ts.net") ? "https://" : "http://") + s }
        guard var c = URLComponents(string: s), c.host != nil else { return s }
        if c.scheme == "http" && c.port == nil { c.port = 8420 }
        c.path = ""; c.query = nil; c.fragment = nil
        return c.string ?? s
    }

    static func cookies(for url: URL) -> [HTTPCookie] { HTTPCookieStorage.shared.cookies(for: url) ?? [] }
}

// MARK: - Artwork (loaded with the sign-in cookie, cached in memory)

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    func image(_ path: String?) async -> UIImage? {
        guard let path, let url = TVAPI.url(path) else { return nil }
        if let hit = cache.object(forKey: url.absoluteString as NSString) { return hit }
        guard let result = try? await URLSession.shared.data(from: url), let img = UIImage(data: result.0) else { return nil }
        cache.setObject(img, forKey: url.absoluteString as NSString)
        return img
    }
}

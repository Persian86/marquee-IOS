import UIKit
import UserNotifications

/// What the web app tells us about a download (sent as JSON from downloads.js).
struct DownloadMeta: Codable {
    var itemId: Int
    var title: String
    var showTitle: String?
    var showId: Int?
    var smart: Bool?
    var code: String?
    var quality: String?
    var poster: String?
    var duration: Double?

    var displayTitle: String {
        if let show = showTitle, !show.isEmpty { return [show, code].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        return title
    }
}

/// A movie or episode saved on this device.
struct DownloadedItem: Codable {
    var meta: DownloadMeta
    var file: String          // name inside Documents/Marquee Downloads
    var size: Int64
    var savedAt: Date
    var position: Double = 0  // where you got to, for resuming

    var itemId: Int { meta.itemId }
}

// MARK: - The list of what's saved

final class DownloadStore {
    static let shared = DownloadStore()
    static let changed = Notification.Name("MarqueeDownloadsChanged")

    /// Visible in the Files app under On My iPhone → Marquee → Marquee Downloads.
    let folder: URL
    private let indexURL: URL
    private let postersFolder: URL
    private(set) var items: [DownloadedItem] = []

    private init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Marquee Downloads", isDirectory: true)
        postersFolder = support.appendingPathComponent("Posters", isDirectory: true)
        indexURL = support.appendingPathComponent("downloads.json")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: postersFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([DownloadedItem].self, from: data) {
            // Forget anything deleted from the Files app
            items = list.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
        }
    }

    func url(for item: DownloadedItem) -> URL { folder.appendingPathComponent(item.file) }
    func posterURL(itemId: Int) -> URL { postersFolder.appendingPathComponent("\(itemId).jpg") }
    func item(_ itemId: Int) -> DownloadedItem? { items.first { $0.itemId == itemId } }

    func add(_ item: DownloadedItem) {
        items.removeAll { $0.itemId == item.itemId }
        items.append(item)
        save()
    }

    func remove(itemId: Int) {
        guard let item = item(itemId) else { return }
        try? FileManager.default.removeItem(at: url(for: item))
        try? FileManager.default.removeItem(at: posterURL(itemId: itemId))
        items.removeAll { $0.itemId == itemId }
        save()
    }

    func setPosition(itemId: Int, _ position: Double) {
        guard let i = items.firstIndex(where: { $0.itemId == itemId }) else { return }
        items[i].position = position
        save(notify: false)
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// What the web app needs to know (for "Downloaded" badges and smart downloads).
    var webSummaryJSON: String {
        let list: [[String: Any]] = items.map { i in
            var d: [String: Any] = ["itemId": i.itemId, "smart": i.meta.smart ?? false]
            if let s = i.meta.showId { d["showId"] = s }
            return d
        }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func save(notify: Bool = true) {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
        if notify { NotificationCenter.default.post(name: DownloadStore.changed, object: nil) }
    }

    /// A file name people will recognise in the Files app: "Bluey · S02E05 (720p).mp4"
    func fileName(for meta: DownloadMeta, suggested: String?) -> String {
        var base = meta.displayTitle
        if base.isEmpty { base = (suggested as NSString?)?.deletingPathExtension ?? "Video" }
        if let q = meta.quality, !q.isEmpty { base += " (\(q)p)" }
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        base = base.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        var name = base + ".mp4"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(n).mp4"; n += 1
        }
        return name
    }
}

// MARK: - Downloading (keeps going when you leave the app)

final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    struct Active {
        var meta: DownloadMeta
        var progress: Double
        var received: Int64
        var expected: Int64
    }

    /// In-progress downloads, by task id.
    private(set) var active: [Int: Active] = [:]
    var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.adam.marquee.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        // Pick up downloads that were running when the app was last closed
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for case let t as URLSessionDownloadTask in tasks {
                    guard let meta = Self.meta(of: t) else { continue }
                    self.active[t.taskIdentifier] = Active(meta: meta, progress: 0, received: t.countOfBytesReceived,
                                                           expected: t.countOfBytesExpectedToReceive)
                }
                self.changed()
            }
        }
    }

    func isDownloading(itemId: Int) -> Bool { active.values.contains { $0.meta.itemId == itemId } }

    func start(url: URL, meta: DownloadMeta) {
        guard !isDownloading(itemId: meta.itemId) else { return }
        WebCookies.sync {
            var req = URLRequest(url: url)
            if let cookie = WebCookies.header(for: url) { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let task = self.session.downloadTask(with: req)
            task.taskDescription = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
            self.active[task.taskIdentifier] = Active(meta: meta, progress: 0, received: 0, expected: 0)
            task.resume()
            self.changed()
            Notifier.requestPermission()
        }
    }

    func cancel(itemId: Int) {
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for t in tasks where Self.meta(of: t)?.itemId == itemId { t.cancel() }
                self.active = self.active.filter { $0.value.meta.itemId != itemId }
                self.changed()
            }
        }
    }

    private static func meta(of task: URLSessionTask) -> DownloadMeta? {
        guard let s = task.taskDescription, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DownloadMeta.self, from: data)
    }

    private func changed() {
        NotificationCenter.default.post(name: DownloadStore.changed, object: nil)
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard var a = active[downloadTask.taskIdentifier] ?? Self.meta(of: downloadTask).map({ Active(meta: $0, progress: 0, received: 0, expected: 0) }) else { return }
        let before = Int(a.progress * 100)
        a.received = totalBytesWritten
        a.expected = totalBytesExpectedToWrite
        a.progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        active[downloadTask.taskIdentifier] = a
        if Int(a.progress * 100) != before { changed() } // at most ~100 updates per download
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it now
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, var meta = Self.meta(of: downloadTask) else { return }
        let store = DownloadStore.shared
        if meta.title.isEmpty { meta.title = downloadTask.response?.suggestedFilename ?? "Video" }
        let name = store.fileName(for: meta, suggested: downloadTask.response?.suggestedFilename)
        let dest = store.folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            var dest2 = dest
            var values = URLResourceValues()
            values.isExcludedFromBackup = true // big video files shouldn't fill up iCloud backups
            try? dest2.setResourceValues(values)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            store.add(DownloadedItem(meta: meta, file: name, size: size, savedAt: Date()))
            fetchPoster(meta)
            announce(meta, ok: true)
        } catch {
            announce(meta, ok: false)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let meta = active[task.taskIdentifier]?.meta ?? Self.meta(of: task)
        active[task.taskIdentifier] = nil
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let cancelled = (error as? URLError)?.code == .cancelled
        if let meta = meta, !cancelled, error != nil || status != 200 { announce(meta, ok: false) }
        changed()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = backgroundCompletion
        backgroundCompletion = nil
        done?()
    }

    // MARK: Helpers

    private func fetchPoster(_ meta: DownloadMeta) {
        guard let p = meta.poster, !p.isEmpty,
              let url = p.hasPrefix("http") ? URL(string: p) : Prefs.server.flatMap({ URL(string: $0 + p) }) else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        if let cookie = WebCookies.header(for: url) { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data, let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
            try? jpeg.write(to: DownloadStore.shared.posterURL(itemId: meta.itemId))
            DispatchQueue.main.async { NotificationCenter.default.post(name: DownloadStore.changed, object: nil) }
        }.resume()
    }

    private func announce(_ meta: DownloadMeta, ok: Bool) {
        // A notification only when you're not looking at the app (the app shows its own message otherwise)
        guard UIApplication.shared.applicationState != .active else {
            NotificationCenter.default.post(name: DownloadManager.finished, object: nil,
                                            userInfo: ["title": meta.displayTitle, "ok": ok])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = ok ? "Ready to watch offline" : "Download didn't finish"
        content.body = ok ? meta.displayTitle : "\(meta.displayTitle) — open Marquee to try again."
        content.userInfo = ["downloads": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dl-\(meta.itemId)", content: content, trigger: nil))
    }

    static let finished = Notification.Name("MarqueeDownloadFinished")
}

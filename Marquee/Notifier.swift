import UIKit
import BackgroundTasks
import UserNotifications

/// "New on Marquee" notifications.
/// iOS lets the app check the server every so often in the background (how often is up to iOS —
/// it learns when you usually use the app). The app also checks whenever you open it.
enum Notifier {
    static let taskId = "com.adam.marquee.refresh"
    private static var checking = false

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            schedule() // line up the next one
            var finished = false
            task.expirationHandler = {
                DispatchQueue.main.async { if !finished { finished = true; task.setTaskCompleted(success: false) } }
            }
            check {
                DispatchQueue.main.async {
                    if !finished { finished = true; task.setTaskCompleted(success: true) }
                }
            }
        }
    }

    static func schedule() {
        guard Prefs.server != nil else { return }
        let req = BGAppRefreshTaskRequest(identifier: taskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func checkNow() {
        WebCookies.sync { check(nil) }
    }

    /// Asks the server for its latest "New on Marquee" messages and shows any we haven't shown yet.
    static func check(_ done: (() -> Void)?) {
        DispatchQueue.main.async {
            guard !checking, Prefs.server != nil else { done?(); return }
            checking = true
            // Home address or away address, whichever answers from where the phone is now
            WebCookies.fetch("/api/notifications") { data, response in
                defer { DispatchQueue.main.async { checking = false; done?() } }
                guard response?.statusCode == 200, let data = data,
                      let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
                DispatchQueue.main.async { show(list) }
            }
        }
    }

    private static func show(_ list: [[String: Any]]) {
        let last = Prefs.lastNoteId
        let fresh = list.compactMap { n -> (Int, [String: Any])? in
            guard let id = (n["id"] as? NSNumber)?.intValue, id > last else { return nil }
            return (id, n)
        }.sorted { $0.0 < $1.0 }
        guard let newest = fresh.last?.0 else { return }
        Prefs.lastNoteId = newest
        // The very first check just notes where things are, rather than replaying old news
        guard last > 0 else { return }

        for (id, n) in fresh.suffix(5) {
            let content = UNMutableNotificationContent()
            content.title = (n["title"] as? String) ?? "New on Marquee"
            content.body = (n["body"] as? String) ?? ""
            content.sound = .default
            content.threadIdentifier = "new-arrivals"
            var open = "#/notifications"
            if let items = n["items"] as? [[String: Any]], items.count == 1, let itemId = (items[0]["id"] as? NSNumber)?.intValue {
                open = "#/item/\(itemId)"
            }
            content.userInfo = ["open": open]
            attachImage(n["image"] as? String, to: content) { c in
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "note-\(id)", content: c, trigger: nil))
            }
        }
    }

    /// Adds the poster to the notification when we can fetch it quickly.
    private static func attachImage(_ path: String?, to content: UNMutableNotificationContent,
                                    then: @escaping (UNNotificationContent) -> Void) {
        guard let path = path, !path.isEmpty, let server = Prefs.server,
              let url = URL(string: path.hasPrefix("http") ? path : server + path) else { return then(content) }
        var req = URLRequest(url: url, timeoutInterval: 8)
        if let cookie = WebCookies.header(for: url) { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        URLSession.shared.downloadTask(with: req) { file, response, _ in
            if let file = file, (response as? HTTPURLResponse)?.statusCode == 200 {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                if (try? FileManager.default.moveItem(at: file, to: dest)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "poster", url: dest) {
                    content.attachments = [attachment]
                }
            }
            then(content)
        }.resume()
    }
}

import SwiftUI
import WebKit
import UserNotifications

/// The Marquee web app inside the window.
struct WebView: NSViewRepresentable {
    let server: String
    let model: AppModel

    func makeCoordinator() -> WebCoordinator { WebCoordinator(server: server, model: model) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    private let server: String
    private let model: AppModel
    private var savedFiles: [ObjectIdentifier: URL] = [:]

    init(server: String, model: AppModel) {
        self.server = server
        self.model = model
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.applicationNameForUserAgent = "MarqueeApp/\(appVersion) MarqueeMac"
        config.preferences.isElementFullscreenEnabled = true // the player's full-screen button

        // window.MarqueeNative — the same hooks the phone apps offer, so the web app works with all of them
        let bridge = """
        (function () {
          var post = function (m) { window.webkit.messageHandlers.marquee.postMessage(m); };
          window.MarqueeNative = {
            platform: 'mac',
            playing: function (on) { post({ cmd: 'playing', on: !!on }); },
            playerClosed: function () { post({ cmd: 'playerClosed' }); },
            isTv: function () { return false; },
            version: function () { return \(jsString(appVersion)); },
            server: function () { return location.origin; },
            openAppSettings: function () { post({ cmd: 'openAppSettings' }); },
            checkNotificationsNow: function () { post({ cmd: 'checkNotificationsNow' }); }
          };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(WeakMessageHandler(self), name: "marquee")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = false
        web.setValue(false, forKey: "drawsBackground") // no white flash before the dark page appears
        #if DEBUG
        if #available(macOS 13.3, *) { web.isInspectable = true }
        #endif
        model.webView = web
        if let url = URL(string: server + "/" + model.startHash) { web.load(URLRequest(url: url)) }
        return web
    }

    // MARK: Messages from the web app

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "playing": model.keepAwake((body["on"] as? Bool) ?? false)
        case "playerClosed": model.keepAwake(false)
        case "openAppSettings": model.showSetup = true
        case "checkNotificationsNow": MacNotifier.checkNow()
        default: break
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if navigationAction.shouldPerformDownload { return decisionHandler(.download) }
        // Trailers (YouTube) and other embedded frames load in place
        if !isMainFrame || ["about", "blob", "data", "javascript"].contains(scheme) { return decisionHandler(.allow) }
        if Addresses.isOurs(url, current: server) { return decisionHandler(.allow) }
        // TMDB, Trakt, IMDb, help pages… open in your normal browser
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.lowercased().hasPrefix("attachment")
        decisionHandler(navigationResponse.canShowMIMEType && !attachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        model.pageLoaded()
        model.startNotifications()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return } // "frame load interrupted" = became a download
        model.pageFailed()
    }

    /// macOS sometimes closes the web view's engine to save memory — just reload.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { model.reload() }

    // MARK: Pop-ups (alert / confirm / prompt), file pickers and new windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Addresses.isOurs(url, current: server) { webView.load(navigationAction.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Marquee"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Marquee"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// Choosing a profile photo or poster to upload
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    // MARK: Downloads → your Downloads folder

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = suggestedFilename.isEmpty ? "Marquee download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var dest = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        savedFiles[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = savedFiles.removeValue(forKey: ObjectIdentifier(download)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file]) // show it in Finder
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        savedFiles.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// Stops the web view keeping the coordinator alive forever (WebKit holds its message handlers strongly).
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - "New on Marquee" notifications

/// While the app is open it asks the server every so often for new arrivals and shows them as Mac notifications.
enum MacNotifier {
    @MainActor static func checkNow() {
        guard let server = AppModel.shared.server, let url = URL(string: server + "/api/notifications") else { return }
        // The web app signs in with a cookie; borrow it so this check is signed in as the same profile
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let host = url.host ?? ""
            let mine = cookies.filter { c in
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                return host == d || host.hasSuffix("." + d)
            }
            fetch(url: url, cookie: HTTPCookie.requestHeaderFields(with: mine)["Cookie"])
        }
    }

    private static func fetch(url: URL, cookie: String?) {
        guard let cookie = cookie else { return } // not signed in yet
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpShouldHandleCookies = false
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            show(list)
        }.resume()
    }

    private static func show(_ list: [[String: Any]]) {
        let defaults = UserDefaults.standard
        let last = defaults.integer(forKey: "last_note_id")
        let fresh = list.compactMap { n -> (Int, [String: Any])? in
            guard let id = (n["id"] as? NSNumber)?.intValue, id > last else { return nil }
            return (id, n)
        }.sorted { $0.0 < $1.0 }
        guard let newest = fresh.last?.0 else { return }
        defaults.set(newest, forKey: "last_note_id")
        // The very first check just notes where things are, rather than replaying old news
        guard last > 0 else { return }

        for (id, n) in fresh.suffix(5) {
            let content = UNMutableNotificationContent()
            content.title = (n["title"] as? String) ?? "New on Marquee"
            content.body = (n["body"] as? String) ?? ""
            content.sound = .default
            var open = "#/notifications"
            if let items = n["items"] as? [[String: Any]], items.count == 1, let itemId = (items[0]["id"] as? NSNumber)?.intValue {
                open = "#/item/\(itemId)"
            }
            content.userInfo = ["open": open]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "note-\(id)", content: content, trigger: nil))
        }
    }
}

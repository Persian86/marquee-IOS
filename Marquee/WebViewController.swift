import UIKit
import WebKit
import Network

/// Marquee itself: your server's web app, full screen, plus the native extras.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {

    /// The address in use right now — your home one or your away one, whichever answers.
    private var server: String
    private var connecting = false
    private var playing = false
    private var lastTarget = ""
    private var lastCheck = Date.distantPast
    private var lastAutoRetry = Date.distantPast
    private let offlineBody = UILabel()
    private let network = NWPathMonitor()
    private var networkSettling: DispatchWorkItem?
    private var web: WKWebView!
    private let splash = UIView()
    private let offline = UIView()
    private let offlineDownloads = UIButton.marquee("Watch your downloads", primary: false)
    private let toast = UILabel()
    private var loadedOnce = false
    private var onPlayerScreen = false
    private var savedFiles: [ObjectIdentifier: URL] = [:]   // Letterboxd exports, backups… to share

    init() {
        server = Prefs.server ?? ""
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .mqBackground
        setupWebView()
        setupSplash()
        setupOffline()
        setupToast()

        NotificationCenter.default.addObserver(self, selector: #selector(routeRequested), name: Router.openNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(downloadsRequested), name: Router.downloadsNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(downloadsChanged), name: DownloadStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(downloadFinished(_:)), name: DownloadManager.finished, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        connect(Router.take())

        // Wi-Fi ↔ mobile data (walking out the door, arriving home): check straight away whether to switch address
        network.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.networkChanged() }
        }
        network.start(queue: DispatchQueue.global(qos: .utility))
    }

    deinit { network.cancel() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if Router.takeDownloads() { openDownloads() }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Mobile/15E148 MarqueeApp/\(appVersion) MarqueeiOS"
        if #available(iOS 15.4, *) { config.preferences.isElementFullscreenEnabled = true }

        // window.MarqueeNative — the same hooks the Android app offers, so the web app works with both
        let bridge = """
        (function () {
          var post = function (m) { window.webkit.messageHandlers.marquee.postMessage(m); };
          window.MarqueeNative = {
            platform: 'ios',
            _items: \(DownloadStore.shared.webSummaryJSON),
            playing: function (on) { post({ cmd: 'playing', on: !!on }); },
            playerClosed: function () { post({ cmd: 'playerClosed' }); },
            isTv: function () { return false; },
            version: function () { return \(jsString(appVersion)); },
            server: function () { return location.origin; },
            openAppSettings: function () { post({ cmd: 'openAppSettings' }); },
            checkNotificationsNow: function () { post({ cmd: 'checkNotificationsNow' }); },
            download: function (url, meta) { post({ cmd: 'download', url: String(url), meta: String(meta || '{}') }); },
            removeDownload: function (id) { post({ cmd: 'removeDownload', id: Number(id) }); },
            openDownloads: function () { post({ cmd: 'openDownloads' }); },
            profileChanged: function () { post({ cmd: 'profileChanged' }); }
          };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(WeakMessageHandler(self), name: "marquee")

        web = WKWebView(frame: view.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .mqBackground
        web.scrollView.backgroundColor = .mqBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never // the web app handles the notch and home bar itself
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = false
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupSplash() {
        splash.backgroundColor = .mqBackground
        let logo = UIImageView(image: UIImage(named: "Logo"))
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .mqMuted
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [logo, spinner])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        splash.addSubview(stack)
        fill(splash)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: splash.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: splash.centerYAnchor),
        ])
    }

    private func setupOffline() {
        offline.backgroundColor = .mqBackground
        offline.isHidden = true
        let icon = UIImageView(image: UIImage(systemName: "wifi.exclamationmark"))
        icon.tintColor = .mqAccent
        icon.preferredSymbolConfiguration = .init(pointSize: 44, weight: .semibold)
        let title = UILabel()
        title.text = "Can't reach Marquee"
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = .mqText
        let body = offlineBody
        body.numberOfLines = 0
        body.textAlignment = .center
        body.font = .systemFont(ofSize: 16)
        body.textColor = .mqMuted
        let retry = UIButton.marquee("Try again", primary: true)
        retry.addAction(UIAction { [weak self] _ in self?.connect(patient: true) }, for: .touchUpInside)
        let tailscale = UIButton.marquee("Open Tailscale", primary: false)
        tailscale.addAction(UIAction { [weak self] _ in if let me = self { Tailscale.open(from: me) } }, for: .touchUpInside)
        offlineDownloads.addAction(UIAction { [weak self] _ in self?.openDownloads() }, for: .touchUpInside)
        let change = UIButton.marquee("Change addresses", primary: false)
        change.addAction(UIAction { [weak self] _ in self?.openSetup() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, title, body, retry, tailscale, offlineDownloads, change])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.setCustomSpacing(24, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        offline.addSubview(stack)
        fill(offline)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: offline.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: offline.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 320),
        ])
        icon.contentMode = .center
        title.textAlignment = .center
    }

    private func setupToast() {
        toast.backgroundColor = .mqPanel2
        toast.textColor = .mqText
        toast.font = .systemFont(ofSize: 15, weight: .medium)
        toast.textAlignment = .center
        toast.numberOfLines = 2
        toast.layer.cornerRadius = 12
        toast.clipsToBounds = true
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            toast.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func fill(_ v: UIView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func showToast(_ text: String) {
        toast.text = "   \(text)   "
        view.bringSubviewToFront(toast)
        UIView.animate(withDuration: 0.2) { self.toast.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 3, options: []) { self.toast.alpha = 0 }
    }

    // MARK: - Loading

    /// Works out which address reaches the server right now — home on your Wi-Fi, away (Tailscale) everywhere
    /// else — then opens the app there, on the page you were on.
    private func connect(_ hash: String? = nil, patient: Bool = false) {
        lastTarget = hash ?? currentHash()
        guard !connecting else { return } // the search already under way will open lastTarget
        connecting = true
        offline.isHidden = true
        showSplash()
        let before = server
        Task { @MainActor [weak self] in
            let found = await Servers.pick(patient: patient)
            guard let self = self else { return }
            guard let url = found else {
                self.connecting = false
                self.showOffline()
                return
            }
            await Servers.copyLogin(from: before, to: url) // stay signed in when switching between home and away
            Prefs.publish()
            self.connecting = false
            self.server = url
            self.go(self.lastTarget)
        }
    }

    private func go(_ hash: String) {
        lastTarget = hash
        offline.isHidden = true
        guard let url = URL(string: server + "/" + hash) else { return }
        web.load(URLRequest(url: url))
        // Going to another part of the page already showing isn't a "load", so nothing would hide the splash
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.loadedOnce, !self.web.isLoading, !self.connecting, self.offline.isHidden else { return }
            self.hideSplash()
        }
    }

    private func showSplash() {
        splash.alpha = 1
        splash.isHidden = false
    }

    private func hideSplash() {
        guard !splash.isHidden else { return }
        UIView.animate(withDuration: 0.25, animations: { self.splash.alpha = 0 }) { _ in
            self.splash.isHidden = true
            self.splash.alpha = 1
        }
    }

    /// "#/item/4": the page being shown, whichever address it came from.
    private func currentHash() -> String {
        guard let url = web.url, Addresses.isOurs(url, current: server) else { return lastTarget }
        return url.fragment.map { "#" + $0 } ?? ""
    }

    /// Back in the app.
    @objc private func becameActive() { recheck(force: false) }

    private func networkChanged() {
        guard loadedOnce || !offline.isHidden else { return }
        networkSettling?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recheck(force: true) }
        networkSettling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work) // give the new network (and Tailscale) a moment
    }

    /// If it couldn't connect before, try again by itself (you've probably just switched Tailscale or Wi-Fi on).
    /// If you've moved between home and away and the address in use has stopped answering, switch to the other
    /// one and stay on the same page.
    private func recheck(force: Bool) {
        let now = Date()
        if !offline.isHidden {
            if !connecting && now.timeIntervalSince(lastCheck) > 3 {
                lastCheck = now
                connect()
            }
            return
        }
        guard loadedOnce, !connecting, !playing, force || now.timeIntervalSince(lastCheck) > 20 else { return }
        lastCheck = now
        let using = server
        Task { @MainActor [weak self] in
            if await Servers.probe(using, timeout: 3) != nil { return }
            // Not answering. Patiently look at both addresses (a busy server can be slow) before deciding anything
            let other = await Servers.pick(patient: true)
            guard let self = self else { return }
            Prefs.publish()
            guard other != using, self.server == using, !self.connecting, !self.playing else { return }
            guard let next = other else {
                self.connect() // nothing answers (left home with Tailscale off?): say so, and offer Tailscale
                return
            }
            let page = self.currentHash()
            await Servers.copyLogin(from: using, to: next)
            self.server = next
            self.showSplash()
            self.go(page)
        }
    }

    private func showOffline() {
        // Be honest about what was tried: a brand-new install may not know the away address yet
        offlineBody.text = Addresses.away == nil
            ? "Your home address didn't answer, and this app doesn't know your away-from-home (Tailscale) address yet.\n\nIt learns it the first time it connects on your home Wi-Fi — or tap Change addresses and type it in."
            : "Marquee tried your home address and your away address, and neither answered.\n\nAway from home? Switch Tailscale on and come back — Marquee reconnects by itself."
        splash.isHidden = true
        offlineDownloads.isHidden = DownloadStore.shared.items.isEmpty
        offline.isHidden = false
        view.bringSubviewToFront(offline)
    }

    @objc private func routeRequested() {
        guard let hash = Router.take() else { return }
        if loadedOnce && offline.isHidden && !connecting {
            web.evaluateJavaScript("location.hash = \(jsString(hash.hasPrefix("#") ? String(hash.dropFirst()) : hash))")
        } else {
            connect(hash)
        }
    }

    @objc private func downloadsRequested() {
        if Router.takeDownloads() { openDownloads() }
    }

    @objc private func downloadsChanged() {
        web.evaluateJavaScript("window.MarqueeNative && (MarqueeNative._items = \(DownloadStore.shared.webSummaryJSON))")
    }

    @objc private func downloadFinished(_ note: Notification) {
        guard let title = note.userInfo?["title"] as? String else { return }
        let ok = (note.userInfo?["ok"] as? Bool) ?? false
        showToast(ok ? "\(title) is ready to watch offline" : "\(title) didn't finish downloading")
    }

    // MARK: - Screens

    func openSetup() {
        let setup = SetupViewController()
        setup.modalPresentationStyle = .formSheet
        topMost.present(setup, animated: true)
    }

    func openDownloads() {
        if topMost is UINavigationController, (topMost as? UINavigationController)?.viewControllers.first is DownloadsViewController { return }
        let nav = UINavigationController(rootViewController: DownloadsViewController())
        nav.modalPresentationStyle = .pageSheet
        topMost.present(nav, animated: true)
    }

    // Full-screen look while a video plays
    override var prefersStatusBarHidden: Bool { onPlayerScreen }
    override var prefersHomeIndicatorAutoHidden: Bool { onPlayerScreen }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func setPlayerScreen(_ on: Bool) {
        guard on != onPlayerScreen else { return }
        onPlayerScreen = on
        UIView.animate(withDuration: 0.25) {
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    // MARK: - Messages from the web app

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "playing":
            let on = (body["on"] as? Bool) ?? false
            playing = on
            UIApplication.shared.isIdleTimerDisabled = on // keep the screen on while watching
            setPlayerScreen(true)
        case "playerClosed":
            playing = false
            recheck(force: false) // if you moved between home and away while watching, switch address now
            UIApplication.shared.isIdleTimerDisabled = false
            setPlayerScreen(false)
        case "openAppSettings":
            openSetup()
        case "checkNotificationsNow":
            Notifier.checkNow()
        case "download":
            guard let s = body["url"] as? String, let url = URL(string: s) else { return }
            DownloadManager.shared.start(url: url, meta: Self.meta(from: body["meta"] as? String, url: url))
        case "removeDownload":
            if let id = (body["id"] as? NSNumber)?.intValue {
                DownloadManager.shared.cancel(itemId: id)
                DownloadStore.shared.remove(itemId: id)
            }
        case "openDownloads":
            openDownloads()
        case "profileChanged":
            // Widgets and Siri now follow the newly picked profile
            SharedStore.deviceKey = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DeviceKey.ensure() }
        default:
            break
        }
    }

    private static func meta(from json: String?, url: URL) -> DownloadMeta {
        let d = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func str(_ k: String) -> String? {
            if let s = d[k] as? String { return s }
            if let n = d[k] as? NSNumber { return n.stringValue }
            return nil
        }
        // No item id (an old "Save file" link)? Use the version id from the address so it's still unique
        let fallbackId = -(Int(url.deletingLastPathComponent().lastPathComponent) ?? Int.random(in: 1...999_999))
        return DownloadMeta(
            itemId: (d["itemId"] as? NSNumber)?.intValue ?? fallbackId,
            title: str("title") ?? "",
            showTitle: str("showTitle"),
            showId: (d["showId"] as? NSNumber)?.intValue,
            smart: d["smart"] as? Bool,
            code: str("code"),
            quality: str("quality"),
            poster: str("poster"),
            duration: (d["duration"] as? NSNumber)?.doubleValue)
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        // Trailers (YouTube) and other embedded frames load in place
        if !isMainFrame || ["about", "blob", "data", "javascript"].contains(scheme) { return decisionHandler(.allow) }

        if Addresses.isOurs(url, current: server) {
            if navigationAction.shouldPerformDownload {
                // A prepared movie copy → the app's own downloads; anything else (exports, backups) → share sheet
                if url.path.hasPrefix("/api/versions/") {
                    DownloadManager.shared.start(url: url, meta: Self.meta(from: nil, url: url))
                    showToast("Downloading — see Downloads")
                    return decisionHandler(.cancel)
                }
                return decisionHandler(.download)
            }
            return decisionHandler(.allow)
        }
        // TMDB, Trakt, IMDb, help pages… open in Safari (or the matching app)
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = ((navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "")
            .lowercased().hasPrefix("attachment")
        decisionHandler(navigationResponse.canShowMIMEType && !attachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedOnce = true
        offline.isHidden = true
        hideSplash()
        downloadsChanged()
        WebCookies.sync()
        DeviceKey.ensure()
        if !Self.askedForNotifications {
            Self.askedForNotifications = true
            Notifier.requestPermission()
            Notifier.schedule()
            OfflineProgress.flush()
        }
    }
    private static var askedForNotifications = false

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return } // "frame load interrupted" = became a download
        if connecting { return }
        // Maybe you just left the house (or came home): look for the other address once before giving up
        if Date().timeIntervalSince(lastAutoRetry) > 15 {
            lastAutoRetry = Date()
            connect()
        } else {
            showOffline()
        }
    }

    /// iOS sometimes closes the web view's engine in the background to save memory — just reload.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        connect()
    }

    // MARK: - Pop-ups (alert / confirm / prompt) and new windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Addresses.isOurs(url, current: server) { webView.load(navigationAction.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        topMost.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        topMost.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { [unowned a] _ in completionHandler(a.textFields?.first?.text ?? "") })
        topMost.present(a, animated: true)
    }

    // MARK: - Small file downloads (Letterboxd export, backups): save, then offer the share sheet

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(suggestedFilename.isEmpty ? "Marquee download" : suggestedFilename)
        savedFiles[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = savedFiles.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        share.popoverPresentationController?.permittedArrowDirections = []
        topMost.present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        savedFiles.removeValue(forKey: ObjectIdentifier(download))
        showToast("Download failed")
    }
}

/// Stops the web view keeping this screen alive forever (WebKit holds its message handlers strongly).
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Tailscale is the separate (free) app that lets this device reach home from anywhere.
/// iOS doesn't let one app switch another app's VPN on, so the best Marquee can do is take you there —
/// or, better, Tailscale can switch itself on: Tailscale → your picture → VPN On Demand.
enum Tailscale {
    static func open(from vc: UIViewController) {
        guard let app = URL(string: "tailscale://") else { return }
        UIApplication.shared.open(app, options: [:]) { opened in
            if opened { return }
            let a = UIAlertController(
                title: "Switch on Tailscale",
                message: "Open the Tailscale app, switch it on, then come back here — Marquee reconnects by itself.\n\nTip: in Tailscale, tap your picture → VPN On Demand, and it switches itself on whenever you leave your Wi-Fi.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Get Tailscale", style: .default) { _ in
                if let store = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") { UIApplication.shared.open(store) }
            })
            a.addAction(UIAlertAction(title: "OK", style: .cancel))
            vc.topMost.present(a, animated: true)
        }
    }
}

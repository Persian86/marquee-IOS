import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .mqBackground
        window.tintColor = .mqAccent
        window.overrideUserInterfaceStyle = .dark
        self.window = window
        Prefs.publish()
        showMain()
        window.makeKeyAndVisible()
        if let url = connectionOptions.urlContexts.first?.url { handle(url) }
    }

    /// Marquee itself. The server's addresses are built into the app, so the "where's your server?" screen
    /// only appears if there are none.
    func showMain() {
        window?.rootViewController = Prefs.server == nil ? SetupViewController() : WebViewController()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { handle(url) }
    }

    /// marquee://item/42 → #/item/42,  marquee://downloads → the app's downloads
    private func handle(_ url: URL) { Router.openURL(url) }

    func sceneDidEnterBackground(_ scene: UIScene) {
        WebCookies.sync()
        reloadWidgets()
        Notifier.schedule()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        Notifier.checkNow()
        OfflineProgress.flush()
    }
}

/// Lets notifications, links and the web app ask for a particular screen, even before Marquee has loaded.
enum Router {
    static let openNotification = Notification.Name("MarqueeOpen")
    static let downloadsNotification = Notification.Name("MarqueeOpenDownloads")
    private(set) static var pending: String?
    private(set) static var pendingDownloads = false

    static func open(_ hash: String) {
        pending = hash
        NotificationCenter.default.post(name: openNotification, object: nil)
    }
    static func openDownloads() {
        pendingDownloads = true
        NotificationCenter.default.post(name: downloadsNotification, object: nil)
    }
    /// marquee://item/42 → #/item/42,  marquee://downloads → the app's downloads
    static func openURL(_ url: URL) {
        guard url.scheme?.lowercased() == "marquee" else { return }
        let host = url.host ?? ""
        if host == "downloads" { openDownloads(); return }
        open("#/" + host + url.path)
    }
    static func take() -> String? { defer { pending = nil }; return pending }
    static func takeDownloads() -> Bool { defer { pendingDownloads = false }; return pendingDownloads }
}

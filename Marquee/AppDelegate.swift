import UIKit
import AVFoundation
import UserNotifications

/// Marquee for iPhone and iPad.
/// The app shows your Marquee server's web app full-screen and adds what a browser tab can't:
/// downloads that keep going in the background and play with no internet, new-arrival notifications,
/// background music, picture-in-picture and AirPlay.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // "Playback" lets music and podcasts carry on with the screen locked, and allows picture-in-picture
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        UNUserNotificationCenter.current().delegate = self
        Notifier.register()
        _ = DownloadManager.shared // reconnects to downloads that were running when the app was closed
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// iOS wakes the app when background downloads finish.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletion = completionHandler
    }

    // Show "New on Marquee" banners even while the app is open
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Tapping a notification opens the movie / episode it's about
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if info["downloads"] as? Bool == true {
            Router.openDownloads()
        } else {
            Router.open((info["open"] as? String) ?? "#/notifications")
        }
        completionHandler()
    }
}

import UIKit
import AVKit

/// Movies and episodes saved on this device. Works with no internet at all.
final class DownloadsViewController: UITableViewController {

    private var downloading: [DownloadManager.Active] = []
    private var saved: [DownloadedItem] = []

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.overrideUserInterfaceStyle = .dark
        tableView.backgroundColor = .mqBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: DownloadStore.changed, object: nil)
        reload()
    }

    @objc private func reload() {
        downloading = DownloadManager.shared.active.values.sorted { $0.meta.displayTitle < $1.meta.displayTitle }
        saved = DownloadStore.shared.items.sorted { $0.savedAt > $1.savedAt }
        tableView.reloadData()
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? downloading.count : max(saved.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return downloading.isEmpty ? nil : "Downloading" }
        return "On this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        if saved.isEmpty { return "In Marquee, tap ⋯ on a movie or ↓ next to an episode to download it. Downloads keep going if you leave the app." }
        return "\(formatBytes(DownloadStore.shared.totalSize)) used. Swipe left to delete. These files are also in the Files app → On My \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") → Marquee."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var c = UIListContentConfiguration.subtitleCell()
        c.textProperties.color = .mqText
        c.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
        c.secondaryTextProperties.color = .mqMuted
        c.secondaryTextProperties.numberOfLines = 2
        c.imageProperties.maximumSize = CGSize(width: 54, height: 80)
        c.imageProperties.reservedLayoutSize = CGSize(width: 54, height: 80)
        c.imageProperties.cornerRadius = 6
        cell.backgroundColor = .mqPanel
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default

        if indexPath.section == 0 {
            let a = downloading[indexPath.row]
            c.text = a.meta.displayTitle
            c.secondaryText = a.expected > 0
                ? "\(Int(a.progress * 100))% · \(formatBytes(a.received)) of \(formatBytes(a.expected))"
                : "Starting…"
            c.image = UIImage(systemName: "arrow.down.circle")
            c.imageProperties.tintColor = .mqAccent
            cell.selectionStyle = .none
        } else if saved.isEmpty {
            c.text = "Nothing downloaded yet"
            c.secondaryText = nil
            c.image = UIImage(systemName: "film")
            c.imageProperties.tintColor = .mqMuted
            cell.selectionStyle = .none
        } else {
            let item = saved[indexPath.row]
            c.text = item.meta.showTitle ?? item.meta.title
            var bits: [String] = []
            if item.meta.showTitle != nil { bits.append([item.meta.code, item.meta.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) }
            if let q = item.meta.quality, !q.isEmpty { bits.append("\(q)p") }
            bits.append(formatBytes(item.size))
            if item.position > 30, let d = item.meta.duration, d > 0 { bits.append("\(Int(item.position / d * 100))% watched") }
            c.secondaryText = bits.joined(separator: " · ")
            if let img = UIImage(contentsOfFile: DownloadStore.shared.posterURL(itemId: item.itemId).path) {
                c.image = img
            } else {
                c.image = UIImage(systemName: "film")
                c.imageProperties.tintColor = .mqMuted
            }
            let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
            play.tintColor = .mqAccent
            play.preferredSymbolConfiguration = .init(pointSize: 28)
            cell.accessoryView = play
        }
        cell.contentConfiguration = c
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, !saved.isEmpty else { return }
        OfflinePlayer.play(saved[indexPath.row], from: self)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if indexPath.section == 0 {
            let a = downloading[indexPath.row]
            return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: "Cancel") { _, _, done in
                DownloadManager.shared.cancel(itemId: a.meta.itemId); done(true)
            }])
        }
        guard !saved.isEmpty else { return nil }
        let item = saved[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            DownloadStore.shared.remove(itemId: item.itemId); done(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - Playing a download

/// Plays a saved file with Apple's own player (AirPlay, picture-in-picture, lock-screen controls included)
/// and remembers where you stopped — on this device, and on the server when there's internet.
final class OfflinePlayer: NSObject, AVPlayerViewControllerDelegate {
    private static var current: OfflinePlayer?

    private let item: DownloadedItem
    private let controller = PlayerController()
    private let player: AVPlayer
    private var timeObserver: Any?
    private var reportedEnd = false
    private var stopped = false
    private weak var presenter: UIViewController?

    private init(item: DownloadedItem) {
        self.item = item
        player = AVPlayer(url: DownloadStore.shared.url(for: item))
        super.init()
    }

    static func play(_ item: DownloadedItem, from presenter: UIViewController) {
        current?.stop()
        let p = OfflinePlayer(item: item)
        current = p
        p.presenter = presenter
        p.start()
    }

    private func start() {
        controller.player = player
        controller.delegate = self
        controller.onClose = { [weak self] in
            guard let self = self, !self.inPictureInPicture else { return }
            self.finish()
        }
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.exitsFullScreenWhenPlaybackEnds = true
        controller.modalPresentationStyle = .fullScreen

        let resume = item.position
        let duration = item.meta.duration ?? 0
        if resume > 30 && (duration == 0 || resume < duration * 0.92) {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] t in
            guard let self = self, t.seconds > 0 else { return }
            DownloadStore.shared.setPosition(itemId: self.item.itemId, t.seconds)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(ended), name: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem)
        presenter?.topMost.present(controller, animated: true) { self.player.play() }
    }

    @objc private func ended() {
        reportedEnd = true
        report(finished: true)
    }

    private func finish() {
        stop()
        if OfflinePlayer.current === self { OfflinePlayer.current = nil }
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        if !reportedEnd { report(finished: false) }
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        NotificationCenter.default.removeObserver(self)
    }

    private func report(finished: Bool) {
        let duration = item.meta.duration ?? player.currentItem?.duration.seconds ?? 0
        let pos = finished ? duration : player.currentTime().seconds
        guard pos.isFinite, pos > 5 else { return }
        DownloadStore.shared.setPosition(itemId: item.itemId, finished ? 0 : pos)
        OfflineProgress.send(itemId: item.itemId, position: pos, duration: duration.isFinite ? duration : 0)
    }

    // Closing the player (not just shrinking it into picture-in-picture)
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
            guard let self = self, !ctx.isCancelled, !self.inPictureInPicture else { return }
            self.finish()
        }
    }

    private var inPictureInPicture = false

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { inPictureInPicture = true }
    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = false
        // Closed from the little window rather than going back to full screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, playerViewController.presentingViewController == nil else { return }
            self.finish()
        }
    }
    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { true }

    /// Tapping "back to full screen" on the little picture-in-picture window
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
            return completionHandler(false)
        }
        let top = root.topMost
        if top === playerViewController { return completionHandler(true) }
        top.present(playerViewController, animated: true) { completionHandler(true) }
    }
}

/// Apple's player, plus a heads-up when it's closed.
final class PlayerController: AVPlayerViewController {
    var onClose: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onClose?() }
    }
}

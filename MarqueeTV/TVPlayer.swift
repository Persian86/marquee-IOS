import SwiftUI
import AVKit

/// Plays something with Apple's own player. Remembers where you got to, plays the next episode,
/// and respects kids' screen-time limits (the server says when to stop).
struct TVPlayerScreen: View {
    let itemId: Int
    let resume: Double?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TVPlayerModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                TVPlayerView(player: player, title: model.title).ignoresSafeArea()
            } else if let error = model.error {
                VStack(spacing: 30) {
                    Image(systemName: model.blocked ? "moon.stars.fill" : "exclamationmark.triangle").font(.system(size: 70)).foregroundColor(tvGold)
                    Text(error).font(.title2).multilineTextAlignment(.center).frame(maxWidth: 1200)
                    Button("OK") { dismiss() }
                }
            } else { ProgressView().tint(tvGold) }
        }
        .toolbar(.hidden, for: .tabBar)
        .task { await model.start(itemId: itemId, resume: resume) }
        .onDisappear { model.stop() }
        .onChange(of: model.finished) { done in if done { dismiss() } }
    }
}

struct TVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        let meta = AVMutableMetadataItem()
        meta.identifier = .commonIdentifierTitle
        meta.value = title as NSString
        meta.extendedLanguageTag = "und"
        player.currentItem?.externalMetadata = [meta]
    }
}

@MainActor
final class TVPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var error: String?
    @Published var blocked = false
    @Published var finished = false
    @Published var title = ""

    private var itemId = 0
    private var offset: Double = 0          // HLS streams start where you resumed, so their clock starts at 0 there
    private var duration: Double = 0
    private var sessionId: String?
    private var nextId: Int?
    private var timer: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSent: Double = -100

    func start(itemId: Int, resume: Double?) async {
        self.itemId = itemId
        stopPlayback(report: false)
        error = nil
        do {
            let detail: TVDetail = try await TVAPI.call("/api/items/\(itemId)")
            nextId = detail.nextId
            let start = resume ?? 0
            let info: TVPlay = try await TVAPI.call("/api/play/\(itemId)", body: [
                "quality": "original", "start": start, "deviceId": TVAPI.deviceId,
                // Apple TV plays H.264, HEVC, Dolby Digital and Dolby Digital Plus natively
                "caps": ["h264": true, "hevc": true, "ac3": true, "eac3": true, "mkv": false],
            ])
            title = [info.showTitle, info.title].compactMap { $0 }.joined(separator: " · ")
            duration = info.duration ?? detail.duration ?? 0
            sessionId = info.sessionId
            guard let url = TVAPI.url(info.url) else { throw TVAPI.Failure(message: "Bad address", status: 0) }
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPCookiesKey": TVAPI.cookies(for: url)])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            if info.mode == "direct" {
                offset = 0
                if start > 0 { await p.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            } else {
                offset = info.start ?? start
            }
            // Left the screen while it was loading: don't start playing behind the menus
            if Task.isCancelled { p.pause(); return }
            observe(p)
            player = p
            p.play()
        } catch let e as TVAPI.Failure {
            blocked = e.status == 403
            error = e.message
        } catch { self.error = error.localizedDescription }
    }

    private var position: Double { offset + (player?.currentTime().seconds.isFinite == true ? player!.currentTime().seconds : 0) }

    private func observe(_ p: AVPlayer) {
        timer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.heartbeat() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.ended() }
        }
    }

    private func heartbeat() async {
        guard let p = player else { return }
        let pos = position
        if abs(pos - lastSent) < 3 && p.rate == 0 { return }
        lastSent = pos
        let reply: TVProgressReply? = try? await TVAPI.call("/api/progress", body: [
            "itemId": itemId, "position": pos, "duration": duration, "deviceId": TVAPI.deviceId, "state": p.rate == 0 ? "paused" : "playing",
        ])
        if let stop = reply?.stop {
            stopPlayback(report: false)
            blocked = true
            error = stop
        }
    }

    private func ended() async {
        await heartbeat()
        if let next = nextId {
            await start(itemId: next, resume: nil) // goes to the friendly "that's all" message if screen time is up
        } else { finished = true }
    }

    func stop() { stopPlayback(report: true) }

    private func stopPlayback(report: Bool) {
        guard let p = player else { return }
        let pos = position
        p.pause()
        if let t = timer { p.removeTimeObserver(t) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        timer = nil; endObserver = nil
        player = nil
        let id = itemId, dur = duration, sid = sessionId
        Task {
            if report && pos > 5 { await TVAPI.send("/api/progress", ["itemId": id, "position": pos, "duration": dur, "deviceId": TVAPI.deviceId, "state": "stopped"]) }
            await TVAPI.send("/api/play-stop", ["deviceId": TVAPI.deviceId])
            if let sid { await TVAPI.send("/api/hls/\(sid)", [:], method: "DELETE") }
        }
    }
}

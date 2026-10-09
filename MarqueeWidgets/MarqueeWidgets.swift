import WidgetKit
import SwiftUI

// Home-screen widgets: "Continue watching" and "New on Marquee".
// They load from your server with the app's device key, about every 30 minutes (iOS decides exactly when).

struct FeedEntry: TimelineEntry {
    let date: Date
    let feed: WidgetFeed?
    let images: [Int: UIImage]
    let message: String?
}

struct FeedProvider: TimelineProvider {
    let wide: Bool

    func placeholder(in context: Context) -> FeedEntry { FeedEntry(date: Date(), feed: nil, images: [:], message: "Marquee") }

    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        load { completion($0) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        load { entry in completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))) }
    }

    private func load(_ done: @escaping (FeedEntry) -> Void) {
        guard SharedStore.deviceKey != nil, !SharedStore.candidates.isEmpty else {
            return done(FeedEntry(date: Date(), feed: nil, images: [:], message: "Open Marquee and pick your profile"))
        }
        // Tries your home address and your away address, whichever answers
        SharedStore.fetch("/ext/v1/widget") { data, response in
            let code = response?.statusCode ?? 0
            guard code == 200, let data, let feed = try? JSONDecoder().decode(WidgetFeed.self, from: data) else {
                return done(FeedEntry(date: Date(), feed: nil, images: [:], message: code == 401 ? "Open Marquee to sign in again" : "Can't reach Marquee right now"))
            }
            // Fetch the pictures (small) before handing the entry over
            let cards = Array((wide ? feed.continueWatching.prefix(3) : feed.newArrivals.prefix(4)))
            let box = ImageBox()
            let group = DispatchGroup()
            for c in cards {
                guard let url = SharedStore.absolute(c.image) else { continue }
                group.enter()
                URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { d, _, _ in
                    if let d, let img = UIImage(data: d)?.preparingThumbnail(of: CGSize(width: wide ? 320 : 200, height: wide ? 180 : 300)) {
                        box.set(c.id, img)
                    }
                    group.leave()
                }.resume()
            }
            group.notify(queue: .main) { done(FeedEntry(date: Date(), feed: feed, images: box.all, message: nil)) }
        }
    }
}

/// Pictures arrive on background threads; this keeps them safe until they're all in.
private final class ImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var dict: [Int: UIImage] = [:]
    func set(_ id: Int, _ img: UIImage) { lock.lock(); dict[id] = img; lock.unlock() }
    var all: [Int: UIImage] { lock.lock(); defer { lock.unlock() }; return dict }
}

private let gold = Color(red: 0.94, green: 0.71, blue: 0.16)
private let bg = Color(red: 0.05, green: 0.04, blue: 0.035)

struct WidgetHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.rectangle.fill").foregroundColor(gold)
            Text(title).font(.caption.weight(.bold)).foregroundColor(gold)
            Spacer()
        }
    }
}

struct ContinueView: View {
    let entry: FeedEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Continue watching")
            if let msg = entry.message { Text(msg).font(.footnote).foregroundColor(.secondary); Spacer() }
            else if let items = entry.feed?.continueWatching, !items.isEmpty {
                ForEach(items.prefix(family == .systemLarge ? 3 : 2), id: \.id) { c in
                    Link(destination: URL(string: c.play) ?? URL(string: "marquee://")!) {
                        HStack(spacing: 10) {
                            thumb(c).frame(width: 84, height: 47).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.footnote.weight(.semibold)).foregroundColor(.white).lineLimit(1)
                                Text(c.subtitle ?? "").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                ProgressView(value: c.progress ?? 0).tint(gold).scaleEffect(x: 1, y: 0.7)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            } else { Text("Nothing in progress — start something in Marquee").font(.footnote).foregroundColor(.secondary); Spacer() }
        }
        .padding(family == .systemSmall ? 12 : 14)
        .widgetBackground(bg)
    }
    @ViewBuilder func thumb(_ c: WidgetFeed.Card) -> some View {
        if let img = entry.images[c.id] { Image(uiImage: img).resizable().scaledToFill() } else { Color.white.opacity(0.08) }
    }
}

struct NewArrivalsView: View {
    let entry: FeedEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "New on Marquee")
            if let msg = entry.message { Text(msg).font(.footnote).foregroundColor(.secondary); Spacer() }
            else if let items = entry.feed?.newArrivals, !items.isEmpty {
                HStack(spacing: 8) {
                    ForEach(items.prefix(family == .systemSmall ? 2 : 4), id: \.id) { c in
                        Link(destination: URL(string: c.open) ?? URL(string: "marquee://")!) {
                            VStack(alignment: .leading, spacing: 3) {
                                Group {
                                    if let img = entry.images[c.id] { Image(uiImage: img).resizable().scaledToFill() } else { Color.white.opacity(0.08) }
                                }.frame(maxWidth: .infinity).aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 7))
                                Text(c.title).font(.caption2.weight(.semibold)).foregroundColor(.white).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            } else { Text("Nothing new yet").font(.footnote).foregroundColor(.secondary); Spacer() }
        }
        .padding(family == .systemSmall ? 12 : 14)
        .widgetBackground(bg)
        .widgetURL(URL(string: "marquee://notifications"))
    }
}

extension View {
    /// iOS 17 wants widget backgrounds declared this way; older iOS just uses a normal background.
    @ViewBuilder func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) { containerBackground(color, for: .widget) } else { background(color) }
    }
}

struct ContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MarqueeContinue", provider: FeedProvider(wide: true)) { ContinueView(entry: $0) }
            .configurationDisplayName("Continue watching")
            .description("Pick up where you left off.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct NewArrivalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MarqueeNew", provider: FeedProvider(wide: false)) { NewArrivalsView(entry: $0) }
            .configurationDisplayName("New on Marquee")
            .description("The newest movies and shows in your library.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MarqueeWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWidget()
        NewArrivalsWidget()
    }
}

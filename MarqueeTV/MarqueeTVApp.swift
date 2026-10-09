import SwiftUI

// Marquee for Apple TV — a proper native app: your library, posters, resume, next episode,
// and Apple's own player (so the Siri Remote, Dolby audio and AirPlay all just work).

let tvGold = Color(red: 0.94, green: 0.71, blue: 0.16)
let tvBg = Color(red: 0.05, green: 0.04, blue: 0.035)

@MainActor
final class TVSession: ObservableObject {
    @Published var server: String? = TVAPI.server
    @Published var me: TVMe?
    @Published var checking = true

    func start() async {
        checking = true
        defer { checking = false }
        guard TVAPI.server != nil else { return }
        me = try? await TVAPI.call("/api/me")
    }
    func signOut() async {
        await TVAPI.send("/api/logout", [:])
        me = nil
    }
    func forgetServer() {
        TVAPI.server = nil
        server = nil
        me = nil
    }
}

@main
struct MarqueeTVApp: App {
    @StateObject private var session = TVSession()

    var body: some Scene {
        WindowGroup {
            ZStack {
                tvBg.ignoresSafeArea()
                if session.server == nil { TVSetupView() }
                else if session.checking { ProgressView().tint(tvGold) }
                else if session.me == nil { TVWhoView() }
                else { TVRootView() }
            }
            .environmentObject(session)
            .preferredColorScheme(.dark)
            .tint(tvGold)
            .task { await session.start() }
        }
    }
}

// MARK: - First run

struct TVSetupView: View {
    @EnvironmentObject var session: TVSession
    /// Starts with the address built into the app (MARQUEE_HOME in project.yml), so it's usually just "Connect"
    @State private var address: String = {
        let built = (Bundle.main.object(forInfoDictionaryKey: "MarqueeHome") as? String) ?? ""
        return built.contains("$(") ? "" : built
    }()
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "play.rectangle.fill").font(.system(size: 90)).foregroundColor(tvGold)
            Text("Welcome to Marquee").font(.largeTitle.bold())
            Text("Type your Marquee server's address — the same one you use on your phone, like zimaos:8420.\nAway from home? Use the Tailscale address (the Tailscale app is on the Apple TV App Store).")
                .multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 1100)
            TextField("zimaos:8420", text: $address).frame(width: 800)
            Button(busy ? "Checking…" : "Connect") { Task { await connect() } }.disabled(busy || address.isEmpty)
            if let status { Text(status).foregroundColor(.orange).multilineTextAlignment(.center).frame(maxWidth: 1000) }
        }
        .padding(80)
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        let url = TVAPI.normalise(address)
        if await TVAPI.checkServer(url) {
            TVAPI.server = url
            session.server = url
            await session.start()
        } else {
            status = "Couldn't reach Marquee at \(url). Check the address — and that Tailscale is on if you're away from home."
        }
    }
}

struct TVWhoView: View {
    @EnvironmentObject var session: TVSession
    @State private var profiles: [TVProfile] = []
    @State private var picked: TVProfile?
    @State private var pin = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 50) {
            Text("Who's watching?").font(.largeTitle.bold())
            HStack(spacing: 50) {
                ForEach(profiles) { p in
                    Button { choose(p) } label: {
                        VStack(spacing: 16) {
                            Text(String(p.name.prefix(1))).font(.system(size: 80, weight: .bold)).foregroundColor(.black)
                                .frame(width: 200, height: 200).background(RoundedRectangle(cornerRadius: 34).fill(Color(hex: p.color)))
                            Text(p.name).font(.title3)
                            if p.hasPin { Image(systemName: "lock.fill").font(.caption).foregroundColor(.secondary) }
                        }.padding(20)
                    }.buttonStyle(.card)
                }
            }
            if let picked, picked.hasPin {
                VStack(spacing: 20) {
                    Text("PIN for \(picked.name)").font(.title3)
                    SecureField("PIN", text: $pin).keyboardType(.numberPad).frame(width: 400).onSubmit { Task { await signIn(picked) } }
                    Button("Sign in") { Task { await signIn(picked) } }
                }
            }
            if let error { Text(error).foregroundColor(.orange) }
            Button("Change server") { session.forgetServer() }.font(.footnote)
        }
        .padding(60)
        .task { profiles = (try? await TVAPI.call("/api/profiles")) ?? [] }
    }

    private func choose(_ p: TVProfile) {
        error = nil
        pin = ""
        picked = p
        if !p.hasPin { Task { await signIn(p) } }
    }
    private func signIn(_ p: TVProfile) async {
        do {
            let _: TVProfile = try await TVAPI.call("/api/login", body: ["profileId": p.id, "pin": pin])
            await session.start()
        } catch { self.error = error.localizedDescription }
    }
}

extension Color {
    init(hex: String) {
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

// MARK: - Main tabs

struct TVRootView: View {
    var body: some View {
        TabView {
            NavigationStack { TVHomeView() }.tabItem { Label("Home", systemImage: "house") }
            NavigationStack { TVLibraryView(kind: "movies") }.tabItem { Label("Movies", systemImage: "film") }
            NavigationStack { TVLibraryView(kind: "shows") }.tabItem { Label("TV Shows", systemImage: "tv") }
            NavigationStack { TVSearchView() }.tabItem { Label("Search", systemImage: "magnifyingglass") }
            TVSettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct TVArt: View {
    let path: String?
    var title: String = ""
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .top, endPoint: .bottom); Text(title).font(.headline).multilineTextAlignment(.center).padding() }
        }
        .clipped()
        .task(id: path) { image = await ImageCache.shared.image(path) }
    }
}

struct TVPosterCard: View {
    let item: TVItem
    var body: some View {
        NavigationLink(value: item) {
            TVArt(path: item.poster ?? item.show?.poster, title: item.title).frame(width: 260, height: 390)
        }
        .buttonStyle(.card)
        .overlay(alignment: .bottom) {
            if let f = item.fraction { GeometryReader { g in Rectangle().fill(tvGold).frame(width: g.size.width * f, height: 6).frame(maxHeight: .infinity, alignment: .bottom) } }
        }
    }
}

struct TVWideCard: View {
    let item: TVItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: TVPlayTarget(itemId: item.id, resume: item.resumeAt)) {
                TVArt(path: item.wideImage, title: item.displayTitle).frame(width: 480, height: 270)
                    .overlay(alignment: .bottom) {
                        if let f = item.fraction { GeometryReader { g in Rectangle().fill(tvGold).frame(width: g.size.width * f, height: 6).frame(maxHeight: .infinity, alignment: .bottom) } }
                    }
            }.buttonStyle(.card)
            Text(item.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Text(item.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }.frame(width: 480)
    }
}

struct TVRow: View {
    let title: String
    let items: [TVItem]
    var wide = false
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.title3.bold()).padding(.leading, 60)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 40) { ForEach(items) { wide ? AnyView(TVWideCard(item: $0)) : AnyView(TVPosterCard(item: $0)) } }
                        .padding(.horizontal, 60).padding(.vertical, 30)
                }
            }
        }
    }
}

struct TVPlayTarget: Hashable { let itemId: Int; let resume: Double? }

extension View {
    /// Where cards lead: a movie/show page, or straight into the player
    func tvDestinations() -> some View {
        navigationDestination(for: TVItem.self) { item in TVDetailView(itemId: item.type == "episode" ? (item.show?.id ?? item.id) : item.id) }
            .navigationDestination(for: TVPlayTarget.self) { t in TVPlayerScreen(itemId: t.itemId, resume: t.resume) }
    }
}

struct TVHomeView: View {
    @State private var home: TVHome?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let error { Text(error).foregroundColor(.orange).padding(60) }
                if let h = home {
                    TVRow(title: "Continue watching", items: h.continueWatching, wide: true)
                    TVRow(title: "Next up", items: h.nextUp, wide: true)
                    TVRow(title: "My List", items: h.myList)
                    TVRow(title: "Recently added movies", items: h.allMovies ?? h.recentMovies)
                    TVRow(title: "Recently added shows", items: h.allShows ?? h.recentShows)
                    TVRow(title: "Home videos", items: h.recentHome ?? [], wide: true)
                } else if error == nil { ProgressView().frame(maxWidth: .infinity).padding(200) }
            }
        }
        .tvDestinations()
        .onAppear { Task { await load() } }  // also refreshes Continue watching after you come back from the player
    }
    private func load() async {
        do { home = try await TVAPI.call("/api/home"); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct TVLibraryView: View {
    let kind: String
    @State private var items: [TVItem] = []
    private let columns = Array(repeating: GridItem(.fixed(260), spacing: 50), count: 5)
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 60) { ForEach(items) { TVPosterCard(item: $0) } }.padding(60)
        }
        .tvDestinations()
        .task { items = (try? await TVAPI.call("/api/\(kind)?sort=title")) ?? [] }
    }
}

struct TVSearchView: View {
    @State private var query = ""
    @State private var result: TVSearch?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TVRow(title: "Movies", items: result?.movies ?? [])
                TVRow(title: "TV Shows", items: result?.shows ?? [])
                TVRow(title: "Episodes", items: result?.episodes ?? [], wide: true)
            }
        }
        .searchable(text: $query, prompt: "Movies, shows, actors")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { result = nil; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            result = try? await TVAPI.call("/api/search?q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)")
        }
        .tvDestinations()
    }
}

struct TVSettingsView: View {
    @EnvironmentObject var session: TVSession
    var body: some View {
        VStack(spacing: 30) {
            Text(session.me.map { "Signed in as \($0.name)" } ?? "").font(.title2)
            Text(TVAPI.server ?? "").foregroundColor(.secondary)
            Button("Switch profile") { Task { await session.signOut() } }
            Button("Change server") { session.forgetServer() }
            Text("Marquee for Apple TV \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.footnote).foregroundColor(.secondary)
        }
    }
}

// MARK: - Movie / show page

struct TVDetailView: View {
    let itemId: Int
    @State private var d: TVDetail?
    @State private var season = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVArt(path: d?.backdrop).ignoresSafeArea().overlay(LinearGradient(colors: [tvBg, tvBg.opacity(0.75), tvBg.opacity(0.2)], startPoint: .leading, endPoint: .trailing).ignoresSafeArea())
            ScrollView {
                if let d {
                    VStack(alignment: .leading, spacing: 26) {
                        Text(d.title).font(.system(size: 64, weight: .bold))
                        Text(TVMeta.line(d))
                            .foregroundColor(.secondary)
                        if let o = d.overview { Text(o).frame(maxWidth: 1100, alignment: .leading).lineLimit(5) }
                        HStack(spacing: 30) {
                            if d.type == "movie" {
                                let resume = (d.progress?.watched != true && (d.progress?.position ?? 0) > 30) ? d.progress?.position : nil
                                NavigationLink(value: TVPlayTarget(itemId: d.id, resume: resume)) { Label(resume.map { "Resume \(fmt($0))" } ?? "Play", systemImage: "play.fill") }
                                if resume != nil { NavigationLink(value: TVPlayTarget(itemId: d.id, resume: 0)) { Label("Start over", systemImage: "backward.end.fill") } }
                            } else if let ne = d.nextEpisode {
                                NavigationLink(value: TVPlayTarget(itemId: ne.id, resume: ne.resumeAt)) { Label("Play S\(ne.season ?? 0) E\(ne.episode ?? 0)", systemImage: "play.fill") }
                            }
                        }
                        if let seasons = d.seasons, !seasons.isEmpty {
                            Picker("Season", selection: $season) { ForEach(seasons.indices, id: \.self) { Text(seasons[$0].title).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 900)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 40) {
                                    ForEach(seasons[min(season, seasons.count - 1)].episodes) { e in
                                        VStack(alignment: .leading, spacing: 8) {
                                            NavigationLink(value: TVPlayTarget(itemId: e.id, resume: e.resumeAt)) {
                                                TVArt(path: e.still ?? d.backdrop, title: e.title).frame(width: 400, height: 225)
                                                    .overlay(alignment: .topTrailing) { if e.progress?.watched == true { Image(systemName: "checkmark.circle.fill").foregroundColor(tvGold).padding(10) } }
                                            }.buttonStyle(.card)
                                            Text("\(e.episode.map { "\($0). " } ?? "")\(e.title)").font(.callout.weight(.semibold)).lineLimit(1)
                                        }.frame(width: 400)
                                    }
                                }.padding(.vertical, 30)
                            }
                        }
                    }.padding(80)
                } else { ProgressView().padding(300) }
            }
        }
        .task {
            d = try? await TVAPI.call("/api/items/\(itemId)")
            if let d, let ne = d.nextEpisode, let idx = d.seasons?.firstIndex(where: { $0.season == ne.season }) { season = idx }
        }
    }
    private func fmt(_ s: Double) -> String { let t = Int(s); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60) }
}

/// "2019  ·  PG  ·  1h 42m  ·  ★ 7.4" (kept out of the view so Swift type-checks it quickly)
enum TVMeta {
    static func line(_ d: TVDetail) -> String {
        var parts: [String] = []
        if let y = d.year { parts.append(String(y)) }
        if let c = d.certification, !c.isEmpty { parts.append(c) }
        if let r = d.runtime { parts.append("\(r / 60)h \(r % 60)m") }
        if let v = d.vote { parts.append(String(format: "★ %.1f", v)) }
        return parts.joined(separator: "  ·  ")
    }
}

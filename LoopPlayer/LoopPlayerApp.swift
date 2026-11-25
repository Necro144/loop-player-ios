import SwiftUI
import UIKit
import MediaPlayer

enum Theme {
    static let bg = Color.black
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surface2 = Color(red: 0.13, green: 0.13, blue: 0.145)
    static let accent = Color(red: 1.0, green: 0.27, blue: 0.47)
    static let accent2 = Color(red: 1.0, green: 0.55, blue: 0.35)
    static let hairline = Color.white.opacity(0.09)
    static let dim = Color.white.opacity(0.55)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Small piece of shared UI state (sheets started from list rows).
@MainActor
final class AppUI: ObservableObject {
    static let shared = AppUI()
    @Published var addToPlaylist: TrackIDs?
    @Published var info: Track?
    @Published var showPhoneBrowser = false
    @Published var openYouTube: OpenID?
    @Published var showSuno = false
    @Published var showSunoSignIn = false
}

struct OpenID: Identifiable {
    let id: UUID
}

struct TrackIDs: Identifiable {
    let id = UUID()
    let ids: [String]
}

@main
struct LoopPlayerApp: App {
    @StateObject private var library = Library.shared
    @StateObject private var player = Player.shared
    @StateObject private var store = UserStore.shared
    @StateObject private var ui = AppUI.shared

    init() {
        TestHooks.prepare()
        Watchdog.start()
        FolderLog.append("App started (version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))" + (DeviceFolders.available ? ", phone folders readable (TrollStore)" : ""))
        // Put the kept Suno sign-in back into WebKit before anything loads Suno's page.
        Task { @MainActor in await SunoAuth.shared.restoreSession() }
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(white: 0.035, alpha: 1)
        tab.shadowColor = UIColor(white: 1, alpha: 0.08)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .black
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UITableView.appearance().backgroundColor = .black
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(player.clock)
                .environmentObject(store)
                .environmentObject(ui)
                .environmentObject(YouTubeStore.shared)
                .environmentObject(SpotifyStore.shared)
                .environmentObject(SunoStore.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: AppUI
    @ObservedObject private var clips = ClipMaker.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if library.folders.isEmpty {
                WelcomeView()
            } else {
                MainTabs()
            }
        }
        .sheet(isPresented: $player.showFullPlayer) {
            NowPlayingView()
        }
        .sheet(isPresented: $clips.openStudio) {
            ClipStudioView()
        }
        .onOpenURL { url in ClipMaker.shared.handle(url) }
        .sheet(item: $ui.addToPlaylist) { box in
            PlaylistPickerView(ids: box.ids)
        }
        .sheet(item: $ui.info) { t in
            TrackInfoView(track: t)
        }
        .sheet(item: $ui.openYouTube) { o in
            NavigationStack { YouTubePlaylistView(playlistID: o.id) }
        }
        .sheet(isPresented: $ui.showSuno) {
            SunoLinkSheet()
                .environmentObject(SunoStore.shared)
                .environmentObject(player)
        }
        .sheet(isPresented: $ui.showSunoSignIn) {
            SunoSignInView().environmentObject(SunoAuth.shared)
        }
        .sheet(isPresented: $ui.showPhoneBrowser) {
            PhoneBrowserView()
                .environmentObject(library)
        }
        .overlay(alignment: .top) { ToastOverlay() }
        .alert("Loop Player", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.message ?? "")
        }
        .onAppear { TestHooks.run() }
    }
}

/// Six tabs (1.3.0 adds Suno). iPhone's own tab bar shows only five before folding the rest
/// into "More", so the bar is drawn here. Every tab stays alive when hidden, like a TabView.
struct MainTabs: View {
    @AppStorage("tab") private var tab = 0

    private static let items: [(String, String)] = [
        ("Home", "house.fill"), ("Library", "square.stack.fill"), ("Search", "magnifyingglass"),
        ("Playlists", "music.note.list"), ("Suno", "waveform"), ("Settings", "gearshape.fill")
    ]
    /// Old saved tab numbers: Settings was 4 before the Suno tab.
    private static let sunoTab = 4, settingsTab = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(0) { NavigationStack { HomeView() }.withMiniPlayer() }
                page(1) { NavigationStack { LibraryView() }.withMiniPlayer() }
                page(2) { NavigationStack { SearchView() }.withMiniPlayer() }
                page(3) { NavigationStack { PlaylistsView() }.withMiniPlayer() }
                page(MainTabs.sunoTab) { SunoTabView(active: tab == MainTabs.sunoTab).withMiniPlayer() }
                page(MainTabs.settingsTab) { NavigationStack { SettingsView() }.withMiniPlayer() }
            }
            bar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            if UserDefaults.standard.object(forKey: "tabsV13") == nil {
                UserDefaults.standard.set(true, forKey: "tabsV13")
                if tab == 4 { tab = MainTabs.settingsTab }
            }
            if tab < 0 || tab >= MainTabs.items.count { tab = 0 }
        }
    }

    private func page<V: View>(_ i: Int, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .opacity(tab == i ? 1 : 0)
            .allowsHitTesting(tab == i)
            .accessibilityHidden(tab != i)
            .zIndex(tab == i ? 1 : 0)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(Array(MainTabs.items.enumerated()), id: \.offset) { i, item in
                Button {
                    if tab == i, i != MainTabs.sunoTab { NotificationCenter.default.post(name: .tabReselected, object: i) }
                    tab = i
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.1).font(.system(size: 19, weight: .semibold)).frame(height: 24)
                        Text(item.0).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 7)
                    .padding(.bottom, 2)
                    .foregroundColor(tab == i ? Theme.accent : Color.white.opacity(0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(item.0)")
                .accessibilityAddTraits(tab == i ? [.isSelected] : [])
            }
        }
        .background(Color(white: 0.035).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

extension Notification.Name {
    static let tabReselected = Notification.Name("LoopPlayer.tabReselected")
}

extension View {
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerSlot() }
    }

    func darkList() -> some View {
        self.listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
    }
}

struct ToastOverlay: View {
    @EnvironmentObject var player: Player

    var body: some View {
        Group {
            if let text = player.toast {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { player.toast = nil }
                    }
                    .onTapGesture { withAnimation { player.toast = nil } }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.toast)
    }
}

/// Hooks used only by the automated simulator test in GitHub Actions.
enum TestHooks {
    private static var done = false

    /// Runs before anything is loaded. TEST_RESET starts from a clean app,
    /// TEST_SEED_DIR copies test songs into Documents/Suno Songs.
    static func prepare() {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if env["TEST_RESET"] == "1" {
            if let files = try? fm.contentsOfDirectory(at: AppPaths.support, includingPropertiesForKeys: nil) {
                for f in files { try? fm.removeItem(at: f) }
            }
            for key in ["playerState", "tab", "songSort"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let seed = env["TEST_SEED_DIR"], !seed.isEmpty {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let target = docs.appendingPathComponent("Suno Songs", isDirectory: true)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: URL(fileURLWithPath: seed, isDirectory: true), to: target)
            }
        }
    }

    @MainActor static func run() {
        guard !done else { return }
        done = true
        let env = ProcessInfo.processInfo.environment
        if let tab = env["TEST_TAB"], let n = Int(tab) {
            UserDefaults.standard.set(n, forKey: "tab")
            UserDefaults.standard.set(true, forKey: "tabsV13")
        }
        if env["TEST_ADD_DOCUMENTS"] == "1", Library.shared.folders.isEmpty {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            Library.shared.addFolders([docs])
        }
        if env["TEST_PLAY"] == "1" {
            Task { @MainActor in
                for _ in 0..<60 {
                    if !Library.shared.isScanning && !Library.shared.tracks.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let all = Grouping.sort(Library.shared.tracks, by: .title)
                if let title = env["TEST_PLAY_TITLE"], let i = all.firstIndex(where: { $0.title == title }) {
                    Player.shared.play(all, startAt: i)
                } else if let v = env["TEST_PLAY_VIDEO"], v == "1", let i = all.firstIndex(where: { $0.isVideo }) {
                    Player.shared.play(all, startAt: i)
                } else if env["TEST_PLAY_VIDEO"] == "0", let i = all.firstIndex(where: { !$0.isVideo && $0.hasArtwork }) {
                    Player.shared.play(all, startAt: i)
                } else {
                    Player.shared.play(all)
                }
                if env["TEST_REPEAT_ONE"] == "1" { Player.shared.setRepeat(.one) }
                if env["TEST_FULL"] == "1" {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    Player.shared.showFullPlayer = true
                }
                if let secs = env["TEST_CLIP"].flatMap(Double.init) {
                    // Share a Clip: cut `secs` seconds from where the video is after a few seconds.
                    if let r = env["TEST_RATE"].flatMap(Float.init) {
                        Player.shared.setKeepPitch(env["TEST_KEEP_PITCH"] != "0")
                        Player.shared.setRate(r)
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    // Clip Studio choices (1.5.0).
                    var o = ClipOptions()
                    o.seconds = secs
                    if let v = env["TEST_CLIP_SIZE"].flatMap(ClipSize.init(rawValue:)) { o.size = v }
                    if let v = env["TEST_CLIP_LOOK"].flatMap(ClipLook.init(rawValue:)) { o.look = v }
                    if let v = env["TEST_CLIP_REPEAT"].flatMap(Int.init) { o.repeats = v }
                    o.caption = env["TEST_CLIP_CAPTION"] ?? ""
                    o.showTitle = env["TEST_CLIP_TITLE"] == "1"
                    o.fade = env["TEST_CLIP_FADE"] == "1"
                    o.watermark = env["TEST_CLIP_STAMP"] == "1"
                    if env["TEST_CLIP_PHOTO"] == "1" {
                        // A made-up 800x600 photo, as if picked from the library.
                        let f = UIGraphicsImageRendererFormat()
                        f.scale = 1
                        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: f).image { c in
                            UIColor.systemTeal.setFill()
                            c.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
                            UIColor.systemPink.setFill()
                            c.fill(CGRect(x: 200, y: 150, width: 400, height: 300))
                        }
                        let u = FileManager.default.temporaryDirectory.appendingPathComponent("test-photo.img")
                        try? img.jpegData(compressionQuality: 0.9)?.write(to: u)
                        ClipMaker.shared.source = .photo(u)
                    }
                    ClipMaker.shared.make(o, to: .share)
                }
                if env["TEST_STUDIO"] == "1" {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    ClipMaker.shared.openStudio = true
                }
                if let out = env["TEST_BG_OUT"] {
                    // The test sends the app to the background meanwhile (opens Settings).
                    let wait = Double(env["TEST_BG_WAIT"] ?? "40") ?? 40
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    let p = Player.shared
                    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
                    let lines = [
                        "background=\(p.isInBackground)",
                        "playing=\(p.isPlaying)",
                        "time=\(Int(p.clock.time))",
                        "bgPauses=\(p.bgPauses)",
                        "current=\(p.current?.title ?? "-")",
                        "nowPlayingTitle=\(info?[MPMediaItemPropertyTitle] as? String ?? "-")",
                        "nowPlayingRate=\(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1)",
                        "nowPlayingArtwork=\(info?[MPMediaItemPropertyArtwork] != nil)",
                    ]
                    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                }
                if let out = env["TEST_OUT"] {
                    let wait = Double(env["TEST_OUT_WAIT"] ?? "7") ?? 7
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    let p = Player.shared
                    let lib = Library.shared
                    var lines = [
                        "tracks=\(lib.tracks.count)",
                        "videos=\(lib.tracks.filter(\.isVideo).count)",
                        "artwork=\(lib.tracks.filter(\.hasArtwork).count)",
                        "albums=\(lib.albums.count)",
                        "artists=\(lib.artists.count)",
                        "playing=\(p.isPlaying)",
                        "current=\(p.current?.title ?? "-")",
                        "time=\(Int(p.clock.time))",
                        "repeat=\(p.repeatMode.rawValue)",
                    ]
                    for t in Grouping.sort(lib.tracks, by: .title) {
                        lines.append("track: \(t.title) | \(t.artist) | \(t.album) | \(Int(t.duration))s | video=\(t.isVideo) | art=\(t.hasArtwork) | \(t.relativePath)")
                    }
                    lines.append(contentsOf: FolderLog.read().suffix(40).map { "log: \($0)" })
                    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
        }
        if let link = env["TEST_YT"], let out = env["TEST_YT_OUT"] {
            Task { @MainActor in
                let err = await YouTubeStore.shared.add(link)
                let list = YouTubeStore.parse(link)
                guard let p = YouTubeStore.shared.playlists.first(where: {
                    (list.list != nil && $0.listID == list.list) || (list.list == nil && $0.videoID == list.video)
                }) else {
                    try? "add failed: \(err ?? "-")".write(toFile: out, atomically: true, encoding: .utf8)
                    return
                }
                AppUI.shared.openYouTube = OpenID(id: p.id)
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                let now = YouTubeStore.shared.playlist(p.id)
                var lines = ["title=\(now?.title ?? "-")", "single=\(now?.isSingle ?? false)",
                             "videos=\(now?.videos.count ?? 0)",
                             "titled=\(now?.videos.filter { !$0.title.isEmpty }.count ?? 0)"]
                lines += YTController.testLog.map { "event: \($0)" }
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        if env["TEST_SUNO_SIGNIN"] == "1" {
            AppUI.shared.showSunoSignIn = true
        }
        if let link = env["TEST_SUNO"], let out = env["TEST_SUNO_OUT"] {
            Task { @MainActor in
                var lines: [String] = []
                do {
                    let got = try await SunoStore.shared.add(link)
                    lines.append("songs=\(got.count)")
                    lines += got.prefix(3).map { "song: \($0.title) | \($0.artist) | \(Int($0.duration)) | \($0.stream)" }
                    Player.shared.play(got.prefix(1).map { SunoStore.shared.track($0) })
                } catch {
                    lines.append("error=\(error.localizedDescription)")
                }
                let wait = Double(env["TEST_SUNO_WAIT"] ?? "25") ?? 25
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                let p = Player.shared
                lines.append("playing=\(p.isPlaying)")
                lines.append("time=\(Int(p.clock.time))")
                lines.append("duration=\(Int(p.clock.duration))")
                lines.append("current=\(p.current?.title ?? "-")")
                lines.append("art=\(p.current?.hasArtwork ?? false)")
                let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
                lines.append("nowPlayingTitle=\((info?[MPMediaItemPropertyTitle] as? String) ?? "-")")
                lines.append("lists=\(SunoStore.shared.lists.count)")
                lines.append("signedIn=\(SunoAuth.shared.signedIn)")
                lines.append(contentsOf: FolderLog.read().suffix(15).map { "log: \($0)" })
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        if let link = env["TEST_SPOTIFY"], let out = env["TEST_SP_OUT"] {
            Task { @MainActor in
                let err = await SpotifyStore.shared.add(link)
                var lines = ["error=\(err ?? "-")"]
                if let l = SpotifyStore.shared.lists.first {
                    lines.append("title=\(l.title)")
                    lines.append("tracks=\(l.tracks.count)")
                    lines += l.tracks.prefix(3).map { "track: \($0.title) | \($0.artist) | \(Int($0.duration))" }
                    let m = SongMatcher(Library.shared.tracks)
                    lines.append("matched=\(l.tracks.filter { m.find($0) != nil }.count)")
                }
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }
}

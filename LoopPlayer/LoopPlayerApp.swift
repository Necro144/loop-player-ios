import SwiftUI
import UIKit
import MediaPlayer

/// How the app looks (1.5.4): System follows the iPhone, Black is the old pure black look.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .black: return "Black"
        }
    }
}

/// The colour of buttons, the playing song and highlights.
enum AccentChoice: String, CaseIterable, Identifiable {
    case pink, red, orange, yellow, green, mint, teal, blue, indigo, purple
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var pair: (UIColor, UIColor) {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
        switch self {
        case .pink: return (c(1, 0.27, 0.47), c(1, 0.55, 0.35))
        case .red: return (c(1, 0.23, 0.19), c(1, 0.45, 0.3))
        case .orange: return (c(1, 0.58, 0.0), c(1, 0.78, 0.2))
        case .yellow: return (c(1, 0.8, 0.0), c(1, 0.6, 0.1))
        case .green: return (c(0.2, 0.8, 0.35), c(0.6, 0.9, 0.2))
        case .mint: return (c(0.0, 0.78, 0.65), c(0.3, 0.9, 0.8))
        case .teal: return (c(0.19, 0.69, 0.78), c(0.35, 0.55, 1))
        case .blue: return (c(0.0, 0.48, 1), c(0.35, 0.35, 1))
        case .indigo: return (c(0.35, 0.34, 0.84), c(0.6, 0.35, 0.95))
        case .purple: return (c(0.69, 0.32, 0.87), c(1, 0.35, 0.65))
        }
    }
}

enum Theme {
    static var mode: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .black }
    static var accentChoice: AccentChoice { AccentChoice(rawValue: UserDefaults.standard.string(forKey: "appAccent") ?? "") ?? .pink }
    /// nil: follow the iPhone.
    static var scheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark, .black: return .dark
        }
    }

    /// A colour for dark screens (`black` / `dark` theme) and for light ones.
    static func dyn(black: UIColor, dark: UIColor, light: UIColor) -> UIColor {
        UIColor { t in
            guard t.userInterfaceStyle == .dark else { return light }
            return Theme.mode == .dark ? dark : black
        }
    }
    static var uiBG: UIColor { dyn(black: .black, dark: UIColor(white: 0.11, alpha: 1), light: UIColor(white: 0.97, alpha: 1)) }
    static var uiBar: UIColor { dyn(black: UIColor(white: 0.035, alpha: 1), dark: UIColor(white: 0.15, alpha: 1), light: .white) }
    static var bg: Color { Color(uiBG) }
    static var surface: Color { Color(dyn(black: UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1), dark: UIColor(white: 0.17, alpha: 1), light: .white)) }
    static var surface2: Color { Color(dyn(black: UIColor(red: 0.13, green: 0.13, blue: 0.145, alpha: 1), dark: UIColor(white: 0.23, alpha: 1), light: UIColor(white: 0.9, alpha: 1))) }
    static var accent: Color { Color(accentChoice.pair.0) }
    static var accent2: Color { Color(accentChoice.pair.1) }
    static var hairline: Color { Color(dyn(black: UIColor(white: 1, alpha: 0.09), dark: UIColor(white: 1, alpha: 0.1), light: UIColor(white: 0, alpha: 0.1))) }
    static var dim: Color { Color(dyn(black: UIColor(white: 1, alpha: 0.55), dark: UIColor(white: 1, alpha: 0.58), light: UIColor(white: 0, alpha: 0.5))) }
    static var faint: Color { Color(dyn(black: UIColor(white: 1, alpha: 0.5), dark: UIColor(white: 1, alpha: 0.5), light: UIColor(white: 0, alpha: 0.42))) }
    static var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var snapYellow: Color { Color(dyn(black: UIColor(red: 1, green: 0.99, blue: 0, alpha: 1), dark: UIColor(red: 1, green: 0.99, blue: 0, alpha: 1), light: UIColor(red: 0.85, green: 0.68, blue: 0, alpha: 1))) }

    /// Light or dark for the whole app, set on the windows themselves (1.5.5). SwiftUI's
    /// preferredColorScheme stayed dark after the full player (always dark) had been open, so
    /// System didn't follow the iPhone any more.
    @MainActor static func applyWindow() {
        let style: UIUserInterfaceStyle
        switch mode {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark, .black: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows where w.overrideUserInterfaceStyle != style { w.overrideUserInterfaceStyle = style }
        }
    }

    /// UIKit bars in the chosen theme.
    static func applyBars() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiBar
        tab.shadowColor = dyn(black: UIColor(white: 1, alpha: 0.08), dark: UIColor(white: 1, alpha: 0.08), light: UIColor(white: 0, alpha: 0.1))
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiBG
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.label]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UITableView.appearance().backgroundColor = uiBG
    }
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
    @Published var showSnapSend = false
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
        if let t = ProcessInfo.processInfo.environment["TEST_THEME"] { UserDefaults.standard.set(t, forKey: "appTheme") }
        if let a = ProcessInfo.processInfo.environment["TEST_ACCENT"] { UserDefaults.standard.set(a, forKey: "appAccent") }
        Theme.applyBars()
    }

    @AppStorage("appTheme") private var themeName = AppTheme.black.rawValue
    @AppStorage("appAccent") private var accentName = AccentChoice.pink.rawValue

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
                .tint(Theme.accent)
                // A new theme or colour redraws every screen at once.
                .id(themeName + "-" + accentName)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: AppUI
    @ObservedObject private var studio = ClipStudioRouter.shared

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
        .sheet(isPresented: $studio.open) {
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
        .sheet(isPresented: $ui.showSnapSend) {
            SnapSendView()
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
        .onAppear {
            Theme.applyWindow()
            TestHooks.run()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Theme.applyWindow() }
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
                page(0) { NavigationStack { HomeView().snapButton() }.withMiniPlayer() }
                page(1) { NavigationStack { LibraryView().snapButton() }.withMiniPlayer() }
                page(2) { NavigationStack { SearchView().snapButton() }.withMiniPlayer() }
                page(3) { NavigationStack { PlaylistsView().snapButton() }.withMiniPlayer() }
                page(MainTabs.sunoTab) { SunoTabView(active: tab == MainTabs.sunoTab).withMiniPlayer() }
                page(MainTabs.settingsTab) { NavigationStack { SettingsView().snapButton() }.withMiniPlayer() }
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
                    .foregroundColor(tab == i ? Theme.accent : Theme.faint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(item.0)")
                .accessibilityAddTraits(tab == i ? [.isSelected] : [])
            }
        }
        .background(Color(Theme.uiBar).ignoresSafeArea(edges: .bottom))
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
        if let out = env["TEST_PAINT_OUT"] {
            try? PaintCheck.run().joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        if env["TEST_SNAP_SEND"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                AppUI.shared.showSnapSend = true
            }
        }
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
                    if let v = env["TEST_CLIP_CARD"].flatMap(CardStyle.init(rawValue:)) { o.cardStyle = v }
                    if let v = env["TEST_CLIP_CAPTION_PLACE"].flatMap(CaptionPlace.init(rawValue:)) { o.captionPlace = v }
                    if let v = env["TEST_CLIP_CAPTION_COLOR"].flatMap(CaptionColor.init(rawValue:)) { o.captionColor = v }
                    if let v = env["TEST_CLIP_VIDEO"] { ClipMaker.shared.source = .video(URL(fileURLWithPath: v)) }
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
                if env["TEST_STICKER_OUT"] != nil {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    ClipMaker.shared.songToSnapchatCamera()
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

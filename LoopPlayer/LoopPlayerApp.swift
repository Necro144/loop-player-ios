import SwiftUI
import UIKit

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
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: AppUI

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
        .sheet(item: $ui.addToPlaylist) { box in
            PlaylistPickerView(ids: box.ids)
        }
        .sheet(item: $ui.info) { t in
            TrackInfoView(track: t)
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

struct MainTabs: View {
    @AppStorage("tab") private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView() }
                .withMiniPlayer()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            NavigationStack { LibraryView() }
                .withMiniPlayer()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag(1)
            NavigationStack { SearchView() }
                .withMiniPlayer()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(2)
            NavigationStack { PlaylistsView() }
                .withMiniPlayer()
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
                .tag(3)
            NavigationStack { SettingsView() }
                .withMiniPlayer()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
    }
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

    @MainActor static func run() {
        guard !done else { return }
        done = true
        let env = ProcessInfo.processInfo.environment
        if let tab = env["TEST_TAB"], let n = Int(tab) {
            UserDefaults.standard.set(n, forKey: "tab")
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
                if let v = env["TEST_PLAY_VIDEO"], v == "1", let i = all.firstIndex(where: { $0.isVideo }) {
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
                if let out = env["TEST_OUT"] {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
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
                    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

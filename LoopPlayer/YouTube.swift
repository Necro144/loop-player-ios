import SwiftUI
import WebKit

// YouTube playlists and single videos play through YouTube's own embedded player (the IFrame
// Player API), which is the way YouTube allows other apps to play its videos. YouTube's rules for
// that player: the video stays visible, nothing is downloaded or played as audio only, nothing
// plays in the background, and its ads are not touched. So playback stops when the app leaves
// the screen. Videos whose owners turned off embedding are skipped. No API key or account is used.

struct YTVideo: Codable, Hashable, Identifiable {
    let id: String
    var title: String
}

struct YTPlaylist: Codable, Identifiable, Hashable {
    let id: UUID
    let listID: String
    var title: String
    var videos: [YTVideo]
    var added: Date
    /// Set when this is one video (looped), not a playlist.
    var videoID: String? = nil

    var isSingle: Bool { videoID != nil }
    var youtubeURL: URL? {
        if let v = videoID { return URL(string: "https://www.youtube.com/watch?v=\(v)") }
        return URL(string: "https://www.youtube.com/playlist?list=\(listID)")
    }
}

@MainActor
final class YouTubeStore: ObservableObject {
    static let shared = YouTubeStore()
    @Published private(set) var playlists: [YTPlaylist] = []
    private var titleLookups: Set<String> = []
    private var feedLoaded: Set<UUID> = []

    private init() {
        playlists = JSONStore.load([YTPlaylist].self, "youtube.json") ?? []
    }

    private func save() { JSONStore.save(playlists, "youtube.json") }

    func playlist(_ id: UUID) -> YTPlaylist? { playlists.first { $0.id == id } }

    // MARK: Links

    /// Playlist id and/or video id from a YouTube link (watch, youtu.be, shorts, embed, live,
    /// music.youtube.com, playlist) or a bare playlist id.
    static func parse(_ text: String) -> (list: String?, video: String?) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list: String?
        var video: String?
        if let c = URLComponents(string: s.contains("://") ? s : "https://" + s), let host = c.host?.lowercased(),
           host.contains("youtu") {
            let q = c.queryItems ?? []
            if let v = q.first(where: { $0.name == "list" })?.value, validList(v) { list = v }
            if let v = q.first(where: { $0.name == "v" })?.value, validVideo(v) { video = v }
            let parts = c.path.split(separator: "/").map(String.init)
            if video == nil {
                if host.hasPrefix("youtu.be"), let first = parts.first, validVideo(first) {
                    video = first
                } else if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]), validVideo(parts[1]) {
                    video = parts[1]
                }
            }
        } else if validList(s) && s.count >= 13 {
            list = s
        }
        return (list, video)
    }

    private static func idChars(_ s: String) -> Bool {
        s.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }
    private static func validList(_ s: String) -> Bool { !s.isEmpty && s.count <= 64 && idChars(s) }
    private static func validVideo(_ s: String) -> Bool { s.count == 11 && idChars(s) }

    /// Adds a playlist or one video; returns an error text if the link is neither.
    func add(_ link: String) async -> String? {
        let p = YouTubeStore.parse(link)
        if let list = p.list {
            if playlists.contains(where: { $0.listID == list && !$0.isSingle }) { return "This playlist is already here." }
            let title = await YouTubeStore.oembedTitle("https://www.youtube.com/playlist?list=\(list)") ?? "YouTube Playlist"
            playlists.insert(YTPlaylist(id: UUID(), listID: list, title: title, videos: [], added: Date()), at: 0)
        } else if let v = p.video {
            if playlists.contains(where: { $0.videoID == v }) { return "This video is already here." }
            let title = await YouTubeStore.oembedTitle("https://www.youtube.com/watch?v=\(v)") ?? "YouTube Video"
            playlists.insert(YTPlaylist(id: UUID(), listID: "", title: title, videos: [YTVideo(id: v, title: title)],
                                        added: Date(), videoID: v), at: 0)
        } else {
            return "That isn't a YouTube playlist or video link. In YouTube tap Share > Copy link, then paste it here."
        }
        save()
        return nil
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].title = n
        save()
    }

    // MARK: Video lists and titles

    /// The player reported the playlist's videos (in YouTube's order). Titles are looked up once.
    func setVideos(_ id: UUID, ids: [String]) {
        guard !ids.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let known = Dictionary(playlists[i].videos.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let fresh = ids.map { YTVideo(id: $0, title: known[$0] ?? "") }
        if fresh != playlists[i].videos {
            playlists[i].videos = fresh
            save()
        }
        lookUpTitles(id)
    }

    /// YouTube's public feed of the playlist (its newest 15 videos, with titles): shows the list
    /// at once, even before the player has started.
    func loadFeed(_ id: UUID) {
        guard !feedLoaded.contains(id), let p = playlist(id), !p.isSingle else { return }
        feedLoaded.insert(id)
        let list = p.listID
        Task {
            guard let videos = await YouTubeStore.feed(list), !videos.isEmpty,
                  let i = playlists.firstIndex(where: { $0.id == id }) else { return }
            if playlists[i].videos.isEmpty {
                playlists[i].videos = videos
            } else {
                let titles = Dictionary(videos.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
                for j in playlists[i].videos.indices where playlists[i].videos[j].title.isEmpty {
                    if let t = titles[playlists[i].videos[j].id] { playlists[i].videos[j].title = t }
                }
            }
            save()
        }
    }

    private func lookUpTitles(_ id: UUID) {
        guard let p = playlist(id) else { return }
        let missing = p.videos.filter { $0.title.isEmpty && !titleLookups.contains($0.id) }.map(\.id)
        guard !missing.isEmpty else { return }
        titleLookups.formUnion(missing)
        Task {
            // A few at a time, so a long playlist doesn't fire hundreds of requests at once.
            var pending = missing[...]
            while !pending.isEmpty {
                let batch = Array(pending.prefix(4))
                pending = pending.dropFirst(4)
                let titles = await withTaskGroup(of: (String, String?).self) { group -> [(String, String?)] in
                    for v in batch {
                        group.addTask { (v, await YouTubeStore.oembedTitle("https://www.youtube.com/watch?v=\(v)")) }
                    }
                    var out: [(String, String?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                self.setTitles(id, titles)
            }
        }
    }

    private func setTitles(_ id: UUID, _ titles: [(String, String?)]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        for (vid, title) in titles {
            guard let title, let j = playlists[i].videos.firstIndex(where: { $0.id == vid }) else { continue }
            playlists[i].videos[j].title = title
            changed = true
        }
        if changed { save() }
    }

    /// Public title lookup (YouTube oEmbed; no key, no account).
    nonisolated static func oembedTitle(_ page: String) async -> String? {
        guard let enc = page.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://www.youtube.com/oembed?format=json&url=" + enc),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let t = obj["title"] as? String, !t.isEmpty else { return nil }
        return t
    }

    nonisolated static func feed(_ list: String) async -> [YTVideo]? {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?playlist_id=\(list)"),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: result.0, encoding: .utf8) else { return nil }
        var out: [YTVideo] = []
        for entry in xml.components(separatedBy: "<entry>").dropFirst() {
            guard let vid = between(entry, "<yt:videoId>", "</yt:videoId>") else { continue }
            let title = between(entry, "<title>", "</title>").map(unescape) ?? ""
            out.append(YTVideo(id: vid, title: title))
        }
        return out
    }

    nonisolated private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }

    nonisolated private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Import screens

struct YouTubeImportSheet: View {
    @EnvironmentObject var yt: YouTubeStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("YouTube playlist or video link", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        if let s = UIPasteboard.general.string { link = s }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Link")
                } footer: {
                    Text("In the YouTube app tap Share > Copy link on a playlist or a video, then paste it here. A single video plays on a loop. Public and unlisted playlists work; private ones don't.")
                }
                if let error {
                    Text(error).foregroundColor(.orange).font(.subheadline)
                }
                Section {
                    Text("Videos play in YouTube's own player inside Loop Player, with the video showing and YouTube's ads as usual. YouTube doesn't allow other apps to download its videos, remove its ads or play them in the background, so they stop when you leave the app or lock the phone.")
                        .font(.footnote)
                        .foregroundColor(Theme.dim)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Add from YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Add") {
                            working = true
                            Task {
                                error = await yt.add(link)
                                working = false
                                if error == nil { dismiss() }
                            }
                        }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if link.isEmpty, let s = UIPasteboard.general.string {
                    let p = YouTubeStore.parse(s)
                    if p.list != nil || p.video != nil { link = s }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct YouTubePlaylistRow: View {
    let playlist: YTPlaylist

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let first = playlist.videoID ?? playlist.videos.first?.id {
                    YTThumb(videoID: first)
                } else {
                    Theme.gradient
                }
                Image(systemName: playlist.isSingle ? "repeat.1" : "play.fill")
                    .font(.caption.weight(.bold))
                    .padding(5)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).lineLimit(1)
                Text(playlist.isSingle ? "YouTube · video on a loop"
                     : (playlist.videos.isEmpty ? "YouTube playlist" : "YouTube · \(playlist.videos.count) videos"))
                    .font(.caption).foregroundColor(Theme.dim)
            }
        }
    }
}

struct YTThumb: View {
    let videoID: String

    var body: some View {
        AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Theme.surface2
        }
    }
}

// MARK: - Player

enum YTLoop: Int { case off, all, one }

/// What the embedded player reports back, and the commands sent to it.
@MainActor
final class YTController: ObservableObject {
    weak var webView: WKWebView?
    @Published var stage = "Connecting to YouTube…"
    @Published var apiLoaded = false
    @Published var ready = false
    @Published var playing = false
    @Published var currentID = ""
    @Published var order: [String] = []
    @Published var shuffle = false
    @Published var loop: YTLoop = .all
    @Published var message: String?
    @Published var failed = false
    var autoplay = false
    /// Videos refused in a row; after a few, stop skipping (YouTube is refusing this phone, not one video).
    var refusedInARow = 0

    /// Events, kept for the automatic simulator test.
    static var testLog: [String] = []
    func note(_ s: String) {
        if YTController.testLog.count < 200 { YTController.testLog.append(s) }
    }

    func js(_ code: String) { webView?.evaluateJavaScript(code, completionHandler: nil) }
    func play() { js("player&&player.playVideo()") }
    func pause() { js("player&&player.pauseVideo()") }
    func next() { js("player&&player.nextVideo()") }
    func previous() { js("player&&player.previousVideo()") }
    func playAt(_ i: Int) { js("player&&player.playVideoAt(\(i))") }

    func setShuffle(_ on: Bool) {
        shuffle = on
        js("player&&(player.setShuffle(\(on)),setTimeout(function(){sendList(0,true)},300))")
    }

    func setLoop(_ mode: YTLoop) {
        loop = mode
        js("setLoopMode(\(mode.rawValue))")
    }

    /// Shows a clear message instead of an endless "loading" if YouTube never answers.
    func watchdog() {
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !apiLoaded {
                fail("Couldn't reach YouTube. Check the internet connection, then open this again.")
            } else if !ready {
                fail("YouTube's player didn't start here. Try again, or use Open in YouTube.")
            }
        }
    }

    func fail(_ text: String) {
        failed = true
        message = text
        stage = text
        note("fail: \(text)")
    }
}

struct YouTubePlaylistView: View {
    let playlistID: UUID
    @EnvironmentObject var yt: YouTubeStore
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ctl = YTController()
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        let p = yt.playlist(playlistID)
        VStack(spacing: 0) {
            if let p {
                YTPlayerWeb(playlist: p, ctl: ctl) { ids in yt.setVideos(playlistID, ids: ids) }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                controls(p)
                if let m = ctl.message {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(m)
                    }
                    .font(.caption).foregroundColor(.orange)
                    .padding(.horizontal).padding(.bottom, 6)
                }
                list(p)
            }
        }
        .background(Theme.bg)
        .navigationTitle(p?.title ?? "YouTube")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { newName = p?.title ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    if let url = p?.youtubeURL {
                        Link(destination: url) { Label("Open in YouTube", systemImage: "arrow.up.right.square") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { yt.rename(playlistID, to: newName) }
        }
        .confirmationDialog("Remove this from Loop Player? It stays on YouTube.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                yt.delete(playlistID)
                dismiss()
            }
        }
        .onAppear {
            if p?.isSingle == true { ctl.loop = .one }
            ctl.autoplay = ProcessInfo.processInfo.environment["TEST_YT_PLAY"] == "1"
            ctl.watchdog()
            yt.loadFeed(playlistID)
        }
        .onChange(of: ctl.playing) { on in
            // One thing plays at a time.
            if on && player.isPlaying { player.pause() }
        }
        .onChange(of: player.isPlaying) { on in if on && ctl.playing { ctl.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // YouTube's rules: no background playback.
            ctl.pause()
        }
        .onDisappear { ctl.pause() }
    }

    private func controls(_ p: YTPlaylist) -> some View {
        HStack {
            Button { ctl.setShuffle(!ctl.shuffle) } label: {
                Image(systemName: "shuffle").foregroundColor(ctl.shuffle ? Theme.accent : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .opacity(p.isSingle ? 0.3 : 1)
            .disabled(p.isSingle)
            Spacer()
            Button { ctl.previous() } label: { Image(systemName: "backward.fill").font(.title2).frame(width: 50, height: 44) }
                .disabled(p.isSingle)
            Spacer()
            Button { ctl.playing ? ctl.pause() : ctl.play() } label: {
                Image(systemName: ctl.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 46))
            }
            .disabled(!ctl.ready)
            Spacer()
            Button { ctl.next() } label: { Image(systemName: "forward.fill").font(.title2).frame(width: 50, height: 44) }
                .disabled(p.isSingle)
            Spacer()
            Button {
                if p.isSingle {
                    ctl.setLoop(ctl.loop == .one ? .off : .one)
                } else {
                    ctl.setLoop(ctl.loop == .off ? .all : (ctl.loop == .all ? .one : .off))
                }
            } label: {
                Image(systemName: ctl.loop == .one ? "repeat.1" : "repeat")
                    .foregroundColor(ctl.loop == .off ? .white.opacity(0.75) : Theme.accent)
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundColor(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func list(_ p: YTPlaylist) -> some View {
        let titles = Dictionary(p.videos.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let shown = ctl.order.isEmpty ? p.videos.map(\.id) : ctl.order
        return List {
            if !ctl.ready || shown.isEmpty {
                HStack(spacing: 10) {
                    if !ctl.failed { ProgressView() }
                    Text(ctl.stage).foregroundColor(ctl.failed ? .orange : Theme.dim).font(.subheadline)
                }
                .listRowBackground(Theme.bg)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, vid in
                Button {
                    if p.isSingle { ctl.play() } else if !ctl.order.isEmpty { ctl.playAt(i) }
                } label: {
                    HStack(spacing: 12) {
                        YTThumb(videoID: vid)
                            .frame(width: 80, height: 45)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(titles[vid].flatMap { $0.isEmpty ? nil : $0 } ?? "Video \(i + 1)")
                            .foregroundColor(vid == ctl.currentID ? Theme.accent : .white)
                            .font(.subheadline.weight(vid == ctl.currentID ? .semibold : .regular))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if vid == ctl.currentID { PlayingBars(animating: ctl.playing) }
                    }
                }
                .listRowBackground(Theme.bg)
            }
            Text(p.isSingle
                 ? "Plays in YouTube's player and starts again at the end (repeat-one button). YouTube doesn't allow background play, so it stops when you leave the app."
                 : "Plays in YouTube's player. YouTube doesn't allow background play or downloads, so it stops when you leave the app. Up to 200 videos of a playlist load.")
                .font(.caption)
                .foregroundColor(Theme.dim)
                .listRowBackground(Theme.bg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// The YouTube IFrame player in a web view.
struct YTPlayerWeb: UIViewRepresentable {
    let playlist: YTPlaylist
    let ctl: YTController
    let onList: ([String]) -> Void

    // The page needs a real https address: YouTube's embed refuses pages without one (error 152/153).
    static let origin = "https://necro144.com"

    func makeCoordinator() -> Coordinator { Coordinator(ctl: ctl, onList: onList, single: playlist.isSingle) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakHandler(context.coordinator), name: "yt")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1"
        ctl.webView = web
        let mode = playlist.isSingle ? "video" : "list"
        let id = playlist.videoID ?? playlist.listID
        let loop = playlist.isSingle ? YTLoop.one.rawValue : ctl.loop.rawValue
        web.loadHTMLString(YTPlayerWeb.page(mode: mode, id: id, loop: loop), baseURL: URL(string: YTPlayerWeb.origin + "/"))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.evaluateJavaScript("player&&player.stopVideo()", completionHandler: nil)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let ctl: YTController
        let onList: ([String]) -> Void
        let single: Bool
        init(ctl: YTController, onList: @escaping ([String]) -> Void, single: Bool) {
            self.ctl = ctl
            self.onList = onList
            self.single = single
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let m = message.body as? [String: Any], let e = m["e"] as? String else { return }
            let ctl = self.ctl
            let onList = self.onList
            let single = self.single
            let ids = (m["ids"] as? [String]) ?? []
            let shuffled = m["shuffled"] as? Bool == true
            let state = m["s"] as? Int ?? -1
            let vid = m["id"] as? String ?? ""
            let code = m["c"] as? Int ?? 0
            let text = m["m"] as? String ?? ""
            Task { @MainActor in
                ctl.note("\(e) s=\(state) c=\(code) n=\(ids.count) \(text)")
                switch e {
                case "api":
                    ctl.apiLoaded = true
                    ctl.stage = single ? "Loading the video…" : "Loading the playlist…"
                case "ready":
                    ctl.apiLoaded = true
                    ctl.ready = true
                    ctl.stage = single ? "Loading the video…" : "Loading the playlist…"
                case "state":
                    ctl.playing = state == 1 || state == 3
                    if !vid.isEmpty { ctl.currentID = vid }
                    if state == 1 { ctl.message = nil; ctl.refusedInARow = 0 }
                    if state == 5 && ctl.autoplay { ctl.autoplay = false; ctl.play() }
                case "list":
                    if ids != ctl.order { ctl.order = ids }
                    if !ctl.shuffle && !shuffled { onList(ids) }
                case "error":
                    switch code {
                    case 100, 101, 150 where ctl.refusedInARow >= 2:
                        ctl.refusedInARow += 1
                        ctl.message = "YouTube refused several videos in a row. That usually means YouTube wants to check you're not a bot (the player then says \"Sign in\"). Play one video in the YouTube app or Safari, then come back, or use Open in YouTube."
                    case 100, 101, 150:
                        ctl.refusedInARow += 1
                        ctl.message = single
                            ? "This video can't be played outside YouTube (removed, private, or its owner turned that off)."
                            : "A video in this playlist can't be played outside YouTube (removed, private, or embedding turned off). Skipped."
                        if !single { ctl.next() }
                    case 2:
                        ctl.fail("YouTube says the link is not valid (error 2).")
                    case 152, 153:
                        ctl.fail("YouTube refused to start its player here (error \(code)). Use Open in YouTube.")
                    default:
                        ctl.message = "YouTube player error \(code)."
                    }
                case "jserror":
                    ctl.note("js error: \(text)")
                default:
                    break
                }
            }
        }
    }

    /// The content controller keeps its handler alive; this stops it keeping the coordinator alive too.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ t: WKScriptMessageHandler) { target = t }
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(uc, didReceive: message)
        }
    }

    /// 1.1.0 handed the playlist to the player when it was created and waited for the list: on
    /// iPhone the list never came until a video played, so the screen stayed on "loading".
    /// Now the player starts empty and the playlist is cued once it is ready, which makes YouTube
    /// send the list straight away (checked in a browser: 200 ids at once).
    static func page(mode: String, id: String, loop: Int) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#p{position:absolute;left:0;top:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        var player=null,lastList='',MODE='\(mode)',ID='\(id)',loopMode=\(loop);
        function post(o){try{window.webkit.messageHandlers.yt.postMessage(o)}catch(e){}}
        window.onerror=function(m){post({e:'jserror',m:String(m)})};
        function sendList(n,shuffled){
          if(MODE!=='list'||!player||!player.getPlaylist)return;
          var l=player.getPlaylist();
          if(l&&l.length){var k=l.join(',');if(k!==lastList||shuffled){lastList=k;post({e:'list',ids:l,shuffled:!!shuffled})}}
          else if(n<40){setTimeout(function(){sendList(n+1,shuffled)},500)}
        }
        function setLoopMode(m){loopMode=m;if(player&&player.setLoop&&MODE==='list'){player.setLoop(m===1)}}
        function onYouTubeIframeAPIReady(){
          post({e:'api'});
          player=new YT.Player('p',{width:'100%',height:'100%',
            playerVars:{playsinline:1,rel:0,modestbranding:1,origin:'\(origin)'},
            events:{
              onReady:function(){
                post({e:'ready'});
                if(MODE==='list'){player.cuePlaylist({listType:'playlist',list:ID,index:0});}
                else{player.cueVideoById(ID);}
                setLoopMode(loopMode);
                setTimeout(function(){sendList(0,false)},300);
              },
              onStateChange:function(ev){
                var d=player.getVideoData?player.getVideoData():{};
                post({e:'state',s:ev.data,id:(d&&d.video_id)||''});
                if(ev.data===0&&loopMode===2){
                  var i=player.getPlaylistIndex?player.getPlaylistIndex():-1;
                  if(MODE==='list'&&i>=0){player.playVideoAt(i)}else{player.seekTo(0,true);player.playVideo()}
                } else if(ev.data===0&&loopMode===1&&MODE==='video'){player.seekTo(0,true);player.playVideo()}
                sendList(0,false);
              },
              onError:function(ev){post({e:'error',c:ev.data})}
            }});
        }
        var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';
        tag.onerror=function(){post({e:'jserror',m:'iframe_api did not load'})};
        document.head.appendChild(tag);
        </script></body></html>
        """
    }
}

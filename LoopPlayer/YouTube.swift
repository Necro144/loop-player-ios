import SwiftUI
import WebKit
import MediaPlayer

// YouTube playlists and single videos play through YouTube's own embedded player (the IFrame
// Player API). Nothing is downloaded and its ads are not touched. 1.4.1 (the owner asked for it):
// it keeps playing in the background and with the screen locked, and shows in Control Center and
// on the lock screen like any song. Videos whose owners turned off embedding are skipped. An optional YouTube Data API
// key (Settings) only reads the full list of a playlist; no account is used.

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
    /// True when the whole playlist came from the YouTube Data API (no 200-video limit).
    var complete: Bool? = nil

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
    @Published var listMessage: [UUID: String] = [:]
    private var titleLookups: Set<String> = []
    private var feedLoaded: Set<UUID> = []

    /// Optional key for YouTube's official Data API (Settings). Without it YouTube's player gives
    /// other apps at most 200 videos of a playlist.
    static var apiKey: String {
        (UserDefaults.standard.string(forKey: "ytApiKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        // A full list from the Data API is never replaced by the player's (at most 200).
        if playlists[i].complete == true { return }
        let known = Dictionary(playlists[i].videos.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let fresh = ids.map { YTVideo(id: $0, title: known[$0] ?? "") }
        if fresh != playlists[i].videos {
            playlists[i].videos = fresh
            save()
        }
        lookUpTitles(id)
    }

    /// Loads the playlist's videos: all of them through YouTube's Data API when a key is set in
    /// Settings, otherwise YouTube's public feed (its newest 15, with titles) until the player
    /// reports its list (up to 200).
    func loadList(_ id: UUID, force: Bool = false) {
        guard force || !feedLoaded.contains(id), let p = playlist(id), !p.isSingle else { return }
        feedLoaded.insert(id)
        let list = p.listID
        let key = YouTubeStore.apiKey
        Task {
            if !key.isEmpty {
                listMessage[id] = "Loading the whole playlist…"
                let result = await YouTubeStore.allVideos(list, key: key)
                guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
                switch result {
                case .success(let videos) where !videos.isEmpty:
                    playlists[i].videos = videos
                    playlists[i].complete = true
                    listMessage[id] = nil
                    save()
                    return
                case .success:
                    listMessage[id] = "YouTube's API returned no videos for this playlist."
                case .failure(let e):
                    listMessage[id] = e.localizedDescription
                }
            }
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

    struct APIError: LocalizedError { let errorDescription: String? }

    /// Every video of a playlist through the official YouTube Data API v3 (50 per page).
    nonisolated static func allVideos(_ list: String, key: String) async -> Result<[YTVideo], APIError> {
        var out: [YTVideo] = []
        var token: String?
        for _ in 0..<100 {
            var c = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var q = [URLQueryItem(name: "part", value: "snippet"), URLQueryItem(name: "maxResults", value: "50"),
                     URLQueryItem(name: "playlistId", value: list), URLQueryItem(name: "key", value: key)]
            if let token { q.append(URLQueryItem(name: "pageToken", value: token)) }
            c.queryItems = q
            guard let url = c.url, let result = try? await URLSession.shared.data(from: url) else {
                return .failure(APIError(errorDescription: "Couldn't reach YouTube's API. Showing what the player gives (up to 200)."))
            }
            let obj = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] ?? [:]
            let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let err = (obj["error"] as? [String: Any])?["message"] as? String ?? "error \(code)"
                return .failure(APIError(errorDescription: "YouTube's API refused the key (\(err)). Check the key in Settings. Showing up to 200 videos."))
            }
            for item in obj["items"] as? [[String: Any]] ?? [] {
                guard let sn = item["snippet"] as? [String: Any],
                      let vid = (sn["resourceId"] as? [String: Any])?["videoId"] as? String else { continue }
                let title = sn["title"] as? String ?? ""
                if title == "Private video" || title == "Deleted video" { continue }
                out.append(YTVideo(id: vid, title: title))
            }
            token = obj["nextPageToken"] as? String
            if token == nil { break }
        }
        return .success(out)
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

/// The app's own queue for YouTube videos. Each video is loaded on its own with the player's most
/// basic call (loadVideoById). 1.1.1 used YouTube's playlist mode (playVideoAt / playVideo on a
/// cued playlist), which on the phone answered "error 2" and did nothing.
@MainActor
final class YTController: ObservableObject, RemoteControllable {
    weak var webView: WKWebView?
    @Published var stage = "Connecting to YouTube…"
    @Published var apiLoaded = false
    @Published var ready = false
    @Published var playing = false
    @Published var currentID = ""
    @Published var shuffle = false
    @Published var loop: YTLoop = .all
    @Published var message: String?
    @Published var failed = false
    /// Play order (ids). `base` is the playlist's own order.
    @Published private(set) var queue: [String] = []
    private var base: [String] = []
    private(set) var index = 0
    var autoplay = false
    /// Videos refused in a row; after a few, stop skipping (YouTube is refusing this phone, not one video).
    var refusedInARow = 0
    /// Last events, shown in the ··· menu (Player Log) to find out what YouTube answered.
    @Published var log: [String] = []
    /// The listener wants it playing (set by play buttons, cleared by pause). When iOS or WebKit
    /// pauses it on leaving the app or locking the screen, it is started again.
    var wantPlaying = false
    /// Video titles for the lock screen.
    var titles: [String: String] = [:]
    private var art: (String, MPMediaItemArtwork)?

    /// Events, kept for the automatic simulator test.
    static var testLog: [String] = []
    func note(_ s: String) {
        if YTController.testLog.count < 300 { YTController.testLog.append(s) }
        log.append(s)
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }

    static func validID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    func js(_ code: String) { webView?.evaluateJavaScript(code, completionHandler: nil) }

    /// The playlist's videos (from the store). Keeps the current video where it is.
    func setList(_ ids: [String]) {
        let clean = ids.filter(YTController.validID)
        guard clean != base else { return }
        base = clean
        if shuffle {
            let rest = clean.filter { $0 != currentID }.shuffled()
            queue = currentID.isEmpty ? rest : [currentID] + rest
        } else {
            queue = clean
        }
        if let i = queue.firstIndex(of: currentID) { index = i } else if index >= queue.count { index = 0 }
    }

    func playIndex(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        let id = queue[i]
        currentID = id
        message = nil
        wantPlaying = true
        note("load \(id)")
        js("loadVid('\(id)')")
    }

    func playID(_ id: String) {
        if let i = queue.firstIndex(of: id) { playIndex(i) }
    }

    func play() {
        if currentID.isEmpty || !ready {
            playIndex(index)
        } else {
            wantPlaying = true
            js("player&&player.playVideo()")
        }
    }

    func pause() {
        wantPlaying = false
        js("player&&player.pauseVideo()")
    }

    // MARK: Background, lock screen and Control Center

    /// The player's state changed (playing, paused, buffering, new video).
    func stateChanged(_ state: Int) {
        if playing {
            Player.shared.startSoundForOtherPlayer()
            if Player.shared.remoteOverride !== self {
                Player.shared.remoteOverride = self
                note("lock screen: YouTube")
            }
        }
        // Paused by iOS, not by the listener (leaving the app, locking the screen): go on.
        if state == 2, wantPlaying, UIApplication.shared.applicationState != .active {
            note("paused in the background; playing on")
            resumeSoon()
        }
        refreshNowPlaying()
    }

    /// The app went to the background or the screen locked.
    func wentToBackground() {
        guard wantPlaying else { return }
        resumeSoon()
    }

    private func resumeSoon() {
        Task {
            for delay in [400_000_000, 1_500_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard wantPlaying else { return }
                if !playing { js("player&&player.playVideo()") }
            }
        }
    }

    /// Fills in the lock screen and Control Center: title, picture, time.
    func refreshNowPlaying() {
        guard Player.shared.remoteOverride === self, !currentID.isEmpty else { return }
        let id = currentID
        let title = titles[id].flatMap { $0.isEmpty ? nil : $0 } ?? "YouTube video"
        webView?.evaluateJavaScript("player&&player.getCurrentTime?[player.getCurrentTime(),player.getDuration()]:[0,0]") { [weak self] r, _ in
            Task { @MainActor in
                guard let self, Player.shared.remoteOverride === self, self.currentID == id else { return }
                let t = (r as? [NSNumber])?.map(\.doubleValue) ?? [0, 0]
                var info: [String: Any] = [
                    MPMediaItemPropertyTitle: title,
                    MPMediaItemPropertyArtist: "YouTube",
                    MPMediaItemPropertyPlaybackDuration: t.count > 1 ? t[1] : 0,
                    MPNowPlayingInfoPropertyElapsedPlaybackTime: t.first ?? 0,
                    MPNowPlayingInfoPropertyPlaybackRate: self.playing ? 1.0 : 0.0,
                    MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                    MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
                ]
                if let a = self.art, a.0 == id { info[MPMediaItemPropertyArtwork] = a.1 }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                if self.art?.0 != id { self.loadArt(id) }
            }
        }
    }

    private func loadArt(_ id: String) {
        guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") else { return }
        Task {
            guard let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) else { return }
            self.art = (id, NowPlayingArt.make(img))
            self.refreshNowPlaying()
        }
    }

    /// Leaving the YouTube screen: give the lock screen back.
    func release() {
        if Player.shared.remoteOverride === self {
            Player.shared.remoteOverride = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }


    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            playIndex(index + 1)
        } else if loop == .all || !auto {
            if shuffle { queue = base.shuffled() }
            playIndex(0)
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        playIndex(index > 0 ? index - 1 : queue.count - 1)
    }

    func setShuffle(_ on: Bool) {
        shuffle = on
        if on {
            let rest = base.filter { $0 != currentID }.shuffled()
            queue = currentID.isEmpty ? rest : [currentID] + rest
        } else {
            queue = base
        }
        index = queue.firstIndex(of: currentID) ?? 0
    }

    func setLoop(_ mode: YTLoop) { loop = mode }

    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteToggle() { playing ? pause() : play() }
    func remoteNext() { next() }
    func remotePrevious() { previous() }
    func remoteSeek(_ seconds: Double) {
        js("player&&player.seekTo(\(seconds),true)")
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            refreshNowPlaying()
        }
    }

    /// A video finished.
    func ended() {
        if loop == .one {
            js("player&&(player.seekTo(0,true),player.playVideo())")
        } else {
            next(auto: true)
        }
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
    @State private var showLog = false

    var body: some View {
        let p = yt.playlist(playlistID)
        VStack(spacing: 0) {
            if let p {
                YTPlayerWeb(playlist: p, ctl: ctl) { ids in yt.setVideos(playlistID, ids: ids) }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                controls(p)
                if let m = ctl.message ?? yt.listMessage[playlistID] {
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
                    if p?.isSingle == false {
                        Button { yt.loadList(playlistID, force: true) } label: { Label("Reload the List", systemImage: "arrow.clockwise") }
                    }
                    if let url = p?.youtubeURL {
                        Link(destination: url) { Label("Open in YouTube", systemImage: "arrow.up.right.square") }
                    }
                    Button { showLog = true } label: { Label("Player Log", systemImage: "doc.text.magnifyingglass") }
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
        .sheet(isPresented: $showLog) { YTLogView(lines: ctl.log) }
        .onAppear {
            if p?.isSingle == true { ctl.loop = .one }
            ctl.autoplay = ProcessInfo.processInfo.environment["TEST_YT_PLAY"] == "1"
            ctl.setList(p?.videos.map(\.id) ?? [])
            ctl.titles = Dictionary((p?.videos ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            ctl.watchdog()
            yt.loadList(playlistID)
        }
        .onChange(of: p?.videos.map(\.id) ?? []) { ids in
            ctl.setList(ids)
            ctl.titles = Dictionary((p?.videos ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        }
        .onChange(of: ctl.playing) { on in
            // One thing plays at a time.
            if on && player.isPlaying { player.pause() }
        }
        .onChange(of: player.isPlaying) { on in if on && ctl.playing { ctl.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Keeps playing in the background and with the screen locked (1.4.1).
            ctl.wentToBackground()
        }
        .onDisappear {
            ctl.pause()
            ctl.release()
        }
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
            .disabled(!ctl.ready || ctl.queue.isEmpty)
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
        let shown = ctl.queue
        return List {
            if !ctl.ready || shown.isEmpty {
                HStack(spacing: 10) {
                    if !ctl.failed { ProgressView() }
                    Text(ctl.stage).foregroundColor(ctl.failed ? .orange : Theme.dim).font(.subheadline)
                }
                .listRowBackground(Theme.bg)
            }
            if !p.isSingle && !shown.isEmpty {
                Text(ctl.shuffle ? "\(shown.count) videos · shuffled" : "\(shown.count) videos")
                    .font(.caption).foregroundColor(Theme.dim)
                    .listRowBackground(Theme.bg)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, vid in
                Button {
                    ctl.playIndex(i)
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
            Text(footer(p))
                .font(.caption)
                .foregroundColor(Theme.dim)
                .listRowBackground(Theme.bg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func footer(_ p: YTPlaylist) -> String {
        var s = "Plays in YouTube's own player, ads as usual. It keeps playing in the background and with the screen locked, and shows in Control Center. It stops when you leave this screen."
        if !p.isSingle && p.complete != true {
            s += "\n\nWithout a YouTube API key, YouTube gives other apps at most 200 videos of a playlist. To load all of them, add a free key in Settings > YouTube."
        }
        return s
    }
}

struct YTLogView: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(lines.isEmpty ? "Nothing yet." : lines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .background(Theme.bg)
            .navigationTitle("Player Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy") { UIPasteboard.general.string = lines.joined(separator: "\n") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// The YouTube IFrame player in a web view.
struct YTPlayerWeb: UIViewRepresentable {
    let playlist: YTPlaylist
    let ctl: YTController
    let onList: ([String]) -> Void

    /// Runs in the page and in YouTube's player frame: the page always says it's on screen, so the
    /// player doesn't pause itself when the app goes to the background or the screen locks.
    static let stayVisible = """
    (function(){
      try {
        Object.defineProperty(document, 'hidden', {get: function(){ return false; }, configurable: true});
        Object.defineProperty(document, 'webkitHidden', {get: function(){ return false; }, configurable: true});
        Object.defineProperty(document, 'visibilityState', {get: function(){ return 'visible'; }, configurable: true});
        Object.defineProperty(document, 'webkitVisibilityState', {get: function(){ return 'visible'; }, configurable: true});
      } catch (e) {}
      var stop = function(e){ e.stopImmediatePropagation(); };
      document.addEventListener('visibilitychange', stop, true);
      document.addEventListener('webkitvisibilitychange', stop, true);
      window.addEventListener('pagehide', stop, true);
      window.addEventListener('blur', stop, true);
    })();
    """

    // The page needs a real https address: YouTube's embed refuses pages without one (error 152/153).
    static let origin = "https://necro144.com"

    func makeCoordinator() -> Coordinator { Coordinator(ctl: ctl, onList: onList, single: playlist.isSingle) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakHandler(context.coordinator), name: "yt")
        config.userContentController.addUserScript(WKUserScript(source: YTPlayerWeb.stayVisible, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        ctl.webView = web
        // Single video: cue it. Playlist: cue the list only to learn its videos (up to 200) when
        // no full list is known; playing always goes through the app's own queue.
        let first: String
        let mode: String
        if let v = playlist.videoID, YTController.validID(v) {
            mode = "video"; first = v
        } else if playlist.complete == true, let v = playlist.videos.first?.id {
            mode = "video"; first = v
        } else {
            mode = "list"; first = playlist.listID
        }
        web.loadHTMLString(YTPlayerWeb.page(mode: mode, id: first), baseURL: URL(string: YTPlayerWeb.origin + "/"))
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
            let state = m["s"] as? Int ?? -1
            let vid = m["id"] as? String ?? ""
            let code = m["c"] as? Int ?? 0
            let text = m["m"] as? String ?? ""
            Task { @MainActor in
                ctl.note("\(e) s=\(state) c=\(code) n=\(ids.count) \(vid) \(text)")
                switch e {
                case "api":
                    ctl.apiLoaded = true
                    ctl.stage = single ? "Loading the video…" : "Loading the playlist…"
                case "ready":
                    ctl.apiLoaded = true
                    ctl.ready = true
                    ctl.stage = single ? "Ready" : "Loading the playlist…"
                    if single || !ctl.queue.isEmpty {
                        if ctl.autoplay { ctl.autoplay = false; ctl.playIndex(ctl.index) }
                    }
                case "state":
                    ctl.playing = state == 1 || state == 3
                    if !vid.isEmpty && YTController.validID(vid) && state != -1 { ctl.currentID = vid }
                    ctl.stateChanged(state)
                    if state == 1 { ctl.message = nil; ctl.refusedInARow = 0 }
                    if state == 0 { ctl.ended() }
                case "list":
                    onList(ids)
                    if ctl.autoplay && !ids.isEmpty {
                        ctl.autoplay = false
                        ctl.setList(ids)
                        ctl.playIndex(0)
                    }
                case "error":
                    switch code {
                    case 100, 101, 150:
                        ctl.refusedInARow += 1
                        if ctl.refusedInARow >= 3 {
                            ctl.message = "YouTube refused several videos in a row. That usually means YouTube wants to check you're not a bot (the player then says \"Sign in\"). Play one video in the YouTube app or Safari, then come back, or use Open in YouTube."
                            break
                        }
                        ctl.message = single
                            ? "This video can't be played outside YouTube (removed, private, or its owner turned that off)."
                            : "A video in this playlist can't be played outside YouTube (removed, private, or embedding turned off). Skipped."
                        if !single { ctl.next(auto: true) }
                    case 2:
                        ctl.message = "YouTube didn't accept video \(ctl.currentID) (error 2). Skipped. Player Log in the ··· menu shows more."
                        if !single && ctl.refusedInARow < 3 { ctl.refusedInARow += 1; ctl.next(auto: true) }
                    case 5:
                        ctl.message = "This video can't play in YouTube's web player (error 5). Skipped."
                        if !single { ctl.next(auto: true) }
                    case 152, 153:
                        ctl.fail("YouTube refused to start its player here (error \(code)). Use Open in YouTube.")
                    default:
                        ctl.message = "YouTube player error \(code)."
                    }
                case "jserror":
                    ctl.message = "Player problem: \(text)"
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

    static func page(mode: String, id: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#p{position:absolute;left:0;top:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        var player=null,listSent=false,MODE='\(mode)',ID='\(id)';
        function post(o){try{window.webkit.messageHandlers.yt.postMessage(o)}catch(e){}}
        window.onerror=function(m){post({e:'jserror',m:String(m)})};
        function sendList(n){
          if(MODE!=='list'||listSent||!player||!player.getPlaylist)return;
          var l=player.getPlaylist();
          if(l&&l.length){listSent=true;post({e:'list',ids:l})}
          else if(n<40){setTimeout(function(){sendList(n+1)},500)}
        }
        function loadVid(v){
          if(!player||!player.loadVideoById){post({e:'jserror',m:'player not ready'});return}
          MODE='video';
          player.loadVideoById({videoId:v});
        }
        function onYouTubeIframeAPIReady(){
          post({e:'api'});
          player=new YT.Player('p',{width:'100%',height:'100%',
            playerVars:{playsinline:1,rel:0,origin:'\(origin)'},
            events:{
              onReady:function(){
                if(MODE==='list'){player.cuePlaylist({listType:'playlist',list:ID});setTimeout(function(){sendList(0)},300);}
                else{player.cueVideoById({videoId:ID});}
                post({e:'ready'});
              },
              onStateChange:function(ev){
                var d=player.getVideoData?player.getVideoData():{};
                post({e:'state',s:ev.data,id:(d&&d.video_id)||''});
                sendList(0);
              },
              onError:function(ev){var d=player.getVideoData?player.getVideoData():{};post({e:'error',c:ev.data,id:(d&&d.video_id)||''})}
            }});
        }
        var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';
        tag.onerror=function(){post({e:'jserror',m:'YouTube player script did not load'})};
        document.head.appendChild(tag);
        </script></body></html>
        """
    }
}

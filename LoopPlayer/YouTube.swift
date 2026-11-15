import SwiftUI
import WebKit

// YouTube playlists play through YouTube's own embedded player (the IFrame Player API), which is
// the way YouTube allows other apps to play its videos. YouTube's rules for that player: the
// video stays visible, nothing is downloaded or played as audio only, and nothing plays in the
// background, so playback stops when the app leaves the screen. Videos whose owners turned off
// embedding are skipped. No API key or Google account is used.

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
}

@MainActor
final class YouTubeStore: ObservableObject {
    static let shared = YouTubeStore()
    @Published private(set) var playlists: [YTPlaylist] = []
    private var titleLookups: Set<String> = []

    private init() {
        playlists = JSONStore.load([YTPlaylist].self, "youtube.json") ?? []
    }

    private func save() { JSONStore.save(playlists, "youtube.json") }

    func playlist(_ id: UUID) -> YTPlaylist? { playlists.first { $0.id == id } }

    /// The playlist id from a YouTube link ("...?list=PL...") or a bare id.
    static func listID(from text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = URLComponents(string: s), let v = c.queryItems?.first(where: { $0.name == "list" })?.value, valid(v) {
            return v
        }
        return valid(s) && s.count >= 12 ? s : nil
    }

    private static func valid(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Adds a playlist; returns an error text if the link is not a playlist.
    func add(_ link: String) async -> String? {
        guard let list = YouTubeStore.listID(from: link) else {
            return "That doesn't look like a YouTube playlist link. Open the playlist on YouTube, tap Share > Copy link, and paste it here."
        }
        if playlists.contains(where: { $0.listID == list }) { return "This playlist is already here." }
        let title = await YouTubeStore.oembedTitle("https://www.youtube.com/playlist?list=\(list)") ?? "YouTube Playlist"
        playlists.insert(YTPlaylist(id: UUID(), listID: list, title: title, videos: [], added: Date()), at: 0)
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

    /// The player reported the playlist's videos (in YouTube's order). Titles are looked up once.
    func setVideos(_ id: UUID, ids: [String]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let known = Dictionary(playlists[i].videos.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let fresh = ids.map { YTVideo(id: $0, title: known[$0] ?? "") }
        if fresh != playlists[i].videos {
            playlists[i].videos = fresh
            save()
        }
        let missing = fresh.filter { $0.title.isEmpty && !titleLookups.contains($0.id) }.map(\.id)
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
              case let data = result.0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["title"] as? String, !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Screens

struct YouTubeImportRow: View {
    @Binding var importing: Bool

    var body: some View {
        Button { importing = true } label: {
            Label("Import YouTube Playlist", systemImage: "play.rectangle.on.rectangle.fill")
                .font(.headline)
                .foregroundColor(Theme.accent)
        }
    }
}

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
                    TextField("https://youtube.com/playlist?list=…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        if let s = UIPasteboard.general.string { link = s }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Playlist link")
                } footer: {
                    Text("In the YouTube app, open the playlist, tap Share > Copy link, then paste it here. Public and unlisted playlists work; private ones don't.")
                }
                if let error {
                    Text(error).foregroundColor(.orange).font(.subheadline)
                }
                Section {
                    Text("Videos play in YouTube's own player inside Loop Player, with the video showing. YouTube doesn't allow other apps to download its videos or play them in the background, so they stop when you leave the app or lock the phone. Videos that can't be played outside YouTube are skipped.")
                        .font(.footnote)
                        .foregroundColor(Theme.dim)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("YouTube Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Import") {
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
                if link.isEmpty, let s = UIPasteboard.general.string, YouTubeStore.listID(from: s) != nil, s.contains("youtu") {
                    link = s
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
                if let first = playlist.videos.first {
                    YTThumb(videoID: first.id)
                } else {
                    Theme.gradient
                }
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .padding(5)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).lineLimit(1)
                Text(playlist.videos.isEmpty ? "YouTube playlist" : "YouTube · \(playlist.videos.count) videos")
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

/// What the embedded player reports back.
@MainActor
final class YTController: ObservableObject {
    weak var webView: WKWebView?
    @Published var ready = false
    @Published var playing = false
    @Published var currentID = ""
    @Published var order: [String] = []
    @Published var shuffle = false
    @Published var loop = true
    @Published var message: String?

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

    func setLoop(_ on: Bool) {
        loop = on
        js("player&&player.setLoop(\(on))")
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
                YTPlayerWeb(listID: p.listID, ctl: ctl) { ids in yt.setVideos(playlistID, ids: ids) }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                controls
                if let m = ctl.message {
                    Text(m).font(.caption).foregroundColor(.orange).padding(.horizontal).padding(.bottom, 6)
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
                    if let p, let url = URL(string: "https://www.youtube.com/playlist?list=\(p.listID)") {
                        Link(destination: url) { Label("Open in YouTube", systemImage: "arrow.up.right.square") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Remove Playlist", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { yt.rename(playlistID, to: newName) }
        }
        .confirmationDialog("Remove this playlist from Loop Player? It stays on YouTube.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove Playlist", role: .destructive) {
                yt.delete(playlistID)
                dismiss()
            }
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

    private var controls: some View {
        HStack {
            Button { ctl.setShuffle(!ctl.shuffle) } label: {
                Image(systemName: "shuffle").foregroundColor(ctl.shuffle ? Theme.accent : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button { ctl.previous() } label: { Image(systemName: "backward.fill").font(.title2).frame(width: 50, height: 44) }
            Spacer()
            Button { ctl.playing ? ctl.pause() : ctl.play() } label: {
                Image(systemName: ctl.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 46))
            }
            .disabled(!ctl.ready)
            Spacer()
            Button { ctl.next() } label: { Image(systemName: "forward.fill").font(.title2).frame(width: 50, height: 44) }
            Spacer()
            Button { ctl.setLoop(!ctl.loop) } label: {
                Image(systemName: "repeat").foregroundColor(ctl.loop ? Theme.accent : .white.opacity(0.75))
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
            if shown.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading the playlist from YouTube…").foregroundColor(Theme.dim)
                }
                .listRowBackground(Theme.bg)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, vid in
                Button {
                    if !ctl.order.isEmpty { ctl.playAt(i) }
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
            Text("Plays in YouTube's player. YouTube doesn't allow background play or downloads, so the music stops when you leave the app. Up to 200 videos of a playlist load.")
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
    let listID: String
    let ctl: YTController
    let onList: ([String]) -> Void

    // The page needs a real https address: YouTube's embed refuses pages without one (error 153).
    static let origin = "https://necro144.com"

    func makeCoordinator() -> Coordinator { Coordinator(ctl: ctl, onList: onList) }

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
        ctl.webView = web
        web.loadHTMLString(YTPlayerWeb.page(listID), baseURL: URL(string: YTPlayerWeb.origin + "/"))
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
        init(ctl: YTController, onList: @escaping ([String]) -> Void) {
            self.ctl = ctl
            self.onList = onList
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let m = message.body as? [String: Any], let e = m["e"] as? String else { return }
            let ctl = self.ctl
            let onList = self.onList
            Task { @MainActor in
                switch e {
                case "ready":
                    ctl.ready = true
                    ctl.js("player.setLoop(\(ctl.loop))")
                case "state":
                    let s = m["s"] as? Int ?? -1
                    ctl.playing = s == 1 || s == 3
                    if let id = m["id"] as? String, !id.isEmpty { ctl.currentID = id }
                    if s == 1 { ctl.message = nil }
                case "list":
                    let ids = (m["ids"] as? [String]) ?? []
                    if ids != ctl.order { ctl.order = ids }
                    if !ctl.shuffle && m["shuffled"] as? Bool != true { onList(ids) }
                case "error":
                    let c = m["c"] as? Int ?? 0
                    switch c {
                    case 100, 101, 150:
                        ctl.message = "A video in this playlist can't be played outside YouTube (removed, private or embedding turned off). Skipped."
                        ctl.next()
                    case 152, 153:
                        ctl.message = "YouTube refused to start the player here (error \(c))."
                    default:
                        ctl.message = "YouTube player error \(c)."
                    }
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

    static func page(_ listID: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#p{position:absolute;left:0;top:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        var player=null,lastList='';
        function post(o){try{window.webkit.messageHandlers.yt.postMessage(o)}catch(e){}}
        function sendList(n,shuffled){
          var l=player&&player.getPlaylist?player.getPlaylist():null;
          if(l&&l.length){var k=l.join(',');if(k!==lastList||shuffled){lastList=k;post({e:'list',ids:l,shuffled:!!shuffled})}}
          else if(n<30){setTimeout(function(){sendList(n+1,shuffled)},500)}
        }
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{width:'100%',height:'100%',
            playerVars:{listType:'playlist',list:'\(listID)',playsinline:1,rel:0,modestbranding:1,origin:'\(origin)'},
            events:{
              onReady:function(){post({e:'ready'});sendList(0,false)},
              onStateChange:function(ev){var d=player.getVideoData?player.getVideoData():{};
                post({e:'state',s:ev.data,id:(d&&d.video_id)||''});sendList(0,false)},
              onError:function(ev){post({e:'error',c:ev.data})}
            }});
        }
        var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';
        document.head.appendChild(tag);
        </script></body></html>
        """
    }
}

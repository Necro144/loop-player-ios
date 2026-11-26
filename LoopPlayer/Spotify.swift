import SwiftUI

// Spotify import: reads a public playlist's or album's track list (names and artists) from
// Spotify's public embed page, the same page any website shows for a shared playlist. No account,
// no key. Spotify's music itself can only be played by Spotify's own app or player, so nothing is
// streamed from Spotify here (and its ads are not touched). Loop Player plays the songs it finds in
// your own files; for the others it can search YouTube.

struct SPTrack: Codable, Hashable {
    var title: String
    var artist: String
    var duration: Double
}

struct SPList: Codable, Identifiable, Hashable {
    let id: UUID
    let spotifyID: String
    let kind: String          // "playlist" or "album"
    var title: String
    var tracks: [SPTrack]
    var added: Date

    var spotifyURL: URL? { URL(string: "https://open.spotify.com/\(kind)/\(spotifyID)") }
}

@MainActor
final class SpotifyStore: ObservableObject {
    static let shared = SpotifyStore()
    @Published private(set) var lists: [SPList] = []

    private init() {
        lists = JSONStore.load([SPList].self, "spotify.json") ?? []
    }

    private func save() { JSONStore.save(lists, "spotify.json") }

    func list(_ id: UUID) -> SPList? { lists.first { $0.id == id } }

    /// (kind, id) from open.spotify.com/playlist/ID, /intl-xx/album/ID, spotify:playlist:ID.
    static func parse(_ text: String) -> (kind: String, id: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]
        if s.hasPrefix("spotify:") {
            parts = s.split(separator: ":").map(String.init)
        } else if let c = URLComponents(string: s.contains("://") ? s : "https://" + s),
                  let host = c.host?.lowercased(), host.contains("spotify") {
            parts = c.path.split(separator: "/").map(String.init)
        } else {
            return nil
        }
        for kind in ["playlist", "album"] {
            if let i = parts.firstIndex(of: kind), i + 1 < parts.count {
                let id = parts[i + 1]
                if id.count >= 10, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    return (kind, id)
                }
            }
        }
        return nil
    }

    func add(_ link: String) async -> String? {
        guard let p = SpotifyStore.parse(link) else {
            return "That isn't a Spotify playlist or album link. In Spotify tap ··· > Share > Copy link, then paste it here."
        }
        if lists.contains(where: { $0.spotifyID == p.id }) { return "This playlist is already here." }
        do {
            let (title, tracks) = try await SpotifyStore.fetch(kind: p.kind, id: p.id)
            lists.insert(SPList(id: UUID(), spotifyID: p.id, kind: p.kind, title: title, tracks: tracks, added: Date()), at: 0)
            save()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refresh(_ id: UUID) async -> String? {
        guard let l = list(id) else { return nil }
        do {
            let (title, tracks) = try await SpotifyStore.fetch(kind: l.kind, id: l.spotifyID)
            if let i = lists.firstIndex(where: { $0.id == id }) {
                lists[i].tracks = tracks
                if lists[i].title.isEmpty { lists[i].title = title }
                save()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func delete(_ id: UUID) {
        lists.removeAll { $0.id == id }
        save()
    }

    struct FetchError: LocalizedError {
        let errorDescription: String?
    }

    nonisolated static func fetch(kind: String, id: String) async throws -> (String, [SPTrack]) {
        guard let url = URL(string: "https://open.spotify.com/embed/\(kind)/\(id)") else {
            throw FetchError(errorDescription: "Bad link.")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            throw FetchError(errorDescription: "Couldn't reach Spotify: \(error.localizedDescription)")
        }
        let data = result.0
        let resp = result.1
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let html = String(data: data, encoding: .utf8) else {
            throw FetchError(errorDescription: code == 404
                             ? "Spotify says this playlist doesn't exist or is private. Only public playlists can be imported."
                             : "Spotify answered with an error (\(code)). Try again later.")
        }
        guard let start = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = html[start.upperBound..<end.lowerBound].data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let page = props["pageProps"] as? [String: Any],
              let state = page["state"] as? [String: Any],
              let d = state["data"] as? [String: Any],
              let entity = d["entity"] as? [String: Any],
              let list = entity["trackList"] as? [[String: Any]] else {
            throw FetchError(errorDescription: "Spotify's page changed and the track list couldn't be read. Tell Necro.")
        }
        let title = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify Playlist"
        let tracks = list.compactMap { t -> SPTrack? in
            guard let name = t["title"] as? String, !name.isEmpty else { return nil }
            let artist = ((t["subtitle"] as? String) ?? "").replacingOccurrences(of: "\u{00a0}", with: " ")
            let ms = (t["duration"] as? Double) ?? Double(t["duration"] as? Int ?? 0)
            return SPTrack(title: name, artist: artist, duration: ms / 1000)
        }
        guard !tracks.isEmpty else { throw FetchError(errorDescription: "This playlist has no songs Spotify shows publicly.") }
        return (title, tracks)
    }
}

/// Finds a Spotify track among your own songs by name (and artist when several match).
struct SongMatcher {
    private var byTitle: [String: [Track]] = [:]
    private var all: [(String, Track)] = []

    init(_ tracks: [Track]) {
        for t in tracks {
            let keys = Set([SongMatcher.norm(t.title), SongMatcher.norm(Scanner.nameGuess(t.fileName).title)])
            for k in keys where !k.isEmpty {
                byTitle[k, default: []].append(t)
                all.append((k, t))
            }
        }
    }

    func find(_ s: SPTrack) -> Track? {
        let key = SongMatcher.norm(s.title)
        guard !key.isEmpty else { return nil }
        let artists = s.artist.split(separator: ",").map { SongMatcher.norm(String($0)) }.filter { !$0.isEmpty }
        func artistFits(_ t: Track) -> Bool {
            let a = SongMatcher.norm(t.artist + " " + t.fileName)
            return artists.contains { a.contains($0) }
        }
        if let exact = byTitle[key], !exact.isEmpty {
            return exact.first(where: artistFits) ?? exact.first
        }
        // "Song (Official Video)", "Artist - Song", "Song feat. X" and so on.
        guard key.count >= 4 else { return nil }
        let loose = all.filter { $0.0.contains(key) || (key.contains($0.0) && $0.0.count >= 6) }.map(\.1)
        return loose.first(where: artistFits) ?? (loose.count == 1 ? loose.first : nil)
    }

    /// Lowercase, no accents, no "(...)" / "[...]", no "feat. ...", letters and digits only.
    static func norm(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        while let r = t.range(of: "\\([^)]*\\)|\\[[^\\]]*\\]", options: .regularExpression) { t.removeSubrange(r) }
        if let r = t.range(of: "\\s(feat\\.?|ft\\.?|featuring)\\s.*$", options: .regularExpression) { t.removeSubrange(r) }
        for w in [" - official video", " - official audio", " - lyrics", " - remastered"] {
            t = t.replacingOccurrences(of: w, with: "")
        }
        let cleaned = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Screens

struct SpotifyImportSheet: View {
    @EnvironmentObject var sp: SpotifyStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://open.spotify.com/playlist/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        if let s = UIPasteboard.general.string { link = s }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Spotify playlist or album link")
                } footer: {
                    Text("In Spotify open the playlist, tap ··· > Share > Copy link, then paste it here. Public playlists and albums work.")
                }
                if let error {
                    Text(error).foregroundColor(.orange).font(.subheadline)
                }
                Section {
                    Text("Loop Player copies the list of songs (names and artists) and plays the ones it finds in your own files, with no ads. Spotify doesn't let other apps play its music, so songs you don't have can be looked up on YouTube instead.")
                        .font(.footnote)
                        .foregroundColor(Theme.dim)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Import from Spotify")
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
                                error = await sp.add(link)
                                working = false
                                if error == nil { dismiss() }
                            }
                        }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if link.isEmpty, let s = UIPasteboard.general.string, SpotifyStore.parse(s) != nil { link = s }
            }
        }
        .preferredColorScheme(Theme.scheme)
    }
}

struct SpotifyListRow: View {
    let list: SPList

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.73, blue: 0.33), Color(red: 0.05, green: 0.3, blue: 0.15)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 54, height: 54)
                .overlay(Image(systemName: "music.note.list").font(.title2).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title).lineLimit(1)
                Text("From Spotify · \(list.tracks.count) songs").font(.caption).foregroundColor(Theme.dim)
            }
        }
    }
}

struct SpotifyListView: View {
    let listID: UUID
    @EnvironmentObject var sp: SpotifyStore
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var matches: [Int: Track] = [:]
    @State private var working = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        let l = sp.list(listID)
        let tracks = l?.tracks ?? []
        let found = tracks.indices.compactMap { matches[$0] }
        List {
            if let l {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l.title).font(.title2.weight(.bold))
                    Text("\(found.count) of \(tracks.count) songs are in your files")
                        .font(.subheadline).foregroundColor(Theme.dim)
                }
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
            }
            if !found.isEmpty {
                PlayShuffleHeader(tracks: found)
            }
            if let error {
                Text(error).foregroundColor(.orange).font(.subheadline).listRowBackground(Theme.bg)
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                if let mine = matches[i] {
                    TrackRow(track: mine, list: found, subtitle: t.artist.isEmpty ? mine.displayArtist : t.artist)
                } else {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surface2)
                            .frame(width: 48, height: 48)
                            .overlay(Image(systemName: "questionmark").foregroundColor(Theme.dim))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).foregroundColor(Theme.dim).lineLimit(1)
                            Text(t.artist.isEmpty ? "Not in your files" : "\(t.artist) · not in your files")
                                .font(.subheadline).foregroundColor(Theme.dim).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let url = youtubeSearch(t) {
                            Link(destination: url) {
                                Image(systemName: "play.rectangle")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(Theme.accent)
                                    .frame(width: 36, height: 40)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
            }
            Text("Songs are matched to your files by name. The ▶︎ button on a missing song searches for it in YouTube.")
                .font(.caption).foregroundColor(Theme.dim)
                .listRowBackground(Theme.bg)
        }
        .darkList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        guard let l else { return }
                        _ = store.createPlaylist(l.title, with: found.map(\.id))
                        player.toast = "Saved \(found.count) songs as playlist \"\(l.title)\""
                    } label: { Label("Save as Playlist", systemImage: "square.and.arrow.down") }
                    .disabled(found.isEmpty)
                    Button {
                        working = true
                        Task {
                            error = await sp.refresh(listID)
                            working = false
                        }
                    } label: { Label("Update from Spotify", systemImage: "arrow.clockwise") }
                    if let url = l?.spotifyURL {
                        Link(destination: url) { Label("Open in Spotify", systemImage: "arrow.up.right.square") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    if working { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("Remove this list from Loop Player? It stays on Spotify.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                sp.delete(listID)
                dismiss()
            }
        }
        .task(id: "\(library.tracks.count)-\(tracks.count)") {
            let lib = library.tracks
            let result = await Task.detached(priority: .userInitiated) { () -> [Int: Track] in
                let m = SongMatcher(lib)
                var out: [Int: Track] = [:]
                for (i, t) in tracks.enumerated() { if let hit = m.find(t) { out[i] = hit } }
                return out
            }.value
            matches = result
        }
    }

    private func youtubeSearch(_ t: SPTrack) -> URL? {
        var c = URLComponents(string: "https://www.youtube.com/results")
        c?.queryItems = [URLQueryItem(name: "search_query", value: "\(t.artist.split(separator: ",").first ?? "") \(t.title)")]
        return c?.url
    }
}

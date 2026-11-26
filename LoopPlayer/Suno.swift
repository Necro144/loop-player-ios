import SwiftUI
import AVFoundation

// Suno songs stream from Suno's public files, the same files suno.com plays for a visitor who is
// not signed in. Nothing is saved except the cover picture. The song plays in the normal player,
// so loop, A-B loop, speed, background play, the lock screen and Control Center all work.
//
// Suno's plain audio file needs a signed-in account; its public share video (cdn1.suno.ai/<id>.mp4,
// H.264 + AAC) does not, and iOS 16 plays its sound. Suno's newer .m4a files are Opus, which
// iOS 16 can't decode, so they are never used.

struct SunoSong: Codable, Identifiable, Hashable {
    let id: String          // Suno clip id
    var title: String
    var artist: String
    var duration: Double
    var stream: String
    var image: String?
    var added: Date
    /// Added while signed in (own or private song): the file is looked up again with the
    /// sign-in each time it plays.
    var auth: Bool? = nil
}

struct SunoList: Codable, Identifiable, Hashable {
    let id: UUID
    let sunoID: String
    var title: String
    var songIDs: [String]
    var added: Date
}

@MainActor
final class SunoStore: ObservableObject {
    static let shared = SunoStore()
    /// Fake folder id that marks streamed Suno tracks.
    static let folderID = UUID(uuidString: "5C0A0000-0000-4000-8000-00000000500A")!

    @Published private(set) var songs: [SunoSong] = []
    @Published private(set) var lists: [SunoList] = []
    private var byID: [String: SunoSong] = [:]

    private struct Saved: Codable {
        var songs: [SunoSong]
        var lists: [SunoList]
    }

    private init() {
        let s = JSONStore.load(Saved.self, "suno.json")
        songs = s?.songs ?? []
        lists = s?.lists ?? []
        byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Task { await fetchMissingCovers() }
    }

    private func save() {
        byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        JSONStore.save(Saved(songs: songs, lists: lists), "suno.json")
    }

    // MARK: Tracks for the player

    static func trackID(_ clip: String) -> String { "\(folderID.uuidString)/suno/\(clip)" }

    func track(_ s: SunoSong) -> Track {
        let id = SunoStore.trackID(s.id)
        let art = FileManager.default.fileExists(atPath: AppPaths.artworkFile(for: id).path)
        return Track(id: id, folderID: SunoStore.folderID, relativePath: "suno/\(s.id).\(URL(string: s.stream)?.pathExtension ?? "mp4")",
                     title: s.title, artist: s.artist, album: "Suno", duration: s.duration, isVideo: false,
                     hasArtwork: art, fileSize: 0, modified: s.added, added: s.added, isPlaceholder: false)
    }

    func track(_ trackID: String) -> Track? {
        let prefix = "\(SunoStore.folderID.uuidString)/suno/"
        guard trackID.hasPrefix(prefix), let s = byID[String(trackID.dropFirst(prefix.count))] else { return nil }
        return track(s)
    }

    var tracks: [Track] { songs.map(track) }

    func tracks(of list: SunoList) -> [Track] { list.songIDs.compactMap { byID[$0] }.map(track) }

    func streamURL(_ t: Track) -> URL? {
        guard t.folderID == SunoStore.folderID else { return nil }
        let clip = ((t.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return byID[clip].flatMap { URL(string: $0.stream) }
    }

    func list(_ id: UUID) -> SunoList? { lists.first { $0.id == id } }

    // MARK: Links

    enum Link { case song(String), playlist(String), short(URL) }

    nonisolated static func parse(_ text: String) -> Link? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "https?://[^\\s]+", options: .regularExpression) ?? (s.contains("suno") ? s.startIndex..<s.endIndex : nil),
              let c = URLComponents(string: s[r].hasPrefix("http") ? String(s[r]) : "https://" + s[r]),
              let host = c.host?.lowercased(), host.hasSuffix("suno.com") || host.hasSuffix("suno.ai") else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "playlist"), i + 1 < parts.count, uuid(parts[i + 1]) { return .playlist(parts[i + 1]) }
        if let id = parts.first(where: uuid) { return .song(id) }
        if parts.first == "s", parts.count >= 2, let u = c.url { return .short(u) }
        return nil
    }

    nonisolated private static func uuid(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    struct SunoError: LocalizedError {
        let errorDescription: String?
        var needsSignIn = false
    }

    /// Adds a song (or every song of a playlist). Returns the songs to play.
    func add(_ link: String) async throws -> [SunoSong] {
        guard var parsed = SunoStore.parse(link) else {
            throw SunoError(errorDescription: "That isn't a Suno link. In Suno tap ··· (or Share) > Copy link, then paste it here.")
        }
        if case .short(let url) = parsed {
            parsed = try await SunoStore.resolve(url)
        }
        switch parsed {
        case .song(let id):
            var song: SunoSong
            do {
                song = try await SunoStore.fetchSong(id, token: nil)
            } catch {
                FolderLog.append("Suno: \(id) has no public file (\(error.localizedDescription))")
                guard SunoAuth.shared.signedIn else {
                    throw SunoError(errorDescription: "This song has no public file on Suno (it is private or unlisted). Sign in to Suno to play your own songs.", needsSignIn: true)
                }
                guard let tok = await SunoAuth.shared.token() else {
                    FolderLog.append("Suno: no sign-in token")
                    throw SunoError(errorDescription: "Suno didn't accept the sign-in. Sign in to Suno again (Settings > Suno).", needsSignIn: true)
                }
                await checkToken(tok)
                let c = try await SunoStore.getJSON(SunoStore.api + "/api/clip/\(id)", token: tok)
                FolderLog.append("Suno: signed-in answer for \(id): \(SunoStore.describe(c))")
                if let s = await SunoStore.song(from: c, token: tok) {
                    song = s
                } else if (c["status"] as? String) == "complete", let s = await SunoStore.song(from: c, token: tok, check: false) {
                    // No file iOS 16 can play by itself (Suno's own audio is Opus): it plays in the Suno tab.
                    FolderLog.append("Suno: \(id) will play in the Suno tab")
                    song = s
                } else {
                    throw SunoError(errorDescription: "Suno is still making this song, or it isn't yours. Try again in a minute.")
                }
                song.auth = true
            }
            insert([song])
            return [song]
        case .playlist(let id):
            let tok = await SunoAuth.shared.token()
            var (title, found) = try await SunoStore.fetchPlaylist(id, token: tok)
            if tok != nil { for i in found.indices { found[i].auth = true } }
            insert(found)
            if let i = lists.firstIndex(where: { $0.sunoID == id }) {
                lists[i].songIDs = found.map(\.id)
                lists[i].title = title
            } else {
                lists.insert(SunoList(id: UUID(), sunoID: id, title: title, songIDs: found.map(\.id), added: Date()), at: 0)
            }
            save()
            return found
        case .short:
            throw SunoError(errorDescription: "This short link didn't lead to a song.")
        }
    }

    /// The file to play and how to open it. Songs added while signed in are looked up again
    /// with a fresh sign-in token (Suno's signed links last about an hour).
    func prepare(_ t: Track) async -> (URL, [String: Any])? {
        let clip = ((t.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let s = byID[clip] else { return nil }
        guard SunoAuth.shared.signedIn else {
            return URL(string: s.stream).map { ($0, [:]) }
        }
        guard let tok = await SunoAuth.shared.token() else {
            FolderLog.append("Suno: no sign-in token for \(s.title)")
            if await SunoStore.reachable(s.stream) { return URL(string: s.stream).map { ($0, [:]) } }
            return nil
        }
        await checkToken(tok)
        do {
            let c = try await SunoStore.getJSON(SunoStore.api + "/api/clip/\(clip)", token: tok)
            FolderLog.append("Suno: signed-in answer for \(s.title): \(SunoStore.describe(c))")
            if let fresh = await SunoStore.song(from: c, token: tok), let url = URL(string: fresh.stream) {
                if fresh.stream != s.stream, let i = songs.firstIndex(where: { $0.id == clip }) {
                    songs[i].stream = fresh.stream
                    save()
                }
                return (url, await SunoStore.options(for: url, token: tok))
            }
        } catch {
            FolderLog.append("Suno: lookup of \(s.title) failed: \(error.localizedDescription)")
        }
        guard let url = URL(string: s.stream), await SunoStore.reachable(s.stream, token: tok) else {
            // Nothing iOS 16 can play here: the Player hands it to the Suno tab.
            return nil
        }
        return (url, await SunoStore.options(for: url, token: tok))
    }

    private var checkedToken: String?

    /// Logs once per token whether Suno accepts it: Suno's song API answers a bad token as if
    /// signed out, so a wrong token only shows as "forbidden" files otherwise.
    func checkToken(_ tok: String) async {
        guard checkedToken != tok else { return }
        checkedToken = tok
        var req = URLRequest(url: URL(string: SunoStore.api + "/api/billing/info/")!, timeoutInterval: 20)
        req.setValue(SunoStore.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        let code = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        FolderLog.append(code == 200 ? "Suno: token accepted by Suno" : "Suno: token NOT accepted by Suno (HTTP \(code), \(tok.count) characters)")
    }

    /// What Suno's answer for a song held (no links, only their kind), for the Folder Log.
    nonisolated static func describe(_ c: [String: Any]) -> String {
        func kind(_ v: Any?) -> String {
            guard let s = v as? String, !s.isEmpty else { return "none" }
            if s.contains("/forbidden") { return "forbidden" }
            guard let u = URL(string: s) else { return "bad" }
            return (u.host ?? "?") + " ." + (u.pathExtension.isEmpty ? "?" : u.pathExtension) + ((u.query ?? "").isEmpty ? "" : " signed")
        }
        return "status=\(c["status"] as? String ?? "?") audio=\(kind(c["audio_url"])) video=\(kind(c["video_url"])) unlocked=\(c["is_download_unlocked"].map { "\($0)" } ?? "none") public=\(c["is_public"].map { "\($0)" } ?? "?")"
    }

    /// Sign-in header and cookies for Suno's own servers (never sent to other hosts).
    static func options(for url: URL, token: String?) async -> [String: Any] {
        guard let host = url.host?.lowercased(), host.hasSuffix("suno.com") || host.hasSuffix("suno.ai") else { return [:] }
        var o: [String: Any] = [:]
        if let token { o["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)", "User-Agent": ua] }
        let cookies = await SunoAuth.shared.cookies(for: url)
        if !cookies.isEmpty { o[AVURLAssetHTTPCookiesKey] = cookies }
        return o
    }

    private func insert(_ new: [SunoSong]) {
        for s in new.reversed() {
            if let i = songs.firstIndex(where: { $0.id == s.id }) {
                var keep = s
                keep.added = songs[i].added
                songs[i] = keep
            } else {
                songs.insert(s, at: 0)
            }
        }
        save()
        Task { await fetchMissingCovers() }
    }

    func delete(_ clip: String) {
        songs.removeAll { $0.id == clip }
        for i in lists.indices { lists[i].songIDs.removeAll { $0 == clip } }
        try? FileManager.default.removeItem(at: AppPaths.artworkFile(for: SunoStore.trackID(clip)))
        save()
    }

    func deleteList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        save()
    }

    /// Cover pictures (the only thing kept on the phone). Fetched again after Clear Cache.
    func fetchMissingCovers() async {
        for s in songs {
            let tid = SunoStore.trackID(s.id)
            let file = AppPaths.artworkFile(for: tid)
            guard !FileManager.default.fileExists(atPath: file.path),
                  let img = s.image, let url = URL(string: img),
                  let r = try? await URLSession.shared.data(from: url),
                  (r.1 as? HTTPURLResponse)?.statusCode == 200,
                  let jpg = Thumbnail.jpeg(from: r.0, maxPixel: 600) else { continue }
            try? FileManager.default.createDirectory(at: AppPaths.artwork, withIntermediateDirectories: true)
            try? jpg.write(to: file, options: .atomic)
            ArtworkCache.shared.forget(tid)
            objectWillChange.send()
            NotificationCenter.default.post(name: .trackUpdated, object: tid)
        }
    }

    // MARK: Suno's API (the calls suno.com makes; with a token when signed in)

    /// The API host suno.com itself uses (the older studio-api.prod.suno.com answers the same).
    nonisolated static let api = "https://studio-api-prod.suno.com"

    nonisolated static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1"

    nonisolated static func getJSON(_ s: String, token: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: s) else { throw SunoError(errorDescription: "Bad link.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(for: req) } catch {
            throw SunoError(errorDescription: "Couldn't reach Suno: \(error.localizedDescription)")
        }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else {
            if token == nil && (code == 404 || code == 403 || code == 401) {
                throw SunoError(errorDescription: "Suno says this song or playlist is private or doesn't exist. Sign in to Suno to play your own songs.", needsSignIn: true)
            }
            throw SunoError(errorDescription: code == 404 || code == 403 || code == 401
                            ? "Suno says this song isn't yours or doesn't exist (\(code))."
                            : "Suno answered with an error (\(code)). Try again later.")
        }
        return obj
    }

    /// suno.com/s/<code> short links lead to /song/<id>.
    nonisolated static func resolve(_ url: URL) async throws -> Link {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let r = try? await URLSession.shared.data(for: req) else {
            throw SunoError(errorDescription: "Couldn't reach Suno to open the short link.")
        }
        let data = r.0
        if let final = r.1.url?.absoluteString, let l = parse(final), !isShort(l) { return l }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        for pat in ["/song/[0-9a-fA-F-]{36}", "/playlist/[0-9a-fA-F-]{36}"] {
            if let r = html.range(of: pat, options: .regularExpression), let l = parse("https://suno.com" + html[r]) { return l }
        }
        throw SunoError(errorDescription: "This short link didn't lead to a song. Open it in Suno and copy the song's own link.")
    }

    nonisolated private static func isShort(_ l: Link) -> Bool { if case .short = l { return true } else { return false } }

    nonisolated static func fetchSong(_ id: String, token: String?) async throws -> SunoSong {
        let c = try await getJSON(api + "/api/clip/\(id)", token: token)
        guard let found = await song(from: c, token: token) else {
            if (c["status"] as? String).map({ $0 != "complete" }) == true {
                throw SunoError(errorDescription: "Suno is still making this song. Try again in a minute.")
            }
            throw SunoError(errorDescription: token == nil
                            ? "Suno has no public file for this song (it is private or unlisted). Sign in to Suno to play your own songs."
                            : "Suno gave no playable file for this song, even signed in. Settings > Folder Log shows what was tried.",
                            needsSignIn: token == nil)
        }
        return found
    }

    nonisolated static func fetchPlaylist(_ id: String, token: String?) async throws -> (String, [SunoSong]) {
        var title = "Suno Playlist"
        var out: [SunoSong] = []
        for page in 1...20 {
            let p = try await getJSON(api + "/api/playlist/\(id)/?page=\(page)", token: token)
            if let n = p["name"] as? String, !n.isEmpty { title = n }
            let items = (p["playlist_clips"] as? [[String: Any]]) ?? []
            for item in items {
                if let c = item["clip"] as? [String: Any], let s = await song(from: c, token: token, check: false),
                   !out.contains(where: { $0.id == s.id }) { out.append(s) }
            }
            let total = (p["num_total_results"] as? Int) ?? 0
            if items.isEmpty || out.count >= total { break }
        }
        guard !out.isEmpty else { throw SunoError(errorDescription: "This playlist has no songs that can be played.") }
        return (title, out)
    }

    /// Picks a file iOS 16 can stream, in this order: the song's own audio (mp3), Suno's
    /// download link when the song is already unlocked (signed in only; never unlocks a song or
    /// uses a download), the public video (H.264 + AAC). Opus .m4a files are skipped.
    nonisolated static func song(from c: [String: Any], token: String? = nil, check: Bool = true) async -> SunoSong? {
        guard let id = c["id"] as? String else { return nil }
        let meta = c["metadata"] as? [String: Any] ?? [:]
        var candidates: [String] = []
        if let a = c["audio_url"] as? String, a.hasPrefix("https://"), !a.contains("/forbidden"),
           !(URL(string: a)?.pathExtension.lowercased() == "m4a") { candidates.append(a) }
        candidates.append("https://cdn1.suno.ai/\(id).mp3")
        if let v = c["video_url"] as? String, v.hasPrefix("https://") { candidates.append(v) }
        candidates.append("https://cdn1.suno.ai/\(id).mp4")
        var stream: String?
        var tried: [String] = []
        if check {
            for u in candidates {
                let (ok, why) = await probe(u, token: token)
                tried.append("\(URL(string: u).map { ($0.host ?? "") + "/…" + "." + $0.pathExtension } ?? u) \(why)")
                if ok { stream = u; break }
                // After the plain audio failed: Suno's download link, only for unlocked songs.
                if u == "https://cdn1.suno.ai/\(id).mp3", let token, (c["is_download_unlocked"] as? Bool) == true,
                   let d = await downloadLink(id, token: token), await reachable(d, token: nil) {
                    stream = d
                    break
                }
            }
            if stream == nil {
                let list = tried.joined(separator: ", ")
                await MainActor.run { FolderLog.append("Suno: no playable file for \(id). Tried: \(list)") }
            }
        } else {
            stream = candidates.last
        }
        guard let stream else { return nil }
        let title = (c["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Suno song"
        let artist = (c["display_name"] as? String) ?? (c["handle"] as? String) ?? ""
        let duration = (meta["duration"] as? Double) ?? Double(meta["duration"] as? Int ?? 0)
        let image = (c["image_large_url"] as? String) ?? (c["image_url"] as? String)
        return SunoSong(id: id, title: title, artist: artist, duration: duration, stream: stream, image: image, added: Date())
    }

    /// Suno's own download link (a signed file link that lasts about an hour).
    nonisolated static func downloadLink(_ id: String, token: String) async -> String? {
        for _ in 0..<6 {
            guard let d = try? await getJSON("https://suno.com/a/api/download/clip/\(id)?format=mp3", token: token) else { return nil }
            if let u = d["download_url"] as? String, u.hasPrefix("https://") { return u }
            if (d["status"] as? String) != "processing" { return nil }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return nil
    }

    nonisolated static func reachable(_ s: String, token: String? = nil) async -> Bool {
        await probe(s, token: token).0
    }

    /// Can iOS stream this file? Also says why not (HTTP status and type), for the Folder Log.
    nonisolated static func probe(_ s: String, token: String? = nil) async -> (Bool, String) {
        guard let url = URL(string: s) else { return (false, "bad link") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let host = url.host?.lowercased() ?? ""
        if let token, host.hasSuffix("suno.com") || host.hasSuffix("suno.ai") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let r = try? await URLSession.shared.data(for: req) else { return (false, "no answer") }
        let code = (r.1 as? HTTPURLResponse)?.statusCode ?? 0
        let type = ((r.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let ok = (code == 200 || code == 206) && !type.contains("xml") && !type.contains("json") && !type.contains("html")
        return (ok, "\(code) \(type)")
    }
}

// MARK: - Screens

struct SunoLinkSheet: View {
    @EnvironmentObject var suno: SunoStore
    @EnvironmentObject var player: Player
    @ObservedObject private var auth = SunoAuth.shared
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    @State private var needsSignIn = false
    @State private var working = false
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://suno.com/song/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        if let s = UIPasteboard.general.string { link = s }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Suno song or playlist link")
                } footer: {
                    Text("In Suno tap ··· or Share > Copy link on a song (or a playlist), then paste it here. It plays right away.")
                }
                if let error {
                    Text(error).foregroundColor(.orange).font(.subheadline)
                }
                Section {
                    if let user = auth.user {
                        Label("Signed in to Suno as \(user)", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    } else {
                        Button { signingIn = true } label: {
                            Label("Sign in to Suno (for your own songs)", systemImage: "person.crop.circle.badge.checkmark")
                                .foregroundColor(needsSignIn ? .white : Theme.accent)
                        }
                        .listRowBackground(needsSignIn ? Theme.accent.opacity(0.6) : Theme.surface2)
                    }
                } footer: {
                    Text("Public songs play without signing in. Your private and unlisted songs need you signed in to Suno.")
                }
                Section {
                    Text("Songs stream from Suno like on suno.com: nothing is downloaded (only the cover picture is kept). Public songs work. Loop, speed, background play and the lock screen work like with your own songs. Needs internet while playing.")
                        .font(.footnote)
                        .foregroundColor(Theme.dim)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Play from Suno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Play") { go() }
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if link.isEmpty, let s = UIPasteboard.general.string, SunoStore.parse(s) != nil { link = s }
            }
            .sheet(isPresented: $signingIn, onDismiss: {
                // Signed in from here: try the link again.
                if auth.signedIn && needsSignIn && !link.isEmpty { go() }
            }) {
                SunoSignInView().environmentObject(SunoAuth.shared)
            }
        }
        .preferredColorScheme(Theme.scheme)
    }

    private func go() {
        working = true
        error = nil
        needsSignIn = false
        Task {
            do {
                let got = try await suno.add(link)
                working = false
                let tracks = got.map { suno.track($0) }
                if !tracks.isEmpty {
                    player.play(tracks)
                    if tracks.count == 1 { player.setRepeat(.one) }
                }
                dismiss()
            } catch {
                working = false
                self.error = error.localizedDescription
                needsSignIn = (error as? SunoStore.SunoError)?.needsSignIn == true && !auth.signedIn
            }
        }
    }
}

struct SunoCover: View {
    var size: CGFloat = 54
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.2), Color(red: 0.55, green: 0.1, blue: 0.45)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "waveform").font(.title2).foregroundColor(.white))
    }
}

struct SunoSongsView: View {
    var listID: UUID? = nil
    @EnvironmentObject var suno: SunoStore
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var confirmDelete = false

    var body: some View {
        let list = listID.flatMap { suno.list($0) }
        let tracks = list.map { suno.tracks(of: $0) } ?? suno.tracks
        List {
            VStack(alignment: .leading, spacing: 6) {
                Text(list?.title ?? "Suno Songs").font(.title2.weight(.bold))
                Text("\(tracks.count) songs · streamed from Suno").font(.subheadline).foregroundColor(Theme.dim)
            }
            .listRowBackground(Theme.bg)
            .listRowSeparator(.hidden)
            if !tracks.isEmpty { PlayShuffleHeader(tracks: tracks) }
            ForEach(tracks) { t in
                TrackRow(track: t, list: tracks)
            }
            .onDelete { offsets in
                if listID == nil {
                    for o in offsets {
                        let clip = ((tracks[o].relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                        suno.delete(clip)
                    }
                }
            }
            Text("These play from Suno over the internet; nothing is downloaded. Swipe a song to remove it from Loop Player (it stays on Suno).")
                .font(.caption).foregroundColor(Theme.dim)
                .listRowBackground(Theme.bg)
        }
        .darkList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { adding = true } label: { Label("Play a Suno Link", systemImage: "link") }
                    if let list {
                        Button {
                            _ = store.createPlaylist(list.title, with: tracks.map(\.id))
                            player.toast = "Saved \(tracks.count) songs as playlist \"\(list.title)\""
                        } label: { Label("Save as Playlist", systemImage: "square.and.arrow.down") }
                        if let url = URL(string: "https://suno.com/playlist/\(list.sunoID)") {
                            Link(destination: url) { Label("Open in Suno", systemImage: "arrow.up.right.square") }
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Remove", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $adding) { SunoLinkSheet() }
        .confirmationDialog("Remove this playlist from Loop Player? Its songs stay in Suno Songs.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let listID { suno.deleteList(listID) }
                dismiss()
            }
        }
    }
}

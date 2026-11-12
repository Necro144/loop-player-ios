import Foundation
import AVFoundation
import UIKit
import ImageIO

/// The chosen folders and every track found in them. Scanning runs off the main thread and
/// the result is cached, so the next launch shows the library at once and only changed files are read again.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var folders: [FolderSource] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var albums: [AlbumGroup] = []
    @Published private(set) var artists: [ArtistGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanDone = 0
    @Published private(set) var scanTotal = 0
    @Published private(set) var unreachableFolders: Set<UUID> = []
    @Published var message: String?

    private(set) var byID: [String: Track] = [:]
    private var folderURLs: [UUID: URL] = [:]
    private var scanTask: Task<Void, Never>?
    private var refreshing: Set<String> = []

    private init() {
        folders = JSONStore.load([FolderSource].self, "folders.json") ?? []
        resolveAll()
        let cached = JSONStore.load([Track].self, "library.json") ?? []
        let known = Set(folders.map(\.id))
        setTracks(cached.filter { known.contains($0.folderID) }, save: false)
        rescan()
    }

    // MARK: Folders

    private func resolveAll() {
        var changed = false
        var bad: Set<UUID> = []
        for i in folders.indices {
            var stale = false
            guard !folders[i].bookmark.isEmpty,
                  let url = try? URL(resolvingBookmarkData: folders[i].bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                bad.insert(folders[i].id)
                log("Could not reopen \(folders[i].name) from its bookmark")
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            folderURLs[folders[i].id] = url
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                folders[i].bookmark = fresh
                changed = true
            }
        }
        unreachableFolders = bad
        if changed { JSONStore.save(folders, "folders.json") }
    }

    func addFolders(_ urls: [URL]) {
        var added = 0
        if urls.isEmpty { log("Picker returned no folder") }
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            log("Picked \(url.path) (access \(access ? "granted" : "not needed or refused"))")
            if let existing = folders.first(where: { folderURLs[$0.id]?.standardizedFileURL == url.standardizedFileURL }) {
                report("\(existing.name) is already in your library.")
                continue
            }
            // Remember the folder for next time. If the system will not make a bookmark,
            // the folder still works until the app is closed, and the user is told.
            var bookmark = Data()
            do {
                bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                log("Bookmark saved (\(bookmark.count) bytes)")
            } catch {
                log("Bookmark failed: \(error.localizedDescription)")
                if let minimal = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    bookmark = minimal
                    log("Minimal bookmark saved (\(minimal.count) bytes)")
                } else {
                    report("\(url.lastPathComponent) was added, but iOS would not let the app remember it. You may need to pick it again after closing the app.")
                }
            }
            let f = FolderSource(id: UUID(), name: url.lastPathComponent, bookmark: bookmark, added: Date())
            folders.append(f)
            folderURLs[f.id] = url
            added += 1
        }
        if added > 0 {
            JSONStore.save(folders, "folders.json")
            rescan()
        }
    }

    /// Shows a message once any closing picker or sheet is out of the way
    /// (an alert started while the picker is still closing is silently dropped by iOS).
    private func report(_ text: String) {
        log(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.message = text }
    }

    // MARK: Folder log (Settings > Folder Log), to see what happened on the phone

    @Published private(set) var folderLog: [String] = (try? String(contentsOf: AppPaths.support.appendingPathComponent("folder-log.txt"), encoding: .utf8))?
        .split(separator: "
").map(String.init) ?? []

    func log(_ line: String) {
        let stamp = Self.stampFormatter.string(from: Date())
        folderLog.append("\(stamp)  \(line)")
        if folderLog.count > 80 { folderLog.removeFirst(folderLog.count - 80) }
        let text = folderLog.joined(separator: "
")
        DispatchQueue.global(qos: .utility).async {
            try? text.write(to: AppPaths.support.appendingPathComponent("folder-log.txt"), atomically: true, encoding: .utf8)
        }
    }

    func clearLog() {
        folderLog = []
        try? FileManager.default.removeItem(at: AppPaths.support.appendingPathComponent("folder-log.txt"))
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        return f
    }()

    func removeFolder(_ id: UUID) {
        folderURLs[id]?.stopAccessingSecurityScopedResource()
        folderURLs[id] = nil
        folders.removeAll { $0.id == id }
        unreachableFolders.remove(id)
        JSONStore.save(folders, "folders.json")
        setTracks(tracks.filter { $0.folderID != id }, save: true)
    }

    func folder(_ id: UUID) -> FolderSource? { folders.first { $0.id == id } }

    func url(for track: Track) -> URL? {
        folderURLs[track.folderID]?.appendingPathComponent(track.relativePath)
    }

    func track(_ id: String) -> Track? { byID[id] }
    func lookup(_ ids: [String]) -> [Track] { ids.compactMap { byID[$0] } }

    // MARK: Scanning

    func rescan() {
        scanTask?.cancel()
        let sources = folders.compactMap { f -> (UUID, URL)? in folderURLs[f.id].map { (f.id, $0) } }
        guard !sources.isEmpty else {
            isScanning = false
            return
        }
        let previous = byID
        isScanning = true
        scanDone = 0
        scanTotal = 0
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await Scanner.scan(sources: sources, previous: previous) { done, total in
                Task { @MainActor in
                    self?.scanDone = done
                    self?.scanTotal = total
                }
            }
            if Task.isCancelled { return }
            await self?.finishScan(result)
        }
    }

    private func finishScan(_ result: [Track]) {
        isScanning = false
        for f in folders {
            let mine = result.filter { $0.folderID == f.id }
            let waiting = mine.filter(\.isPlaceholder).count
            log("Scanned \(f.name): \(mine.count) songs/videos" + (waiting > 0 ? ", \(waiting) still in iCloud (download when played)" : ""))
        }
        setTracks(result, save: true)
    }

    /// Reads the tags again for one file, e.g. after an iCloud file finished downloading.
    func refresh(_ id: String) {
        guard let t = byID[id], let root = folderURLs[t.folderID], !refreshing.contains(id) else { return }
        refreshing.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            let url = root.appendingPathComponent(t.relativePath)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let entry = Scanner.Entry(folderID: t.folderID, url: url, relativePath: t.relativePath,
                                      size: Int64(values?.fileSize ?? 0),
                                      modified: values?.contentModificationDate ?? t.modified,
                                      placeholder: false)
            var fresh = await Scanner.read(entry)
            fresh.added = t.added
            await self?.replace(fresh)
        }
    }

    private func replace(_ t: Track) {
        refreshing.remove(t.id)
        guard let i = tracks.firstIndex(where: { $0.id == t.id }) else { return }
        var list = tracks
        list[i] = t
        setTracks(list, save: true)
        NotificationCenter.default.post(name: .trackUpdated, object: t.id)
    }

    private func setTracks(_ list: [Track], save: Bool) {
        tracks = list
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if save {
            let copy = list
            DispatchQueue.global(qos: .utility).async { JSONStore.save(copy, "library.json") }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let groups = Grouping.build(list)
            await self?.setGroups(groups.0, groups.1)
        }
    }

    private func setGroups(_ a: [AlbumGroup], _ r: [ArtistGroup]) {
        albums = a
        artists = r
    }

    func clearArtworkCache() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: AppPaths.artwork, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
        ArtworkCache.shared.clear()
        // Force all tags and artwork to be read again.
        setTracks([], save: true)
        rescan()
    }

    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }
}

extension Notification.Name {
    static let trackUpdated = Notification.Name("LoopPlayer.trackUpdated")
}

// MARK: - Grouping

enum Grouping {
    static func build(_ tracks: [Track]) -> ([AlbumGroup], [ArtistGroup]) {
        var albumMap: [String: [Track]] = [:]
        var artistMap: [String: [Track]] = [:]
        for t in tracks {
            albumMap[t.displayAlbum.lowercased() + "\u{1}" + (t.album.isEmpty ? t.folderID.uuidString + t.directory : ""), default: []].append(t)
            artistMap[t.displayArtist.lowercased(), default: []].append(t)
        }
        let albums = albumMap.map { key, list -> AlbumGroup in
            let sorted = list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let first = sorted[0]
            let name = first.album.isEmpty ? (first.directory.isEmpty ? "Unknown Album" : (first.directory as NSString).lastPathComponent) : first.album
            let artists = Set(list.map(\.displayArtist))
            return AlbumGroup(id: key, name: name, artist: artists.count == 1 ? first.displayArtist : "Various Artists", tracks: sorted)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let artists = artistMap.map { key, list -> ArtistGroup in
            let sorted = list.sorted {
                let a = $0.displayAlbum.localizedStandardCompare($1.displayAlbum)
                return a == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a == .orderedAscending
            }
            return ArtistGroup(id: key, name: sorted[0].displayArtist, tracks: sorted, albumCount: Set(list.map(\.displayAlbum)).count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (albums, artists)
    }

    static func sort(_ tracks: [Track], by sort: SongSort) -> [Track] {
        switch sort {
        case .title: return tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: return tracks.sorted {
            let a = $0.displayArtist.localizedStandardCompare($1.displayArtist)
            return a == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a == .orderedAscending
        }
        case .album: return tracks.sorted {
            let a = $0.displayAlbum.localizedStandardCompare($1.displayAlbum)
            return a == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a == .orderedAscending
        }
        case .added: return tracks.sorted { $0.modified > $1.modified }
        case .duration: return tracks.sorted { $0.duration > $1.duration }
        }
    }
}

// MARK: - Scanner

enum Scanner {
    struct Entry {
        let folderID: UUID
        let url: URL
        let relativePath: String
        let size: Int64
        let modified: Date
        let placeholder: Bool
        var id: String { folderID.uuidString + "/" + relativePath }
    }

    static func scan(sources: [(UUID, URL)], previous: [String: Track],
                     progress: @escaping (Int, Int) -> Void) async -> [Track] {
        var entries: [Entry] = []
        for (id, root) in sources {
            entries += list(folderID: id, root: root)
            if Task.isCancelled { return [] }
        }
        // De-duplicate: a real file wins over its iCloud placeholder.
        var seen: [String: Int] = [:]
        var unique: [Entry] = []
        for e in entries {
            if let i = seen[e.id] {
                if unique[i].placeholder && !e.placeholder { unique[i] = e }
            } else {
                seen[e.id] = unique.count
                unique.append(e)
            }
        }
        let total = unique.count
        progress(0, total)

        var out: [Track] = []
        out.reserveCapacity(total)
        var toRead: [Entry] = []
        for e in unique {
            if let old = previous[e.id], old.fileSize == e.size, abs(old.modified.timeIntervalSince(e.modified)) < 1,
               old.isPlaceholder == e.placeholder {
                out.append(old)
            } else {
                toRead.append(e)
            }
        }
        var done = out.count
        progress(done, total)

        await withTaskGroup(of: Track.self) { group in
            var it = toRead.makeIterator()
            let width = 6
            for _ in 0..<width {
                guard let e = it.next() else { break }
                group.addTask { await read(e) }
            }
            while let finished = await group.next() {
                var t = finished
                if let old = previous[t.id] { t.added = old.added }
                out.append(t)
                done += 1
                if done % 20 == 0 || done == total { progress(done, total) }
                if Task.isCancelled { group.cancelAll(); break }
                if let e = it.next() { group.addTask { await read(e) } }
            }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func list(folderID: UUID, root: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else { return [] }
        let rootPath = root.standardizedFileURL.path
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath().path
        var out: [Entry] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            var realName = name
            var placeholder = false
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud") && name.count > 8 {
                    realName = String(name.dropFirst().dropLast(7))
                    placeholder = true
                } else {
                    if values?.isDirectory == true { en.skipDescendants() }
                    continue
                }
            }
            if values?.isDirectory == true { continue }
            let ext = (realName as NSString).pathExtension.lowercased()
            guard MediaTypes.isMedia(ext) else { continue }

            let path = url.standardizedFileURL.path
            var rel: String
            if path.hasPrefix(rootPath + "/") {
                rel = String(path.dropFirst(rootPath.count + 1))
            } else {
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(rootResolved + "/") else { continue }
                rel = String(resolved.dropFirst(rootResolved.count + 1))
            }
            if placeholder {
                rel = ((rel as NSString).deletingLastPathComponent as NSString).appendingPathComponent(realName)
            }
            out.append(Entry(folderID: folderID, url: root.appendingPathComponent(rel), relativePath: rel,
                             size: Int64(values?.fileSize ?? 0),
                             modified: values?.contentModificationDate ?? Date.distantPast,
                             placeholder: placeholder))
        }
        return out
    }

    /// Title / artist guessed from a file name like "Artist - Title.mp3".
    static func nameGuess(_ fileName: String) -> (title: String, artist: String) {
        let base = (fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let parts = base.components(separatedBy: " - ")
        if parts.count >= 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            // Leading track numbers like "01 - Title" are not artists.
            if Int(artist) != nil { return (title, "") }
            return (title, artist)
        }
        return (base.isEmpty ? fileName : base, "")
    }

    static func read(_ e: Entry) async -> Track {
        let ext = (e.relativePath as NSString).pathExtension.lowercased()
        let guess = nameGuess((e.relativePath as NSString).lastPathComponent)
        var t = Track(id: e.id, folderID: e.folderID, relativePath: e.relativePath,
                      title: guess.title, artist: guess.artist, album: "", duration: 0,
                      isVideo: MediaTypes.video.contains(ext), hasArtwork: false,
                      fileSize: e.size, modified: e.modified, added: Date(), isPlaceholder: e.placeholder)
        if e.placeholder { return t }

        let asset = AVURLAsset(url: e.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var artData: Data?
        if let items = try? await asset.load(.commonMetadata) {
            var creator = ""
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { t.title = s }
                case .commonKeyArtist:
                    if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { t.artist = s }
                case .commonKeyCreator, .commonKeyAuthor:
                    if let s = try? await item.load(.stringValue), !s.isEmpty { creator = s }
                case .commonKeyAlbumName:
                    if let s = try? await item.load(.stringValue) { t.album = s }
                case .commonKeyArtwork:
                    if artData == nil, let d = try? await item.load(.dataValue) { artData = d }
                default:
                    break
                }
            }
            if t.artist.isEmpty && !creator.isEmpty { t.artist = creator }
        }
        if let d = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(d)
            if s.isFinite { t.duration = s }
        }
        if let v = try? await asset.loadTracks(withMediaType: .video) {
            t.isVideo = !v.isEmpty
        }

        let artURL = AppPaths.artworkFile(for: e.id)
        if let artData, let jpg = Thumbnail.jpeg(from: artData, maxPixel: 700) {
            try? jpg.write(to: artURL, options: .atomic)
            t.hasArtwork = true
        } else if t.isVideo, let jpg = await Thumbnail.videoFrame(asset, duration: t.duration) {
            try? jpg.write(to: artURL, options: .atomic)
            t.hasArtwork = true
        } else {
            try? FileManager.default.removeItem(at: artURL)
        }
        await MainActor.run { ArtworkCache.shared.forget(e.id) }
        return t
    }
}

enum Thumbnail {
    static func jpeg(from data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    static func videoFrame(_ asset: AVAsset, duration: Double) async -> Data? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 700, height: 700)
        let at = duration > 4 ? min(duration * 0.2, 20) : 0
        guard let result = try? await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8)
    }
}

/// In-memory cache over the artwork files written during scanning.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private var missing: Set<String> = []

    init() { cache.countLimit = 400 }

    func cached(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    func image(for track: Track) async -> UIImage? {
        if let img = cache.object(forKey: track.id as NSString) { return img }
        guard track.hasArtwork, !missing.contains(track.id) else { return nil }
        let url = AppPaths.artworkFile(for: track.id)
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }.value
        if let img { cache.setObject(img, forKey: track.id as NSString) } else { missing.insert(track.id) }
        return img
    }

    func forget(_ id: String) {
        cache.removeObject(forKey: id as NSString)
        missing.remove(id)
    }

    func clear() {
        cache.removeAllObjects()
        missing.removeAll()
    }
}

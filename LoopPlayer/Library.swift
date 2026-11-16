import Foundation
import AVFoundation
import UIKit
import ImageIO
import QuickLookThumbnailing
import WebKit
import CoreImage

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
            if var path = folders[i].path {
                // Picked with the built-in browser: opened straight from its path.
                // The app's own folder moves when the app is updated: follow it.
                if let r = path.range(of: #"/Containers/Data/Application/[^/]+"#, options: .regularExpression),
                   !FileManager.default.fileExists(atPath: path) {
                    path = NSHomeDirectory() + path[r.upperBound...]
                    folders[i].path = path
                    changed = true
                }
                if FileManager.default.isReadableFile(atPath: path) {
                    folderURLs[folders[i].id] = URL(fileURLWithPath: path, isDirectory: true)
                } else {
                    bad.insert(folders[i].id)
                    log("Could not open \(folders[i].name) at \(path)")
                }
                continue
            }
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

    /// Folders chosen in the system picker. Nothing slow runs on the main thread here:
    /// on a phone, iCloud Drive can take a long time to answer the first access and the
    /// bookmark request, and waiting for it right after "Open" froze the app.
    func addFolders(_ urls: [URL]) {
        log("Picker returned \(urls.count) folder(s)")
        for url in urls {
            if isAlreadyAdded(url) { continue }
            let f = FolderSource(id: UUID(), name: url.lastPathComponent, bookmark: Data(), added: Date())
            folders.append(f)
            folderURLs[f.id] = url
            log("Adding \(f.name) (\(url.path))")
            let id = f.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let access = url.startAccessingSecurityScopedResource()
                Task { @MainActor in
                    self?.log("Folder access \(access ? "granted" : "not needed or refused"), scanning")
                    self?.rescan()
                }
                var bookmark: Data?
                var problem = ""
                do {
                    bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                } catch {
                    problem = error.localizedDescription
                    bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                let result = bookmark
                let why = problem
                Task { @MainActor in self?.storeBookmark(id, result, why) }
            }
        }
    }

    private func storeBookmark(_ id: UUID, _ data: Data?, _ problem: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        if let data {
            folders[i].bookmark = data
            log("Folder remembered for next time (\(data.count) bytes)" + (problem.isEmpty ? "" : " after: \(problem)"))
        } else {
            log("Could not remember the folder: \(problem)")
            report("\(folders[i].name) was added, but iOS would not let the app remember it. You may need to pick it again after closing the app.")
        }
        JSONStore.save(folders, "folders.json")
    }

    /// On My iPhone > Loop Player (the app's own Documents folder). Always readable, no picker:
    /// songs copied or moved there in the Files app show up here.
    func addAppFolder() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let readme = docs.appendingPathComponent("Put your songs here.txt")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? "Copy or move songs and videos into this folder (Files app > On My iPhone > Loop Player). Folders inside it work too.".write(to: readme, atomically: true, encoding: .utf8)
        }
        addDeviceFolder(docs, name: "Loop Player (On My iPhone)")
    }

    /// A folder chosen with the built-in browser (TrollStore install only).
    func addDeviceFolder(_ url: URL, name: String? = nil) {
        if isAlreadyAdded(url) { return }
        let f = FolderSource(id: UUID(), name: name ?? url.lastPathComponent, bookmark: Data(), added: Date(), path: url.path)
        folders.append(f)
        folderURLs[f.id] = url
        log("Added \(f.name) from the phone browser (\(url.path))")
        JSONStore.save(folders, "folders.json")
        rescan()
    }

    private func isAlreadyAdded(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        guard let existing = folders.first(where: { folderURLs[$0.id]?.standardizedFileURL.path == target }) else { return false }
        report("\(existing.name) is already in your library.")
        return true
    }

    /// Shows a message once any closing picker or sheet is out of the way
    /// (an alert started while the picker is still closing is silently dropped by iOS).
    private func report(_ text: String) {
        log(text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.message = text
        }
    }

    // MARK: Folder log (Settings > Folder Log), to see what happened on the phone

    @Published private(set) var folderLog: [String] = FolderLog.read()

    func log(_ line: String) {
        FolderLog.append(line)
        folderLog = FolderLog.read()
    }

    func reloadLog() { folderLog = FolderLog.read() }

    func clearLog() {
        FolderLog.clear()
        folderLog = []
    }

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
        scanGeneration += 1
        let generation = scanGeneration
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await Scanner.scan(sources: sources, previous: previous, progress: { done, total in
                Task { @MainActor in
                    self?.scanDone = done
                    self?.scanTotal = total
                }
            }, partial: { list in
                // Songs show up (and can be played) while their tags are still being read.
                Task { @MainActor in self?.showPartial(list, generation) }
            })
            if Task.isCancelled { return }
            await self?.finishScan(result)
        }
    }

    private var scanGeneration = 0

    private func showPartial(_ list: [Track], _ generation: Int) {
        guard isScanning, generation == scanGeneration else { return }
        setTracks(list, save: false)
    }

    private func finishScan(_ result: [Track]) {
        isScanning = false
        log("Scan result: \(result.count) files, \(result.filter { $0.duration > 0 }.count) with a length, \(result.filter(\.hasArtwork).count) with artwork, first: \(result.first.map { "\($0.title) / \($0.relativePath)" } ?? "-")")
        for f in folders {
            let mine = result.filter { $0.folderID == f.id }
            let waiting = mine.filter(\.isPlaceholder).count
            log("Scanned \(f.name): \(mine.count) songs/videos" + (waiting > 0 ? ", \(waiting) still in iCloud (download when played)" : ""))
        }
        setTracks(result, save: true)
        fillMissingThumbnails()
    }

    private var thumbTried: Set<String> = []
    private var thumbTask: Task<Void, Never>?
    private var thumbMaking: Set<String> = []

    /// Videos still without a picture after the scan get one now, one at a time and without the
    /// scan's 20-second limit: a frame from the video when the file is on the phone, otherwise the
    /// preview iCloud keeps for it. Songs whose length could not be read are read once more.
    /// Each file is tried once per app launch; what fails is written to the Folder Log.
    func fillMissingThumbnails() {
        thumbTask?.cancel()
        let todo = tracks.filter { t in
            !thumbTried.contains(t.id) && ((t.isVideo && !t.hasArtwork) || (t.duration <= 0 && !t.isPlaceholder))
        }
        guard !todo.isEmpty else { return }
        for t in todo { thumbTried.insert(t.id) }
        let roots = folderURLs
        FolderLog.append("Making pictures / lengths for \(todo.count) files")
        thumbTask = Task.detached(priority: .utility) { [weak self] in
            var made = 0, failed = 0
            for t in todo {
                if Task.isCancelled { return }
                guard let root = roots[t.folderID] else { continue }
                let url = root.appendingPathComponent(t.relativePath)
                var fresh = t
                if !t.isPlaceholder && t.duration <= 0 {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let entry = Scanner.Entry(folderID: t.folderID, url: url, relativePath: t.relativePath,
                                              size: Int64(values?.fileSize ?? Int(t.fileSize)),
                                              modified: values?.contentModificationDate ?? t.modified,
                                              placeholder: false)
                    let read = await Limit.run(45) { await Scanner.read(entry, videoFrame: false) }
                    if let read, read.duration > 0 {
                        fresh = read
                        fresh.added = t.added
                    } else {
                        Scanner.noteFailure("Still could not read \(t.relativePath) (it may still play)")
                    }
                }
                if fresh.isVideo && !fresh.hasArtwork {
                    var jpg: Data?
                    if !t.isPlaceholder {
                        let d = fresh.duration
                        jpg = await Limit.run(60) { await Thumbnail.videoFrame(AVURLAsset(url: url), duration: d, name: t.relativePath) }
                    }
                    if jpg == nil { jpg = await Thumbnail.systemThumbnail(url) }
                    if let jpg {
                        try? jpg.write(to: AppPaths.artworkFile(for: t.id), options: .atomic)
                        fresh.hasArtwork = true
                        made += 1
                        await MainActor.run { ArtworkCache.shared.forget(t.id) }
                    } else {
                        failed += 1
                        Scanner.noteFailure("No picture could be made for \(t.relativePath)")
                    }
                }
                if fresh != t { await self?.replace(fresh) }
            }
            FolderLog.append("Pictures made: \(made), failed: \(failed)")
        }
    }

    /// Picture for a video from the asset the player opened (called when it starts playing).
    func makeThumbnail(_ id: String, from asset: AVAsset, duration: Double) {
        guard !thumbMaking.contains(id) else { return }
        thumbMaking.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            let jpg = await Limit.run(60) { await Thumbnail.videoFrame(asset, duration: duration, name: id) }
            await MainActor.run {
                guard let self else { return }
                self.thumbMaking.remove(id)
                if let jpg { self.setThumbnail(id, jpg: jpg, how: "from the opened file") }
            }
        }
    }

    /// Saves a picture for a video and shows it everywhere.
    func setThumbnail(_ id: String, jpg: Data, how: String) {
        guard var t = byID[id], !t.hasArtwork else { return }
        do {
            try FileManager.default.createDirectory(at: AppPaths.artwork, withIntermediateDirectories: true)
            try jpg.write(to: AppPaths.artworkFile(for: id), options: .atomic)
        } catch {
            FolderLog.append("Couldn't save the picture for \(t.relativePath): \(error.localizedDescription)")
            return
        }
        ArtworkCache.shared.forget(id)
        t.hasArtwork = true
        replace(t)
        FolderLog.append("Picture made for \(t.relativePath) (\(how))")
    }

    /// Settings > Clear Cache: pictures, YouTube's stored player data and downloaded web files.
    /// Songs, playlists, folders and settings stay. Video pictures are made again.
    func clearCache() async -> String {
        let fm = FileManager.default
        var bytes: Int64 = 0
        if let files = try? fm.contentsOfDirectory(at: AppPaths.artwork, includingPropertiesForKeys: [.fileSizeKey]) {
            for f in files {
                bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? fm.removeItem(at: f)
            }
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let files = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.fileSizeKey]) {
            for f in files where f.lastPathComponent != AppPaths.artwork.lastPathComponent {
                bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? fm.removeItem(at: f)
            }
        }
        URLCache.shared.removeAllCachedResponses()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        ArtworkCache.shared.clear()
        thumbTried = []
        thumbMaking = []
        var list = tracks
        for i in list.indices where list[i].hasArtwork { list[i].hasArtwork = false }
        setTracks(list, save: true)
        FolderLog.append("Cache cleared (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))")
        // Song covers come back from the files' tags with a scan; video pictures from the fill pass.
        rescan()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Length learned by the player, for files the scan could not measure.
    func setDuration(_ id: String, _ d: Double) {
        guard var t = byID[id], t.duration <= 0, d > 0 else { return }
        t.duration = d
        replace(t)
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
                     progress: @escaping (Int, Int) -> Void,
                     partial: @escaping ([Track]) -> Void = { _ in }) async -> [Track] {
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
        resetFailures()
        let total = unique.count
        let waiting = unique.filter(\.placeholder).count
        FolderLog.append("Found \(total) songs/videos" + (waiting > 0 ? " (\(waiting) not downloaded yet, read when played)" : "") + ", reading them")
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
        FolderLog.append("\(out.count) unchanged since last scan, \(toRead.count) to read")
        progress(done, total)
        // Everything found so far, with names from the file names until the tags are read.
        var current: [String: Track] = [:]
        for t in out { current[t.id] = t }
        for e in toRead {
            var t = basic(e)
            if let old = previous[e.id] { t = old; t.isPlaceholder = e.placeholder }
            current[t.id] = t
        }
        if !toRead.isEmpty { partial(sorted(Array(current.values))) }
        var lastPartial = Date()

        await withTaskGroup(of: Track.self) { group in
            var it = toRead.makeIterator()
            let width = 4
            for _ in 0..<width {
                guard let e = it.next() else { break }
                group.addTask { await readLimited(e) }
            }
            while let finished = await group.next() {
                var t = finished
                if let old = previous[t.id] { t.added = old.added }
                out.append(t)
                current[t.id] = t
                done += 1
                if Date().timeIntervalSince(lastPartial) > 4 {
                    lastPartial = Date()
                    partial(sorted(Array(current.values)))
                }
                if done % 20 == 0 || done == total { progress(done, total) }
                if Task.isCancelled { group.cancelAll(); break }
                if let e = it.next() { group.addTask { await readLimited(e) } }
            }
        }
        FolderLog.append("Finished reading \(total) songs/videos")
        return sorted(out)
    }

    static func sorted(_ list: [Track]) -> [Track] {
        list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func list(folderID: UUID, root: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
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
            // An iCloud file that is listed but not on the phone: reading its tags now would
            // download it (and every other one) during the scan. It is read when played.
            if !placeholder, values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus,
               status == .notDownloaded {
                placeholder = true
            }

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

    /// Reads one file, but gives up after 20 seconds so one slow or broken file
    /// cannot hold up the whole library.
    static func readLimited(_ e: Entry) async -> Track {
        await withCheckedContinuation { (cont: CheckedContinuation<Track, Never>) in
            let once = Once(cont)
            // Video frames are left to the picture pass after the scan, so big videos can't time out here.
            Task.detached(priority: .userInitiated) { once.resume(await read(e, videoFrame: false)) }
            Task.detached {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if once.resume(basic(e)) {
                    FolderLog.append("Gave up reading \(e.relativePath) after 20 s (it still plays)")
                }
            }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Track, Never>?
        init(_ c: CheckedContinuation<Track, Never>) { cont = c }
        @discardableResult func resume(_ t: Track) -> Bool {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: t)
            return c != nil
        }
    }

    private static let failLock = NSLock()
    private static var failures = 0

    /// Logs the first few files that could not be read in a scan (so one bad folder cannot flood the log).
    static func noteFailure(_ text: String) {
        failLock.lock()
        failures += 1
        let n = failures
        failLock.unlock()
        if n <= 8 { FolderLog.append(text) } else if n == 9 { FolderLog.append("More files could not be read (not all are listed)") }
    }

    static func resetFailures() {
        failLock.lock()
        failures = 0
        reads = 0
        failLock.unlock()
    }

    /// A track made from the file name only.
    static func basic(_ e: Entry) -> Track {
        let ext = (e.relativePath as NSString).pathExtension.lowercased()
        let guess = nameGuess((e.relativePath as NSString).lastPathComponent)
        return Track(id: e.id, folderID: e.folderID, relativePath: e.relativePath,
                     title: guess.title, artist: guess.artist, album: "", duration: 0,
                     isVideo: MediaTypes.video.contains(ext), hasArtwork: false,
                     fileSize: e.size, modified: e.modified, added: Date(), isPlaceholder: e.placeholder)
    }

    static func read(_ e: Entry, videoFrame: Bool = true) async -> Track {
        let ext = (e.relativePath as NSString).pathExtension.lowercased()
        let guess = nameGuess((e.relativePath as NSString).lastPathComponent)
        var t = Track(id: e.id, folderID: e.folderID, relativePath: e.relativePath,
                      title: guess.title, artist: guess.artist, album: "", duration: 0,
                      isVideo: MediaTypes.video.contains(ext), hasArtwork: false,
                      fileSize: e.size, modified: e.modified, added: Date(), isPlaceholder: e.placeholder)
        if e.placeholder { return t }

        let asset = AVURLAsset(url: e.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var artData: Data?
        var items: [AVMetadataItem]?
        do {
            items = try await asset.load(.commonMetadata)
        } catch {
            Scanner.noteFailure("Could not read the tags of \(e.relativePath): \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
        }
        if let items {
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
            if !d.isNumeric { Scanner.noteFailure("No length for \(e.relativePath)") }
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
        } else if t.isVideo, videoFrame, let jpg = await Thumbnail.videoFrame(asset, duration: t.duration, name: e.relativePath) {
            try? jpg.write(to: artURL, options: .atomic)
            t.hasArtwork = true
        } else if t.isVideo && !videoFrame && FileManager.default.fileExists(atPath: artURL.path) {
            t.hasArtwork = true   // picture made earlier by the picture pass
        } else {
            try? FileManager.default.removeItem(at: artURL)
        }
        await MainActor.run { ArtworkCache.shared.forget(e.id) }
        Scanner.noteRead("Read \(e.relativePath): title \"\(t.title)\", \(items?.count ?? -1) tags, \(Int(t.duration)) s, art \(t.hasArtwork), file there \(FileManager.default.fileExists(atPath: e.url.path))")
        return t
    }

    private static var reads = 0
    static func noteRead(_ text: String) {
        failLock.lock()
        reads += 1
        let n = reads
        failLock.unlock()
        if n <= 3 { FolderLog.append(text) }
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

    /// A frame from the video for its thumbnail. Song videos often open on black, so a few
    /// moments are tried and the first one that is not (nearly) black wins.
    static func videoFrame(_ asset: AVAsset, duration: Double, name: String = "") async -> Data? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 700, height: 700)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var d = duration
        if d <= 0, let loaded = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(loaded)
            if s.isFinite { d = s }
        }
        var times: [Double] = d > 4 ? [min(d * 0.25, 30), d * 0.5, min(d * 0.1, 8), 2, 0] : [0]
        times = times.map { max(0, min($0, max(0, d - 0.5))) }
        var best: (CGImage, Double)?
        var lastError: Error?
        for t in times {
            let cg: CGImage
            do {
                cg = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            } catch {
                lastError = error
                continue
            }
            let light = brightness(cg)
            if light > 0.09 { return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) }
            if best == nil || light > best!.1 { best = (cg, light) }
        }
        if best == nil, let lastError {
            let ns = lastError as NSError
            Scanner.noteFailure("Video frame failed for \(name): \(ns.localizedDescription) [\(ns.domain) \(ns.code)]")
        }
        return best.map { UIImage(cgImage: $0.0).jpegData(compressionQuality: 0.8) } ?? nil
    }

    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// JPEG (max 640 px) and brightness of one frame the player decoded.
    static func fromPixelBuffer(_ buf: CVPixelBuffer) -> (Data, Double)? {
        var img = CIImage(cvPixelBuffer: buf)
        let w = img.extent.width
        if w > 640 { img = img.transformed(by: CGAffineTransform(scaleX: 640 / w, y: 640 / w)) }
        guard let cg = ci.createCGImage(img, from: img.extent),
              let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return nil }
        return (jpg, brightness(cg))
    }

    /// Average brightness 0...1, measured on an 8x8 copy.
    static func brightness(_ cg: CGImage) -> Double {
        let w = 8, h = 8
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 1 }
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
        }
        return sum / Double(w * h) / 255
    }

    /// The thumbnail iOS itself shows in the Files app. Works for iCloud videos that are not on
    /// the phone yet (iCloud sends a small preview), so they get a picture without downloading.
    static func systemThumbnail(_ url: URL, seconds: Double = 15) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 350, height: 350),
                                                   scale: 2, representationTypes: .thumbnail)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ d: Data?) {
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                if first { cont.resume(returning: d) }
            }
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                finish(rep?.uiImage.jpegData(compressionQuality: 0.8))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                QLThumbnailGenerator.shared.cancel(request)
                finish(nil)
            }
        }
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

/// Runs `op`, but returns nil after `seconds` if it has not finished (the work itself may go on).
enum Limit {
    static func run<T>(_ seconds: Double, _ op: @escaping () async -> T?) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let box = Box(cont)
            Task.detached { box.resume(await op()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                box.resume(nil)
            }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T?, Never>?
        init(_ c: CheckedContinuation<T?, Never>) { cont = c }
        func resume(_ v: T?) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: v)
        }
    }
}

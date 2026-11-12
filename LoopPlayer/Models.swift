import Foundation

/// One song or video found in a chosen folder.
struct Track: Codable, Identifiable, Hashable {
    /// Stable id: "<folder id>/<path inside the folder>".
    let id: String
    let folderID: UUID
    let relativePath: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var isVideo: Bool
    var hasArtwork: Bool
    var fileSize: Int64
    var modified: Date
    var added: Date
    /// True while the file is only an iCloud placeholder (metadata comes from the file name).
    var isPlaceholder: Bool

    var fileName: String { (relativePath as NSString).lastPathComponent }
    var fileExtension: String { (relativePath as NSString).pathExtension.lowercased() }
    /// Folder part of the path inside the chosen folder ("" for the top level).
    var directory: String { (relativePath as NSString).deletingLastPathComponent }
    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A folder the user picked, remembered with a bookmark.
struct FolderSource: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var bookmark: Data
    var added: Date
}

struct Playlist: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var trackIDs: [String]
    var created: Date
}

struct AlbumGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String
    let tracks: [Track]
    var artworkTrack: Track? { tracks.first(where: { $0.hasArtwork }) ?? tracks.first }
}

struct ArtistGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let tracks: [Track]
    let albumCount: Int
    var artworkTrack: Track? { tracks.first(where: { $0.hasArtwork }) ?? tracks.first }
}

enum RepeatMode: Int, Codable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

enum SongSort: String, CaseIterable, Identifiable {
    case title = "Title", artist = "Artist", album = "Album", added = "Recently Added", duration = "Length"
    var id: String { rawValue }
}

enum MediaTypes {
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "aifc", "caf", "m4b", "alac", "opus"]
    static let video: Set<String> = ["mp4", "mov", "m4v"]
    static func isMedia(_ ext: String) -> Bool { audio.contains(ext) || video.contains(ext) }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatTotal(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    if m >= 60 { return "\(m / 60) hr \(m % 60) min" }
    return "\(m) min"
}

enum AppPaths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoopPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let artwork: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func artworkFile(for trackID: String) -> URL {
        artwork.appendingPathComponent(stableHash(trackID) + ".jpg")
    }

    /// FNV-1a, stable across launches (Swift's hashValue is not).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = AppPaths.support.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = AppPaths.support.appendingPathComponent(name)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

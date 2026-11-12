import Foundation
import SwiftUI

/// Favorites, recently played, play counts and playlists, saved on the phone.
@MainActor
final class UserStore: ObservableObject {
    static let shared = UserStore()

    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var recent: [String] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var playCounts: [String: Int] = [:]

    private struct Saved: Codable {
        var favorites: [String]
        var recent: [String]
        var playlists: [Playlist]
        var playCounts: [String: Int]?
    }

    private init() {
        if let s = JSONStore.load(Saved.self, "user.json") {
            favorites = Set(s.favorites)
            recent = s.recent
            playlists = s.playlists
            playCounts = s.playCounts ?? [:]
        }
    }

    private func save() {
        let s = Saved(favorites: Array(favorites), recent: recent, playlists: playlists, playCounts: playCounts)
        DispatchQueue.global(qos: .utility).async { JSONStore.save(s, "user.json") }
    }

    // MARK: Favorites

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        save()
    }

    // MARK: Recently played

    func markPlayed(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 200 { recent.removeLast(recent.count - 200) }
        playCounts[id, default: 0] += 1
        save()
    }

    func clearRecent() {
        recent.removeAll()
        save()
    }

    func mostPlayed(limit: Int = 50) -> [String] {
        playCounts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String, with ids: [String] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Playlist(id: UUID(), name: trimmed.isEmpty ? "New Playlist" : trimmed, trackIDs: ids, created: Date())
        playlists.append(p)
        save()
        return p
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[i].name = trimmed
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ ids: [String], to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.append(contentsOf: ids)
        save()
    }

    func removeFromPlaylist(_ playlistID: UUID, at offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for o in offsets.sorted(by: >) where o < playlists[i].trackIDs.count {
            playlists[i].trackIDs.remove(at: o)
        }
        save()
    }

    func movePlaylistItems(_ playlistID: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.move(fromOffsets: from, toOffset: to)
        save()
    }

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }
}

import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var suno: SunoStore
    @EnvironmentObject var ui: AppUI

    var body: some View {
        let recent = library.lookup(Array(store.recent.prefix(20)))
        let favorites = library.lookup(Array(store.favorites)).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScanBanner()
                HStack(spacing: 12) {
                    BigButton(title: "Shuffle All", icon: "shuffle", filled: true) {
                        player.play(library.tracks, shuffled: true)
                    }
                    BigButton(title: player.current == nil ? "Play All" : (player.isPlaying ? "Pause" : "Resume"),
                              icon: player.isPlaying ? "pause.fill" : "play.fill", filled: false) {
                        if player.current == nil {
                            player.setShuffle(false)
                            player.play(Grouping.sort(library.tracks, by: .title))
                        } else {
                            player.togglePlay()
                        }
                    }
                }
                .padding(.horizontal)

                Button { ui.showSuno = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                        Text("Play a Suno Link").font(.headline)
                        Spacer()
                        Image(systemName: "link")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.2).opacity(0.85), Color(red: 0.55, green: 0.1, blue: 0.45).opacity(0.85)],
                                               startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)

                if !recent.isEmpty {
                    Shelf(title: "Recently Played", tracks: recent)
                }
                if !suno.songs.isEmpty {
                    Shelf(title: "Suno", tracks: Array(suno.tracks.prefix(20)))
                }
                if !favorites.isEmpty {
                    Shelf(title: "Favorites", tracks: Array(favorites.prefix(20)))
                }
                let added = Array(library.tracks.sorted { $0.modified > $1.modified }.prefix(20))
                if !added.isEmpty {
                    Shelf(title: "Recently Added", tracks: added)
                }
                let videos = library.tracks.filter(\.isVideo)
                if !videos.isEmpty {
                    Shelf(title: "Videos", tracks: Array(videos.prefix(20)), wide: true)
                }
                if library.tracks.isEmpty && !library.isScanning {
                    EmptyState(icon: "music.note", title: "No songs found",
                               text: "The folders you picked have no audio or video files yet. Add another folder in Settings.")
                }
                Color.clear.frame(height: 10)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Loop Player")
        .refreshable { library.rescan() }
    }
}

struct BigButton: View {
    let title: String
    let icon: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundColor(filled ? .white : Theme.accent)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.gradient)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface2)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

struct Shelf: View {
    let title: String
    let tracks: [Track]
    var wide = false
    @EnvironmentObject var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        Button { player.play(tracks, startAt: i) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(track: t, size: wide ? 200 : 140, corner: 10)
                                    .frame(width: wide ? 200 : 140, height: wide ? 112 : 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(alignment: .bottomTrailing) {
                                        if player.current?.id == t.id {
                                            PlayingBars(animating: player.isPlaying)
                                                .padding(6)
                                                .background(.black.opacity(0.6), in: Circle())
                                                .padding(6)
                                        }
                                    }
                                Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(t.displayArtist).font(.caption).foregroundColor(Theme.dim).lineLimit(1)
                            }
                            .frame(width: wide ? 200 : 140, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenuItems(tracks: [t]) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct ScanBanner: View {
    @EnvironmentObject var library: Library

    var body: some View {
        if library.isScanning {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text(library.scanTotal > 0 ? "Scanning \(library.scanDone) of \(library.scanTotal)…" : "Looking for songs…")
                    .font(.subheadline)
                    .foregroundColor(Theme.dim)
                Spacer()
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
        if !library.unreachableFolders.isEmpty {
            Text("Some folders can't be opened any more. Remove them and add them again in Settings.")
                .font(.footnote)
                .foregroundColor(.orange)
                .padding(.horizontal)
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: UserStore

    var body: some View {
        List {
            Section {
                link("Songs", "music.note", library.tracks.count) { TrackListView(title: "Songs", source: .all) }
                link("Albums", "square.stack", library.albums.count) { AlbumsView() }
                link("Artists", "music.mic", library.artists.count) { ArtistsView() }
                link("Folders", "folder", library.folders.count) { FoldersView() }
                link("Videos", "play.rectangle", nil) { TrackListView(title: "Videos", source: .videos) }
                link("Favorites", "heart", store.favorites.count) { TrackListView(title: "Favorites", source: .favorites) }
                link("Recently Played", "clock", nil) { TrackListView(title: "Recently Played", source: .recent, sortable: false) }
                link("Most Played", "flame", nil) { TrackListView(title: "Most Played", source: .mostPlayed, sortable: false) }
            }
            .listRowBackground(Theme.bg)
            .listRowSeparatorTint(Theme.hairline)
            Section {
                ScanBanner()
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
            }
        }
        .darkList()
        .navigationTitle("Library")
        .refreshable { library.rescan() }
    }

    private func link<D: View>(_ title: String, _ icon: String, _ count: Int?, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink {
            dest()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(Theme.accent)
                    .frame(width: 30)
                Text(title).font(.title3)
                Spacer()
                if let count {
                    Text("\(count)").foregroundColor(Theme.dim)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

enum TrackSource: Hashable {
    case all, videos, favorites, recent, mostPlayed
    case artist(String)
    case fixed
}

/// A sortable list of songs. Sorting runs off the main thread so big libraries stay smooth.
struct TrackListView: View {
    let title: String
    var source: TrackSource = .fixed
    var fixed: [Track] = []
    var sortable = true
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: UserStore
    @AppStorage("songSort") private var sortRaw = SongSort.title.rawValue
    @State private var shown: [Track] = []
    @State private var loaded = false

    private var base: [Track] {
        switch source {
        case .all: return library.tracks
        case .videos: return library.tracks.filter(\.isVideo)
        case .favorites: return library.lookup(Array(store.favorites))
        case .recent: return library.lookup(store.recent)
        case .mostPlayed: return library.lookup(store.mostPlayed())
        case .artist(let id): return library.artists.first { $0.id == id }?.tracks ?? []
        case .fixed: return fixed
        }
    }

    var body: some View {
        let items = base
        let key = "\(sortRaw)|\(items.count)|\(items.first?.id ?? "")|\(items.last?.id ?? "")|\(library.tracks.count)"
        List {
            PlayShuffleHeader(tracks: shown)
            if loaded && shown.isEmpty {
                EmptyState(icon: "music.note", title: "Nothing here yet")
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, list: shown, index: i)
            }
        }
        .darkList()
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if sortable {
                    Menu {
                        Picker("Sort", selection: $sortRaw) {
                            ForEach(SongSort.allCases) { s in Text(s.rawValue).tag(s.rawValue) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
            }
        }
        .task(id: key) {
            let sort = SongSort(rawValue: sortRaw) ?? .title
            let doSort = sortable
            let result = await Task.detached(priority: .userInitiated) {
                doSort ? Grouping.sort(items, by: sort) : items
            }.value
            shown = result
            loaded = true
        }
    }
}

// MARK: - Albums and artists

struct AlbumsView: View {
    @EnvironmentObject var library: Library
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.albums) { a in
                    NavigationLink { AlbumDetailView(album: a) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(track: a.artworkTrack, corner: 10)
                            Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(a.artist).font(.caption).foregroundColor(Theme.dim).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenuItems(tracks: a.tracks) }
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Albums")
    }
}

struct AlbumDetailView: View {
    let album: AlbumGroup

    var body: some View {
        List {
            VStack(spacing: 10) {
                ArtworkView(track: album.artworkTrack, size: 220, corner: 12)
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
                Text(album.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text(album.artist).font(.headline).foregroundColor(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Theme.bg)
            .listRowSeparator(.hidden)
            PlayShuffleHeader(tracks: album.tracks)
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, list: album.tracks, index: i)
            }
        }
        .darkList()
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ArtistsView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        List(library.artists) { a in
            NavigationLink {
                TrackListView(title: a.name, source: .artist(a.id))
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: a.artworkTrack, size: 50, corner: 25)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).lineLimit(1)
                        Text("\(a.tracks.count) songs · \(a.albumCount) \(a.albumCount == 1 ? "album" : "albums")")
                            .font(.caption).foregroundColor(Theme.dim)
                    }
                }
            }
            .listRowBackground(Theme.bg)
            .listRowSeparatorTint(Theme.hairline)
        }
        .darkList()
        .navigationTitle("Artists")
    }
}

// MARK: - Folders

struct FoldersView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        List {
            ForEach(library.folders) { f in
                NavigationLink {
                    FolderBrowserView(folderID: f.id, path: "", title: f.name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: library.unreachableFolders.contains(f.id) ? "exclamationmark.triangle.fill" : "folder.fill")
                            .font(.title2)
                            .foregroundColor(library.unreachableFolders.contains(f.id) ? .orange : Theme.accent)
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text("\(library.tracks.lazy.filter { $0.folderID == f.id }.count) files")
                                .font(.caption).foregroundColor(Theme.dim)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.bg)
            }
            AddFolderButton()
                .foregroundColor(Theme.accent)
                .listRowBackground(Theme.bg)
            if DeviceFolders.available {
                BrowsePhoneButton()
                    .foregroundColor(Theme.accent)
                    .listRowBackground(Theme.bg)
            }
            AppFolderButton()
                .foregroundColor(Theme.accent)
                .listRowBackground(Theme.bg)
        }
        .darkList()
        .navigationTitle("Folders")
    }
}

struct FolderBrowserView: View {
    let folderID: UUID
    let path: String
    let title: String
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        let inFolder = library.tracks.filter { $0.folderID == folderID && (path.isEmpty || $0.directory == path || $0.directory.hasPrefix(path + "/")) }
        let here = inFolder.filter { $0.directory == path }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        let subfolders = subfolderCounts(inFolder)
        List {
            PlayShuffleHeader(tracks: inFolder.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending })
            ForEach(subfolders) { sub in
                NavigationLink {
                    FolderBrowserView(folderID: folderID, path: path.isEmpty ? sub.name : path + "/" + sub.name, title: sub.name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").foregroundColor(Theme.accent).font(.title3)
                        Text(sub.name)
                        Spacer()
                        Text("\(sub.count)").foregroundColor(Theme.dim)
                    }
                }
                .listRowBackground(Theme.bg)
            }
            ForEach(Array(here.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, list: here, index: i)
            }
        }
        .darkList()
        .navigationTitle(title)
    }

    private func subfolderCounts(_ tracks: [Track]) -> [SubFolder] {
        var counts: [String: Int] = [:]
        for t in tracks where t.directory != path {
            let rest = path.isEmpty ? t.directory : String(t.directory.dropFirst(path.count + 1))
            let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
            counts[first, default: 0] += 1
        }
        return counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { SubFolder(name: $0.key, count: $0.value) }
    }
}

struct SubFolder: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var library: Library
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var albums: [AlbumGroup] = []
    @State private var artists: [ArtistGroup] = []

    var body: some View {
        List {
            if query.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Search your library",
                           text: "Songs, artists, albums, file and folder names.")
            } else if results.isEmpty && albums.isEmpty && artists.isEmpty {
                EmptyState(icon: "questionmark.circle", title: "No results for \"\(query)\"")
            }
            if !artists.isEmpty {
                Section(header: header("Artists")) {
                    ForEach(artists.prefix(5)) { a in
                        NavigationLink { TrackListView(title: a.name, source: .artist(a.id)) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(track: a.artworkTrack, size: 44, corner: 22)
                                Text(a.name)
                            }
                        }
                        .listRowBackground(Theme.bg)
                    }
                }
            }
            if !albums.isEmpty {
                Section(header: header("Albums")) {
                    ForEach(albums.prefix(5)) { a in
                        NavigationLink { AlbumDetailView(album: a) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(track: a.artworkTrack, size: 44, corner: 6)
                                VStack(alignment: .leading) {
                                    Text(a.name)
                                    Text(a.artist).font(.caption).foregroundColor(Theme.dim)
                                }
                            }
                        }
                        .listRowBackground(Theme.bg)
                    }
                }
            }
            if !results.isEmpty {
                Section(header: header("Songs")) {
                    PlayShuffleHeader(tracks: results)
                    ForEach(Array(results.prefix(300).enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t, list: results, index: i)
                    }
                }
            }
        }
        .darkList()
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task(id: query + "|\(library.tracks.count)") {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = []; albums = []; artists = []; return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let tracks = library.tracks
            let allAlbums = library.albums
            let allArtists = library.artists
            let r = await Task.detached(priority: .userInitiated) { () -> ([Track], [AlbumGroup], [ArtistGroup]) in
                let words = q.lowercased().split(separator: " ").map(String.init)
                func match(_ s: String) -> Bool {
                    let l = s.lowercased()
                    return words.allSatisfy { l.contains($0) }
                }
                let t = tracks.filter { match($0.title + " " + $0.artist + " " + $0.album + " " + $0.relativePath) }
                let al = allAlbums.filter { match($0.name + " " + $0.artist) }
                let ar = allArtists.filter { match($0.name) }
                let sorted = t.sorted { a, b in
                    let aTitle = match(a.title), bTitle = match(b.title)
                    if aTitle != bTitle { return aTitle }
                    return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
                return (sorted, al, ar)
            }.value
            if Task.isCancelled { return }
            results = r.0
            albums = r.1
            artists = r.2
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.title3.weight(.bold)).foregroundColor(.white).textCase(nil)
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var yt: YouTubeStore
    @EnvironmentObject var sp: SpotifyStore
    @EnvironmentObject var suno: SunoStore
    @EnvironmentObject var ui: AppUI
    @State private var importingYT = false
    @State private var importingSP = false
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        List {
            Button { naming = true } label: {
                Label("New Playlist", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundColor(Theme.accent)
            }
            .listRowBackground(Theme.bg)
            NavigationLink { TrackListView(title: "Favorites", source: .favorites) } label: {
                smart("Favorites", "heart.fill", "\(store.favorites.count) songs")
            }
            .listRowBackground(Theme.bg)
            NavigationLink { TrackListView(title: "Recently Played", source: .recent, sortable: false) } label: {
                smart("Recently Played", "clock.fill", "Last \(store.recent.count)")
            }
            .listRowBackground(Theme.bg)
            ForEach(store.playlists) { p in
                NavigationLink { PlaylistDetailView(playlistID: p.id) } label: {
                    HStack(spacing: 12) {
                        PlaylistCover(playlist: p, size: 54)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text("\(p.trackIDs.count) songs").font(.caption).foregroundColor(Theme.dim)
                        }
                    }
                }
                .listRowBackground(Theme.bg)
            }
            .onDelete { offsets in
                for o in offsets { store.deletePlaylist(store.playlists[o].id) }
            }
            Section {
                Button { ui.showSuno = true } label: {
                    Label("Play a Suno Link", systemImage: "waveform")
                        .font(.headline)
                        .foregroundColor(Theme.accent)
                }
                .listRowBackground(Theme.bg)
                if !suno.songs.isEmpty {
                    NavigationLink { SunoSongsView() } label: {
                        HStack(spacing: 12) {
                            SunoCover()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Suno Songs").lineLimit(1)
                                Text("\(suno.songs.count) songs · streamed").font(.caption).foregroundColor(Theme.dim)
                            }
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
                ForEach(suno.lists) { l in
                    NavigationLink { SunoSongsView(listID: l.id) } label: {
                        HStack(spacing: 12) {
                            SunoCover()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.title).lineLimit(1)
                                Text("Suno playlist · \(l.songIDs.count) songs").font(.caption).foregroundColor(Theme.dim)
                            }
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
                .onDelete { offsets in
                    for o in offsets { suno.deleteList(suno.lists[o].id) }
                }
            } header: {
                Text("Suno")
            }
            Section {
                Button { importingYT = true } label: {
                    Label("Add YouTube Playlist or Video", systemImage: "play.rectangle.on.rectangle.fill")
                        .font(.headline)
                        .foregroundColor(Theme.accent)
                }
                .listRowBackground(Theme.bg)
                ForEach(yt.playlists) { p in
                    NavigationLink { YouTubePlaylistView(playlistID: p.id) } label: {
                        YouTubePlaylistRow(playlist: p)
                    }
                    .listRowBackground(Theme.bg)
                }
                .onDelete { offsets in
                    for o in offsets { yt.delete(yt.playlists[o].id) }
                }
            } header: {
                Text("YouTube")
            }
            Section {
                Button { importingSP = true } label: {
                    Label("Import Spotify Playlist", systemImage: "music.note.list")
                        .font(.headline)
                        .foregroundColor(Theme.accent)
                }
                .listRowBackground(Theme.bg)
                ForEach(sp.lists) { l in
                    NavigationLink { SpotifyListView(listID: l.id) } label: {
                        SpotifyListRow(list: l)
                    }
                    .listRowBackground(Theme.bg)
                }
                .onDelete { offsets in
                    for o in offsets { sp.delete(sp.lists[o].id) }
                }
            } header: {
                Text("Spotify")
            }
        }
        .darkList()
        .navigationTitle("Playlists")
        .sheet(isPresented: $importingYT) { YouTubeImportSheet() }
        .sheet(isPresented: $importingSP) { SpotifyImportSheet() }
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") { store.createPlaylist(newName); newName = "" }
        }
    }

    private func smart(_ title: String, _ icon: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.gradient)
                .frame(width: 54, height: 54)
                .overlay(Image(systemName: icon).font(.title2).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(sub).font(.caption).foregroundColor(Theme.dim)
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var adding = false
    @State private var confirmDelete = false

    var body: some View {
        let playlist = store.playlist(playlistID)
        let entries: [(Int, Track)] = (playlist?.trackIDs ?? []).enumerated().compactMap { i, id in
            library.track(id).map { (i, $0) }
        }
        let tracks = entries.map { $0.1 }
        List {
            if let playlist {
                VStack(spacing: 8) {
                    PlaylistCover(playlist: playlist, size: 180)
                    Text(playlist.name).font(.title2.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
            }
            PlayShuffleHeader(tracks: tracks)
            ForEach(Array(entries.enumerated()), id: \.offset) { pos, entry in
                TrackRow(track: entry.1, list: tracks, index: pos)
            }
            .onMove { from, to in
                // Rows map 1:1 to stored ids only when none are missing; fall back to ids otherwise.
                if entries.count == playlist?.trackIDs.count {
                    store.movePlaylistItems(playlistID, from: from, to: to)
                }
            }
            .onDelete { offsets in
                let real = IndexSet(offsets.map { entries[$0].0 })
                store.removeFromPlaylist(playlistID, at: real)
            }
            Button { adding = true } label: {
                Label("Add Songs", systemImage: "plus").foregroundColor(Theme.accent)
            }
            .listRowBackground(Theme.bg)
        }
        .darkList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                EditButton()
                Menu {
                    Button { newName = playlist?.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.renamePlaylist(playlistID, to: newName) }
        }
        .confirmationDialog("Delete this playlist? Your song files are not touched.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                store.deletePlaylist(playlistID)
                dismiss()
            }
        }
        .sheet(isPresented: $adding) {
            SongPickerView { ids in store.add(ids, to: playlistID) }
        }
    }
}

struct SongPickerView: View {
    let onDone: ([String]) -> Void
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []
    @State private var query = ""

    var body: some View {
        let q = query.lowercased()
        let list = Grouping.sort(library.tracks, by: .title).filter {
            q.isEmpty || ($0.title + " " + $0.artist + " " + $0.album).lowercased().contains(q)
        }
        NavigationStack {
            List(list) { t in
                Button {
                    if let i = picked.firstIndex(of: t.id) { picked.remove(at: i) } else { picked.append(t.id) }
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(track: t, size: 42, corner: 5)
                        VStack(alignment: .leading) {
                            Text(t.title).foregroundColor(.white).lineLimit(1)
                            Text(t.displayArtist).font(.caption).foregroundColor(Theme.dim).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: picked.contains(t.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(picked.contains(t.id) ? Theme.accent : Theme.dim)
                    }
                }
                .listRowBackground(Theme.bg)
            }
            .darkList()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(picked.isEmpty ? "Add Songs" : "\(picked.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onDone(picked); dismiss() }.disabled(picked.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore
    @State private var confirmClear = false
    @State private var removing: FolderSource?
    @State private var showSpeed = false
    @State private var confirmCache = false
    @State private var cacheResult: String?
    @State private var clearing = false
    @State private var ytKey = UserDefaults.standard.string(forKey: "ytApiKey") ?? ""
    @State private var igAppID = UserDefaults.standard.string(forKey: "igAppID") ?? ""
    @State private var snapClientID = UserDefaults.standard.string(forKey: "snapClientID") ?? ""
    @State private var lockReport: [String]?
    @ObservedObject private var suno = SunoAuth.shared
    @State private var sunoSignIn = false

    var body: some View {
        List {
            Section {
                ForEach(library.folders) { f in
                    HStack(spacing: 12) {
                        Image(systemName: library.unreachableFolders.contains(f.id) ? "exclamationmark.triangle.fill" : "folder.fill")
                            .foregroundColor(library.unreachableFolders.contains(f.id) ? .orange : Theme.accent)
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text(library.unreachableFolders.contains(f.id) ? "Can't be opened. Remove and add it again." :
                                    "\(library.tracks.lazy.filter { $0.folderID == f.id }.count) files")
                                .font(.caption).foregroundColor(Theme.dim)
                        }
                        Spacer()
                        Button { removing = f } label: {
                            Image(systemName: "minus.circle.fill").foregroundColor(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                }
                AddFolderButton().foregroundColor(Theme.accent)
                if DeviceFolders.available { BrowsePhoneButton().foregroundColor(Theme.accent) }
                AppFolderButton().foregroundColor(Theme.accent)
            } header: {
                Text("Folders")
            } footer: {
                Text("Songs stay where they are. The app only reads them. Subfolders are included.")
            }

            Section("Library") {
                HStack {
                    Text("Songs and videos")
                    Spacer()
                    Text("\(library.tracks.count)").foregroundColor(Theme.dim)
                }
                HStack {
                    Text("Total length")
                    Spacer()
                    Text(formatTotal(library.totalDuration)).foregroundColor(Theme.dim)
                }
                Button {
                    library.rescan()
                } label: {
                    HStack {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                        Spacer()
                        if library.isScanning {
                            ProgressView()
                            Text("\(library.scanDone)/\(library.scanTotal)").font(.caption).foregroundColor(Theme.dim)
                        }
                    }
                }
                .disabled(library.isScanning)
                Button { confirmClear = true } label: {
                    Label("Rebuild Library and Artwork", systemImage: "photo.on.rectangle.angled")
                }
                Button { confirmCache = true } label: {
                    HStack {
                        Label("Clear Cache", systemImage: "trash")
                        Spacer()
                        if clearing { ProgressView() } else if let cacheResult { Text(cacheResult).font(.caption).foregroundColor(Theme.dim) }
                    }
                }
                .disabled(clearing)
            }

            Section {
                NavigationLink {
                    FolderLogView()
                } label: {
                    Label("Folder Log", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                Text("What happened when folders were picked and scanned. Useful if a folder does not show up.")
            }

            Section {
                Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.setRepeat($0) })) {
                    Text("Off").tag(RepeatMode.off)
                    Text("All").tag(RepeatMode.all)
                    Text("One (loop)").tag(RepeatMode.one)
                }
                Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.setShuffle($0) }))
                Button { showSpeed = true } label: {
                    HStack {
                        Text("Speed").foregroundColor(.white)
                        Spacer()
                        Text(rateLabel(player.rate)).foregroundColor(Theme.dim)
                    }
                }
                Toggle("Keep pitch when changing speed", isOn: Binding(get: { player.keepPitch }, set: { player.setKeepPitch($0) }))
                Toggle("Play along with other apps (hides lock screen controls)", isOn: Binding(get: { player.mixWithOthers }, set: { player.setMixWithOthers($0) }))
                Button { lockReport = player.lockScreenReport() } label: {
                    Label("Lock Screen Check", systemImage: "lock.iphone")
                }
                Button(role: .destructive) { store.clearRecent() } label: {
                    Label("Clear Recently Played", systemImage: "clock.arrow.circlepath")
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Keep pitch off: slowing down sounds deeper, like a tape. \"Play along with other apps\" keeps the music going when another app plays sound, but iOS then hides the song on the lock screen and in Control Center, so leave it off to see them.")
            }

            Section {
                if let user = suno.user {
                    HStack {
                        Label("Signed in as \(user)", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                        Spacer()
                    }
                    Button(role: .destructive) { Task { await suno.signOut() } } label: {
                        Label("Sign Out of Suno", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Button { sunoSignIn = true } label: {
                        Label("Sign in to Suno", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            } header: {
                Text("Suno")
            } footer: {
                Text("Sign in to play your own private or unlisted Suno songs from their links. You sign in on Suno's own page; Loop Player never sees your password. Songs still stream: nothing is downloaded.")
            }

            Section {
                SecureField("YouTube API key (optional)", text: $ytKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: ytKey) { v in
                        UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ytApiKey")
                    }
            } header: {
                Text("YouTube")
            } footer: {
                Text("Without a key, YouTube gives other apps at most 200 videos of a playlist. With your own free key, Loop Player loads all of them. To get one: console.cloud.google.com > create a project > APIs & Services > Library > enable \"YouTube Data API v3\" > Credentials > Create credentials > API key. Paste it here, then open the playlist and choose Reload the List.\n\nYouTube videos keep playing in the background and with the screen locked, and show in Control Center.")
            }

            Section {
                Button {
                    ClipMaker.shared.source = .nowPlaying
                    ClipMaker.shared.openStudio = true
                } label: { Label("Open Clip Studio", systemImage: "wand.and.stars") }
                TextField("Facebook App ID (for Instagram Stories)", text: $igAppID)
                    .keyboardType(.numberPad)
                    .onChange(of: igAppID) { v in
                        UserDefaults.standard.set(v.filter(\.isNumber), forKey: "igAppID")
                    }
                TextField("Snap Kit client ID (for Snapchat)", text: $snapClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: snapClientID) { v in
                        UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "snapClientID")
                    }
            } header: {
                Text("Share a Clip")
            } footer: {
                Text("Clip Studio (the share button in the player, or here): pick the playing video or song, or a photo or video from your library; its size (Story 9:16, Square, Portrait 4:5, YouTube 16:9, Cinematic), length (5 s to 10 min), look, speed, loops and text, then send it to Snapchat, Instagram Stories or anywhere.\n\nSnapchat gets it as a fresh snap through Loop Player's own Snap Kit app (no setup). A Snap Kit client ID typed here is used instead.\n\nInstagram Story sends it straight into Instagram's story editor. If Instagram refuses it, make a free app at developers.facebook.com and paste its App ID here.")
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion).foregroundColor(Theme.dim)
                }
                Text("Loop Player plays your own music and video files. No accounts, and your files never leave the phone. YouTube playlists play through YouTube's own player.")
                    .font(.footnote)
                    .foregroundColor(Theme.dim)
                Text("Made by Necro")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.accent)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Settings")
        .sheet(isPresented: $showSpeed) { SpeedSheet() }
        .sheet(isPresented: $sunoSignIn) { SunoSignInView().environmentObject(SunoAuth.shared) }
        .confirmationDialog("Clear the cache? Pictures and YouTube's stored data are deleted and made again. Your songs, playlists and settings stay.", isPresented: $confirmCache, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                clearing = true
                Task {
                    let freed = await library.clearCache()
                    clearing = false
                    cacheResult = "Cleared \(freed)"
                }
            }
        }
        .alert("Lock Screen Check", isPresented: Binding(get: { lockReport != nil }, set: { if !$0 { lockReport = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((lockReport ?? []).joined(separator: "\n"))
        }
        .confirmationDialog("Read every file again and redraw the artwork? This can take a while on big libraries.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Rebuild") { library.clearArtworkCache() }
        }
        .confirmationDialog(removing.map { "Remove \($0.name) from the library? The files are not deleted." } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Folder", role: .destructive) {
                if let f = removing { library.removeFolder(f.id) }
                removing = nil
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

func rateLabel(_ r: Float) -> String {
    r == 1 ? "Normal" : (r == r.rounded() ? String(format: "%.0f×", r) : String(format: "%g×", r))
}

struct FolderLogView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        List {
            if library.folderLog.isEmpty {
                Text("Nothing logged yet.").foregroundColor(Theme.dim).listRowBackground(Theme.bg)
            }
            ForEach(Array(library.folderLog.enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .listRowBackground(Theme.bg)
            }
        }
        .darkList()
        .navigationTitle("Folder Log")
        .onAppear { library.reloadLog() }
        .refreshable { library.reloadLog() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { UIPasteboard.general.string = library.folderLog.joined(separator: "\n") } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button(role: .destructive) { library.clearLog() } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }
}

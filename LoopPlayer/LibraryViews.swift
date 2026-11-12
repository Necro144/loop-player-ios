import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore

    var body: some View {
        let recent = library.tracks(Array(store.recent.prefix(20)))
        let favorites = library.tracks(Array(store.favorites)).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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

                if !recent.isEmpty {
                    Shelf(title: "Recently Played", tracks: recent)
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
        case .favorites: return library.tracks(Array(store.favorites))
        case .recent: return library.tracks(store.recent)
        case .mostPlayed: return library.tracks(store.mostPlayed())
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
            if sortable {
                ToolbarItem(placement: .navigationBarTrailing) {
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
            ForEach(subfolders, id: \.0) { name, count in
                NavigationLink {
                    FolderBrowserView(folderID: folderID, path: path.isEmpty ? name : path + "/" + name, title: name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").foregroundColor(Theme.accent).font(.title3)
                        Text(name)
                        Spacer()
                        Text("\(count)").foregroundColor(Theme.dim)
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

    private func subfolderCounts(_ tracks: [Track]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for t in tracks where t.directory != path {
            let rest = path.isEmpty ? t.directory : String(t.directory.dropFirst(path.count + 1))
            let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
            counts[first, default: 0] += 1
        }
        return counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }
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
        }
        .darkList()
        .navigationTitle("Playlists")
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
        let tracks = entries.map(\.1)
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
            }

            Section("Playback") {
                Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.setRepeat($0) })) {
                    Text("Off").tag(RepeatMode.off)
                    Text("All").tag(RepeatMode.all)
                    Text("One (loop)").tag(RepeatMode.one)
                }
                Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.setShuffle($0) }))
                Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                    ForEach(Player.rates, id: \.self) { r in Text(rateLabel(r)).tag(r) }
                }
                Button(role: .destructive) { store.clearRecent() } label: {
                    Label("Clear Recently Played", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion).foregroundColor(Theme.dim)
                }
                Text("Loop Player plays your own music and video files. No accounts, no streaming, nothing leaves the phone.")
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

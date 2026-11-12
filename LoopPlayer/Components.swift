import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Artwork

struct ArtworkView: View {
    let track: Track?
    var size: CGFloat? = nil
    var corner: CGFloat = 6
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: (track?.id ?? "") + (track?.hasArtwork == true ? "1" : "0")) {
            guard let track else { image = nil; return }
            if let c = ArtworkCache.shared.cached(track.id) { image = c; return }
            image = nil
            image = await ArtworkCache.shared.image(for: track)
        }
    }

    private var placeholder: some View {
        let seed = Int(AppPaths.stableHash(track?.displayAlbum ?? "x").suffix(4), radix: 16) ?? 0
        let hue = Double(seed % 360) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.35),
                                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                Image(systemName: track?.isVideo == true ? "film" : "music.note")
                    .font(.system(size: max(10, min(g.size.width, g.size.height) * 0.38), weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
    }
}

// MARK: - Rows

struct PlayingBars: View {
    var animating: Bool
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 3, height: animating ? (phase ? [12, 6, 10][i] : [5, 13, 7][i]) : 6)
            }
        }
        .frame(width: 15, height: 14, alignment: .bottom)
        .onAppear { if animating { start() } }
        .onChange(of: animating) { on in if on { start() } }
    }

    private func start() {
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { phase.toggle() }
    }
}

struct TrackRow: View {
    let track: Track
    let list: [Track]
    var index: Int? = nil
    var showArtwork = true
    var subtitle: String? = nil
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 12) {
                if showArtwork {
                    ArtworkView(track: track, size: 48, corner: 6)
                        .overlay(alignment: .bottomTrailing) {
                            if track.isVideo {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 10))
                                    .padding(2)
                                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                                    .padding(2)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? Theme.accent : .white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if store.isFavorite(track.id) {
                            Image(systemName: "heart.fill").font(.caption2).foregroundColor(Theme.accent)
                        }
                        if track.isPlaceholder {
                            Image(systemName: "icloud.and.arrow.down").font(.caption2).foregroundColor(Theme.dim)
                        }
                        Text(subtitle ?? track.displayArtist)
                            .font(.subheadline)
                            .foregroundColor(Theme.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if isCurrent {
                    PlayingBars(animating: player.isPlaying)
                } else if track.duration > 0 {
                    Text(formatTime(track.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Theme.dim)
                }
                Menu {
                    TrackMenuItems(tracks: [track])
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundColor(Theme.dim)
                        .frame(width: 30, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let index { player.play(list, startAt: index) } else { player.play(track, in: list) }
        }
        .listRowBackground(Theme.bg)
        .listRowSeparatorTint(Theme.hairline)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.playNext([track]) } label: { Label("Play Next", systemImage: "text.insert") }
                .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { player.addToQueue([track]) } label: { Label("Queue", systemImage: "text.append") }
                .tint(.indigo)
        }
        .contextMenu { TrackMenuItems(tracks: [track]) }
    }
}

/// The actions offered for one or more songs (long press, "..." menu).
struct TrackMenuItems: View {
    let tracks: [Track]
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var ui: AppUI

    var body: some View {
        Button { player.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
        Button { player.playNext(tracks) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }
        Button { ui.addToPlaylist = TrackIDs(ids: tracks.map(\.id)) } label: {
            Label("Add to Playlist…", systemImage: "music.note.list")
        }
        if tracks.count == 1, let t = tracks.first {
            Button { player.play([t]); player.setRepeat(.one) } label: {
                Label("Loop This Song", systemImage: "repeat.1")
            }
            Button { store.toggleFavorite(t.id) } label: {
                store.isFavorite(t.id)
                    ? Label("Remove from Favorites", systemImage: "heart.slash")
                    : Label("Add to Favorites", systemImage: "heart")
            }
            Button { ui.info = t } label: { Label("File Info", systemImage: "info.circle") }
        }
    }
}

struct PlayShuffleHeader: View {
    let tracks: [Track]
    @EnvironmentObject var player: Player

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    player.setShuffle(false)
                    player.play(tracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundColor(Theme.accent)
                }
                Button {
                    player.play(tracks, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            if !tracks.isEmpty {
                Text("\(tracks.count) \(tracks.count == 1 ? "song" : "songs") · \(formatTotal(tracks.reduce(0) { $0 + $1.duration }))")
                    .font(.footnote)
                    .foregroundColor(Theme.dim)
            }
        }
        .listRowBackground(Theme.bg)
        .listRowSeparator(.hidden)
        .padding(.vertical, 6)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var text: String = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 42)).foregroundColor(Theme.dim)
            Text(title).font(.headline)
            if !text.isEmpty {
                Text(text).font(.subheadline).foregroundColor(Theme.dim).multilineTextAlignment(.center)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .listRowBackground(Theme.bg)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Mini player

struct MiniPlayerSlot: View {
    @EnvironmentObject var player: Player

    var body: some View {
        if player.current != nil {
            MiniPlayer()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: Player

    var body: some View {
        if let t = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ArtworkView(track: t, size: 42, corner: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(t.displayArtist).font(.caption).foregroundColor(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if player.repeatMode == .one {
                        Image(systemName: "repeat.1").font(.caption.weight(.bold)).foregroundColor(Theme.accent)
                    }
                    Button { player.togglePlay() } label: {
                        Group {
                            if player.isPreparing {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            }
                        }
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("miniPlayPause")
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title3).frame(width: 40, height: 44).contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                MiniProgress()
            }
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
            .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { player.showFullPlayer = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height < -30 { player.showFullPlayer = true }
                else if v.translation.width < -60 { player.next() }
                else if v.translation.width > 60 { player.previous() }
            })
        }
    }
}

struct MiniProgress: View {
    @EnvironmentObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { g in
            let f = clock.duration > 0 ? min(1, clock.time / clock.duration) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle().fill(Theme.accent).frame(width: g.size.width * f)
            }
        }
        .frame(height: 2)
        .clipShape(RoundedRectangle(cornerRadius: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 1)
    }
}

// MARK: - Folder picker

/// Shows the Files folder picker straight from UIKit.
/// It used to sit inside a SwiftUI sheet: tapping Open closed that sheet, SwiftUI threw the
/// picker's delegate away, and the chosen folder was lost. Here the delegate is kept alive
/// until the picker has reported back, and only one folder is picked at a time (the Open
/// button picks the folder you are in).
@MainActor
final class FolderPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPickerPresenter()
    private var onPick: (([URL]) -> Void)?
    private var picker: UIDocumentPickerViewController?

    func present(onPick: @escaping ([URL]) -> Void) {
        guard picker == nil, let top = Self.topViewController() else { return }
        self.onPick = onPick
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        vc.allowsMultipleSelection = false
        vc.shouldShowFileExtensions = true
        vc.delegate = self
        picker = vc
        top.present(vc, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let callback = onPick
        finish()
        callback?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish()
    }

    private func finish() {
        onPick = nil
        picker = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// Uses On My iPhone > Loop Player. Works on every install, even when the system
/// folder picker will not hand a folder to the app.
struct AppFolderButton: View {
    @EnvironmentObject var library: Library

    var body: some View {
        Button {
            library.addAppFolder()
        } label: {
            VStack(spacing: 2) {
                Label("Use the Loop Player folder", systemImage: "folder.fill")
                Text("Files app > On My iPhone > Loop Player")
                    .font(.caption)
                    .foregroundColor(Theme.dim)
            }
        }
        .accessibilityIdentifier("useAppFolder")
    }
}

struct AddFolderButton: View {
    var title = "Add Folder"
    var prominent = false
    @EnvironmentObject var library: Library

    var body: some View {
        Button {
            let lib = library
            FolderPickerPresenter.shared.present { urls in lib.addFolders(urls) }
        } label: {
            if prominent {
                Label(title, systemImage: "folder.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundColor(.white)
            } else {
                Label(title, systemImage: "folder.badge.plus")
            }
        }
    }
}

// MARK: - AirPlay and video

struct AirPlayButton: UIViewRepresentable {
    var video = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = video
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {
        v.prioritizesVideoDevices = video
    }
}

struct VideoSurface: UIViewRepresentable {
    var fill = false

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        Player.shared.attach(v)
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

// MARK: - Sheets

struct PlaylistPickerView: View {
    let ids: [String]
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var naming = false

    var body: some View {
        NavigationStack {
            List {
                Button { naming = true } label: {
                    Label("New Playlist…", systemImage: "plus.circle.fill").foregroundColor(Theme.accent)
                }
                .listRowBackground(Theme.bg)
                ForEach(store.playlists) { p in
                    Button {
                        store.add(ids, to: p.id)
                        Player.shared.toast = "Added to \(p.name)"
                        dismiss()
                    } label: {
                        HStack {
                            PlaylistCover(playlist: p, size: 44)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundColor(.white)
                                Text("\(p.trackIDs.count) songs").font(.caption).foregroundColor(Theme.dim)
                            }
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
            }
            .darkList()
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New Playlist", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let p = store.createPlaylist(newName, with: ids)
                    Player.shared.toast = "Added to \(p.name)"
                    newName = ""
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

struct PlaylistCover: View {
    let playlist: Playlist
    var size: CGFloat
    @EnvironmentObject var library: Library

    var body: some View {
        let first = playlist.trackIDs.lazy.compactMap { library.track($0) }.first
        Group {
            if let first {
                ArtworkView(track: first, size: size, corner: 6)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.gradient)
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: "music.note.list").foregroundColor(.white))
            }
        }
    }
}

struct TrackInfoView: View {
    let track: Track
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        ArtworkView(track: track, size: 160, corner: 10)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    row("Title", track.title)
                    row("Artist", track.displayArtist)
                    row("Album", track.displayAlbum)
                    row("Length", formatTime(track.duration))
                    row("Type", track.isVideo ? "Video (\(track.fileExtension))" : "Audio (\(track.fileExtension))")
                    row("Size", ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
                    row("Folder", library.folder(track.folderID)?.name ?? "?")
                    row("Path", track.relativePath)
                    row("Plays", "\(UserStore.shared.playCounts[track.id] ?? 0)")
                    if track.isPlaceholder { row("iCloud", "Not downloaded yet (downloads when played)") }
                }
                .listRowBackground(Theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("File Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(Theme.dim)
            Spacer()
            Text(v).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

// MARK: - First launch

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Theme.gradient).frame(width: 120, height: 120)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 30)
                Image(systemName: "repeat")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundColor(.white)
            }
            Text("Loop Player").font(.largeTitle.weight(.bold))
            Text("Pick a folder with your songs and videos. It can be in iCloud Drive or On My iPhone. You can add more folders later in Settings.")
                .font(.body)
                .foregroundColor(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
            if DeviceFolders.available {
                // Installed with TrollStore: the phone's folders can be read directly,
                // without the system picker.
                BrowsePhoneButton(prominent: true)
                    .padding(.horizontal, 24)
                AddFolderButton(title: "Choose a Folder")
                    .foregroundColor(Theme.accent)
            } else {
                AddFolderButton(title: "Choose a Folder", prominent: true)
                    .padding(.horizontal, 24)
            }
            AppFolderButton()
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 24)
            Text("MP3 · M4A · AAC · WAV · FLAC · AIFF · MP4 · MOV")
                .font(.caption)
                .foregroundColor(Theme.dim)
                .padding(.bottom, 30)
        }
    }
}

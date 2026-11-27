import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// Send to Snapchat (1.5.4): a button at the top left of every main screen. Sends a photo or video
// from Photos or Files, or a clip of what's playing, straight to Snapchat as a fresh snap.

extension View {
    /// The Snapchat button, top left.
    func snapButton() -> some View {
        toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { AppUI.shared.showSnapSend = true } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.snapYellow)
                }
                .accessibilityLabel("Send to Snapchat")
                .accessibilityIdentifier("snap-send")
            }
        }
    }
}

struct SnapSendView: View {
    @ObservedObject private var maker = ClipMaker.shared
    @ObservedObject private var player = Player.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var importing = false
    @State private var loading = false
    @AppStorage("snapSendSeconds") private var seconds: Double = 15
    /// How stickers and photos reach Snapchat (1.5.6): "paste" (copy, then paste on a snap taken in
    /// Snapchat; no Creative Kit, so no Media Upload label), "kit" (sticker on Snapchat's camera through
    /// Creative Kit; Snapchat labels it Media Upload) or "upload" (the photo itself, Media Upload).
    @AppStorage("snapWay") private var way = "paste"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { maker.songToSnapchatCamera(paste: way != "kit") } label: {
                        row("Song sticker", player.current.map { "\($0.title): " + (way == "kit" ? "on Snapchat's camera" : "copied, paste it on your snap") } ?? "Play a song first", "music.note.list")
                    }
                    .disabled(player.current == nil)
                    .accessibilityIdentifier("snap-sticker")
                    Picker("Photos and stickers", selection: $way) {
                        Text("Copy & paste: real snap").tag("paste")
                        Text("Sticker on Snapchat's camera").tag("kit")
                        Text("Send the photo itself").tag("upload")
                    }
                    .accessibilityIdentifier("snap-way")
                } header: { Text("Real snap") } footer: {
                    Text(way == "paste" ? "Snapchat labels everything another app hands it as \"Media Upload\", even a sticker put on its own camera. Copy & paste hands Snapchat nothing: Loop Player copies the song card or photo and opens Snapchat. Take your snap, tap T (text), hold on the screen and tap Paste. The picture goes on as a sticker and the snap stays a real snap."
                         : way == "kit" ? "The sticker is put on Snapchat's live camera. Snapchat still shows these snaps as \"Media Upload\"."
                         : "The photo is sent as it is. Snapchat shows it as \"Media Upload\".")
                }
                Section {
                    PhotosPicker(selection: $pick, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                        row("From Photos", loading ? "Loading…" : "A photo or video, sent as a fresh snap", "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("snap-photos")
                    Button { importing = true } label: {
                        row("From Files", "Any photo or video file on the iPhone", "folder.fill")
                    }
                    .accessibilityIdentifier("snap-files")
                } header: { Text("Send a file") } footer: {
                    Text("Videos are sent as they are (Snapchat shows them as Media Upload); longer than 60 seconds are cut to their first 60 seconds.")
                }
                Section {
                    Button { sendNowPlaying() } label: {
                        row("Clip of what's playing", player.current.map { "\(ClipOptions.label(seconds)) of \($0.title), with your Clip Studio choices" } ?? "Nothing is playing", "play.circle.fill")
                    }
                    .disabled(player.current == nil)
                    .accessibilityIdentifier("snap-now")
                    Picker("Length", selection: $seconds) {
                        ForEach([5.0, 10, 15, 20, 30, 45, 60], id: \.self) { Text(ClipOptions.label($0)).tag($0) }
                    }
                } header: { Text("Now playing") }
                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ClipMaker.shared.openStudio = true }
                    } label: { row("Open Clip Studio", "Sizes, looks, text, speed and more", "wand.and.stars") }
                    Button {
                        if let u = URL(string: "snapchat://") { UIApplication.shared.open(u) }
                    } label: { row("Open Snapchat", "Just the camera", "camera.fill") }
                }
            }
            .darkList()
            .navigationTitle("Send to Snapchat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .overlay { ClipProgressOverlay(inStudio: false) }
        .alert("Copied for Snapchat", isPresented: $maker.pasteReady) {
            Button("Open Snapchat") { maker.openSnapchatPlain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In Snapchat: take your photo or video, tap T (text), hold on the screen and tap Paste. Move or resize the sticker, then send. It shows as a snap you took, not Media Upload.")
        }
        .onChange(of: pick) { item in load(item) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .image], allowsMultipleSelection: false) { r in
            guard case .success(let urls) = r, let u = urls.first else { return }
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(UUID().uuidString + "." + (u.pathExtension.isEmpty ? "mov" : u.pathExtension))
            do { try FileManager.default.copyItem(at: u, to: dest) } catch {
                maker.error = "That file couldn't be read."
                return
            }
            let isMovie = (UTType(filenameExtension: u.pathExtension)?.conforms(to: .movie)) ?? false
            FolderLog.append("Snapchat: file picked (\(isMovie ? "video" : "photo"))")
            send(dest, movie: isMovie)
        }
    }

    private func row(_ title: String, _ sub: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundColor(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.primary)
                Text(sub).font(.caption).foregroundColor(Theme.dim).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loading = true
        Task { @MainActor in
            defer { loading = false; pick = nil }
            let movie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if movie, let m = try? await item.loadTransferable(type: PickedMovie.self) {
                FolderLog.append("Snapchat: video picked")
                send(m.url, movie: true)
            } else if let d = try? await item.loadTransferable(type: Data.self), UIImage(data: d) != nil {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let u = dir.appendingPathComponent(UUID().uuidString + ".img")
                try? d.write(to: u)
                FolderLog.append("Snapchat: photo picked")
                send(u, movie: false)
            } else {
                maker.error = "That item couldn't be loaded. If it's in iCloud, open it in Photos once, then try again."
            }
        }
    }

    /// Photos are made a JPEG as they are; videos a plain clip (no painting) of at most 60 s.
    private func send(_ file: URL, movie: Bool) {
        var o = ClipOptions()
        o.start = .beginning
        o.quality = .auto
        if movie {
            let d = CMTimeGetSeconds(AVURLAsset(url: file).duration)
            o.seconds = d.isFinite && d > 0 ? min(60, d) : 60
            maker.source = .video(file)
        } else if way != "upload" {
            maker.photoToSnapchatCamera(file, paste: way == "paste")
            return
        } else {
            maker.source = .photo(file)
        }
        maker.make(o, to: .snapchat)
    }

    private func sendNowPlaying() {
        var o = ClipOptions.saved
        o.seconds = seconds
        maker.source = .nowPlaying
        maker.make(o, to: .snapchat)
    }
}

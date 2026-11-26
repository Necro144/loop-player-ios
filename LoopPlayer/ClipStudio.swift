import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

// Clip Studio (1.5.0): pick what to share (the playing video or song, or a photo or video from
// the library), its shape (Story, Square, YouTube, Cinematic...), length, start, look, speed,
// loops, text and quality, see a preview, then send it to Snapchat, Instagram or anywhere.

/// A video picked in the Photos picker, copied into the app.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = dir.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct ClipStudioView: View {
    @ObservedObject private var maker = ClipMaker.shared
    @ObservedObject private var player = Player.shared
    @Environment(\.dismiss) private var dismiss
    @State private var o = ClipOptions.saved
    @State private var pick: PhotosPickerItem?
    @State private var loadingPick = false
    @State private var preview: UIImage?
    @State private var previewSize: CGSize = .zero
    @State private var previewTask: Task<Void, Never>?
    @State private var resultPlayer: AVPlayer?
    @State private var recent: [URL] = []
    @State private var copied = false

    private var isPhoto: Bool { if case .photo = maker.source { return true } else { return false } }
    private var isPicked: Bool { maker.source != .nowPlaying }
    /// A song (no picture of its own): made into a song card.
    private var isSong: Bool { !isPicked && !(player.current?.isVideo ?? true) }
    private var hasLoop: Bool { player.loopA != nil && player.loopB != nil }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                previewSection
                if !isPhoto { lengthSection }
                sizeSection
                lookSection
                if !isPhoto { soundSection }
                textSection
                qualitySection
                if let r = maker.last { resultSection(r) }
                if !recent.isEmpty { recentSection }
                Section {
                    Text("Shortcuts and other apps can make clips too: loopplayer://clip?seconds=30&size=story&look=mono&to=snapchat (sizes: story, square, portrait, youtube, cinematic, classic; to: snapchat, instagram, share, preview). loopplayer://studio opens this screen.")
                        .font(.caption).foregroundColor(Theme.dim)
                        .textSelection(.enabled)
                } header: { Text("For developers") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Clip Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { o = ClipOptions() }
                }
            }
            .safeAreaInset(edge: .bottom) { sendBar }
        }
        .preferredColorScheme(Theme.scheme)
        .overlay { ClipProgressOverlay(inStudio: true) }
        .onAppear {
            maker.studioShown = true
            if maker.source == .nowPlaying, player.current == nil { o.start = .here }
            recent = ClipMaker.recentClips()
            refreshPreview()
        }
        .onDisappear {
            maker.studioShown = false
            o.save()
            resultPlayer?.pause()
        }
        .onChange(of: o) { _ in
            o.save()
            refreshPreview()
        }
        .onChange(of: pick) { item in load(item) }
        .onChange(of: maker.last?.id) { _ in
            recent = ClipMaker.recentClips()
            if let r = maker.last, !r.isPhoto {
                resultPlayer = AVPlayer(url: r.url)
            } else {
                resultPlayer = nil
            }
        }
    }

    // MARK: sections

    private var sourceSection: some View {
        Section {
            Button { maker.source = .nowPlaying; pick = nil; refreshPreview() } label: {
                sourceRow("Now playing", player.current?.title ?? "Nothing is playing", "play.circle.fill", on: !isPicked)
            }
            .disabled(player.current == nil)
            PhotosPicker(selection: $pick, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                sourceRow("From your library", pickedText, "photo.on.rectangle.angled", on: isPicked)
            }
            .accessibilityIdentifier("studio-pick")
        } header: { Text("Make it from") } footer: {
            Text("Photos and videos you pick go to Snapchat as a fresh snap, the same as one you took in Snapchat, not as a Camera Roll upload.")
        }
    }

    private var pickedText: String {
        if loadingPick { return "Loading…" }
        switch maker.source {
        case .photo: return "Photo picked: tap to change"
        case .video: return "Video picked: tap to change"
        case .nowPlaying: return "Pick a photo or video"
        }
    }

    private func sourceRow(_ title: String, _ sub: String, _ icon: String, on: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundColor(on ? Theme.accent : Theme.dim).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.primary)
                Text(sub).font(.caption).foregroundColor(Theme.dim).lineLimit(1)
            }
            Spacer()
            if on { Image(systemName: "checkmark").foregroundColor(Theme.accent) }
        }
    }

    private var previewSection: some View {
        Section {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.black)
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(previewCaption).font(.caption.weight(.semibold)).foregroundColor(Theme.dim)
            }
            .listRowBackground(Theme.surface)
        } header: { Text("Preview") }
    }

    private var previewCaption: String {
        var parts: [String] = []
        if previewSize != .zero { parts.append("\(Int(previewSize.width)) × \(Int(previewSize.height))") }
        if !isPhoto {
            if !isPicked, o.start == .loop, hasLoop, let a = player.loopA, let b = player.loopB {
                parts.append(ClipOptions.label((b - a) * Double(o.repeats) / effectiveSpeed) + " (A-B loop)")
            } else {
                parts.append(ClipOptions.label(o.seconds))
            }
            if abs(effectiveSpeed - 1) > 0.001 { parts.append(String(format: "%.2gx", effectiveSpeed)) }
            if o.repeats > 1 { parts.append("looped \(o.repeats)×") }
        }
        if o.look != .none { parts.append(o.look.title) }
        if isSong && !o.soundOnly { parts.append("song card") }
        return parts.joined(separator: " · ")
    }

    private var effectiveSpeed: Double { o.speed > 0 ? o.speed : (isPicked ? 1 : Double(player.rate)) }

    private var lengthSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClipOptions.lengthChoices, id: \.self) { s in
                        chip(ClipOptions.label(s), on: abs(o.seconds - s) < 0.5) { o.seconds = s }
                    }
                }
                .padding(.vertical, 4)
            }
            Stepper(value: $o.seconds, in: 1...600, step: 1) {
                Text("Exactly \(ClipOptions.label(o.seconds))")
            }
            if !isPicked {
                Picker("Start", selection: $o.start) {
                    Text("From here").tag(ClipStart.here)
                    Text("From the start").tag(ClipStart.beginning)
                    if hasLoop { Text("A-B loop").tag(ClipStart.loop) }
                }
                .pickerStyle(.segmented)
            }
        } header: { Text("Length") } footer: {
            Text(hasLoop && !isPicked ? "A-B loop makes the clip from exactly your loop (the length above is not used)." :
                    "Set an A-B loop in the player to clip exactly that part.")
        }
    }

    private var sizeSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 10)], spacing: 10) {
                ForEach(ClipSize.allCases) { s in
                    Button { o.size = s } label: { sizeTile(s) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("size-\(s.rawValue)")
                }
            }
            .padding(.vertical, 6)
            if !isSong || o.soundOnly {
                Picker("Fit", selection: $o.framing) {
                    ForEach(ClipFraming.allCases) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented)
            }
        } header: { Text("Size") } footer: { Text(o.size.hint) }
    }

    private func sizeTile(_ s: ClipSize) -> some View {
        let r = s.ratio ?? 1.3
        let w: CGFloat = r >= 1 ? 40 : 40 * r
        let h: CGFloat = r >= 1 ? 40 / r : 40
        let on = o.size == s
        return VStack(spacing: 6) {
            ZStack {
                if s == .original {
                    Image(systemName: "rectangle.dashed").font(.system(size: 30))
                } else {
                    RoundedRectangle(cornerRadius: 4).stroke(lineWidth: 2).frame(width: w, height: h)
                }
            }
            .frame(height: 44)
            Text(s.title).font(.caption2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
        }
        .foregroundColor(on ? Theme.accent : .primary)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(on ? Theme.accent.opacity(0.15) : Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Theme.accent : Color.clear, lineWidth: 1.5))
    }

    private var lookSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClipLook.allCases) { l in chip(l.title, on: o.look == l) { o.look = l } }
                }
                .padding(.vertical, 4)
            }
        } header: { Text("Look") }
    }

    private var soundSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClipOptions.speedChoices, id: \.self) { s in
                        chip(speedLabel(s), on: abs(o.speed - s) < 0.001) { o.speed = s }
                    }
                }
                .padding(.vertical, 4)
            }
            if o.speed > 0 && abs(o.speed - 1) > 0.001 {
                Toggle("Keep the pitch", isOn: $o.keepPitch)
            }
            Picker("Loop it", selection: $o.repeats) {
                Text("Once").tag(1)
                Text("2×").tag(2)
                Text("3×").tag(3)
                Text("5×").tag(5)
            }
            .pickerStyle(.segmented)
            Toggle("Fade in and out", isOn: $o.fade)
            if isSong {
                Toggle("Sound only (no picture)", isOn: $o.soundOnly)
                if !o.soundOnly {
                    Picker("Song card", selection: $o.cardStyle) {
                        ForEach(CardStyle.allCases) { c in Text(c.title).tag(c) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        } header: { Text("Speed and sound") } footer: {
            Text(isSong ? "Songs become a song card video (their picture bouncing, a moving progress bar) so Snapchat and Instagram take them." :
                    "Slowed (0.8×) sounds deeper unless Keep the pitch is on. Loop it plays the part again inside the clip.")
        }
    }

    private func speedLabel(_ s: Double) -> String {
        if s == 0 { return isPicked ? "Normal" : String(format: "Player (%.2gx)", Double(player.rate)) }
        if s == 0.8 { return "Slowed 0.8×" }
        return String(format: "%.2g×", s)
    }

    private var textSection: some View {
        Section {
            TextField("Caption (optional, emoji too)", text: $o.caption, axis: .vertical)
                .lineLimit(1...3)
            if !o.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("Where", selection: $o.captionPlace) {
                    ForEach(CaptionPlace.allCases) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    ForEach(CaptionColor.allCases) { c in
                        Button { o.captionColor = c } label: {
                            Circle().fill(c.color).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(o.captionColor == c ? Theme.accent : Color.white.opacity(0.3),
                                                         lineWidth: o.captionColor == c ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.title)
                    }
                }
                .padding(.vertical, 4)
            }
            if !isPicked { Toggle("Song title on it", isOn: $o.showTitle) }
            Toggle("Loop Player stamp", isOn: $o.watermark)
        } header: { Text("Text") }
    }

    private var qualitySection: some View {
        Section {
            Picker("Quality", selection: $o.quality) {
                ForEach(ClipQuality.allCases) { q in Text(q.title).tag(q) }
            }
            .pickerStyle(.segmented)
        } header: { Text("Quality") } footer: {
            Text("Auto: 720p for Snapchat (a smaller hand-over), 1080p for the rest. 4K files are big and take longer.")
        }
    }

    private func resultSection(_ r: ClipResult) -> some View {
        Section {
            if r.isPhoto {
                if let img = UIImage(contentsOfFile: r.url.path) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else if let resultPlayer {
                VideoPlayer(player: resultPlayer).frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            ForEach(r.rows) { row in LabeledContent(row.key, value: row.value) }
            HStack {
                sendSmall("Snapchat", "camera.viewfinder") { maker.send(r.url, to: .snapchat) }
                sendSmall("Instagram", "camera.circle") { maker.send(r.url, to: .instagramStory) }
                sendSmall("Share", "square.and.arrow.up") { maker.send(r.url, to: .share) }
            }
            .disabled(r.url.pathExtension == "m4a")
            Button { maker.saveToFiles(r.url) } label: { Label("Save to Files", systemImage: "folder") }
            Button {
                UIPasteboard.general.string = r.json
                copied = true
            } label: { Label(copied ? "Copied" : "Copy details (JSON)", systemImage: "curlybraces") }
        } header: { Text("Your clip") }
    }

    private var recentSection: some View {
        Section {
            ForEach(recent, id: \.self) { u in
                Menu {
                    Button { maker.send(u, to: .snapchat) } label: { Label("Snapchat", systemImage: "camera.viewfinder") }
                    Button { maker.send(u, to: .instagramStory) } label: { Label("Instagram Story", systemImage: "camera.circle") }
                    Button { maker.send(u, to: .share) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    Button { maker.saveToFiles(u) } label: { Label("Save to Files", systemImage: "folder") }
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: u)
                        recent = ClipMaker.recentClips()
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    HStack {
                        Image(systemName: u.pathExtension == "jpg" ? "photo" : (u.pathExtension == "m4a" ? "waveform" : "film"))
                            .foregroundColor(Theme.accent).frame(width: 26)
                        Text(u.deletingPathExtension().lastPathComponent).foregroundColor(.primary).lineLimit(1)
                        Spacer()
                        Text(fileSize(u)).font(.caption).foregroundColor(Theme.dim)
                    }
                }
            }
        } header: { Text("Recent clips") } footer: { Text("The last 12 clips are kept so you can send them again.") }
    }

    private func fileSize(_ u: URL) -> String {
        let b = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    private var sendBar: some View {
        let audioOnly = isSong && o.soundOnly
        return HStack(spacing: 8) {
            sendButton("Snapchat", "camera.viewfinder", .snapchat).disabled(audioOnly)
            sendButton("Instagram", "camera.circle", .instagramStory).disabled(audioOnly)
            sendButton("Share", "square.and.arrow.up", .share)
            sendButton("Preview", "eye", .preview)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .disabled(maker.progress != nil || loadingPick || (maker.source == .nowPlaying && player.current == nil))
    }

    private func sendButton(_ title: String, _ icon: String, _ target: ClipTarget) -> some View {
        Button {
            copied = false
            o.save()
            maker.make(o, to: target)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(target == .snapchat ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.surface2), in: RoundedRectangle(cornerRadius: 12))
            .foregroundColor(target == .snapchat ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studio-\(title.lowercased())")
    }

    private func sendSmall(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
    }

    private func chip(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? Theme.accent : Theme.surface2, in: Capsule())
                .foregroundColor(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: picking and preview

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loadingPick = true
        Task { @MainActor in
            defer { loadingPick = false }
            let movie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if movie, let m = try? await item.loadTransferable(type: PickedMovie.self) {
                maker.source = .video(m.url)
                FolderLog.append("Clip Studio: video picked")
            } else if let d = try? await item.loadTransferable(type: Data.self), UIImage(data: d) != nil {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let u = dir.appendingPathComponent(UUID().uuidString + ".img")
                try? d.write(to: u)
                maker.source = .photo(u)
                FolderLog.append("Clip Studio: photo picked")
            } else {
                maker.error = "That item couldn't be loaded. If it's in iCloud, open it in Photos once, then try again."
            }
            refreshPreview()
        }
    }

    private func refreshPreview() {
        previewTask?.cancel()
        let o = self.o
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            if let p = await ClipStudioPreview.make(o) {
                if Task.isCancelled { return }
                preview = p.image
                previewSize = p.size
                if let out = ProcessInfo.processInfo.environment["TEST_STUDIO_OUT"], let cg = p.image.cgImage {
                    let text = "preview=\(Int(p.size.width))x\(Int(p.size.height))\nbrightness=\(String(format: "%.2f", ClipMaker.brightness(cg)))"
                    try? text.write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

/// One still frame of the clip as it will come out.
@MainActor
enum ClipStudioPreview {
    static func make(_ o: ClipOptions) async -> (image: UIImage, size: CGSize)? {
        let maker = ClipMaker.shared
        let player = Player.shared
        var base: CGImage?
        var sourceSize = CGSize(width: 1080, height: 1080)
        var title = "", artist = "", card = false, art: CGImage?
        switch maker.source {
        case .photo(let u):
            guard let d = try? Data(contentsOf: u), let img = UIImage(data: d) else { return nil }
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            let k = min(1, 1200 / max(img.size.width, img.size.height, 1))
            let s = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
            let up = UIGraphicsImageRenderer(size: s, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: s)) }
            base = up.cgImage
            sourceSize = s
        case .video(let u):
            base = await frame(of: AVURLAsset(url: u), at: min(o.seconds, 20) / 2)
            sourceSize = base.map { CGSize(width: $0.width, height: $0.height) } ?? sourceSize
        case .nowPlaying:
            guard let t = player.current else { return nil }
            title = t.title
            artist = t.artist
            if t.isVideo, let a = ClipMaker.ownCopy(player.avPlayer.currentItem?.asset) {
                var at = player.clock.time
                if o.start == .beginning { at = 0 } else if o.start == .loop, let la = player.loopA { at = la }
                // The middle of the clip (song videos often open on black).
                at += min(o.seconds, 20) / 2
                base = await frame(of: a, at: at)
                sourceSize = base.map { CGSize(width: $0.width, height: $0.height) } ?? sourceSize
            } else if !o.soundOnly {
                card = true
                art = ClipPainter.artImage(t.hasArtwork ? AppPaths.artworkFile(for: t.id) : nil)
                base = art
            } else {
                return nil
            }
        }
        guard let base else { return nil }
        let photo: Bool = { if case .photo = maker.source { return true } else { return false } }()
        let full = ClipOptions.renderSize(source: sourceSize, size: o.size,
                                          quality: photo && o.quality == .auto ? .p1080 : o.quality, target: .share)
        // Small copy for the screen: same shape, text scaled the same way.
        let k = min(1, 720 / max(full.width, full.height))
        let small = CGSize(width: (full.width * k).rounded(), height: (full.height * k).rounded())
        let painter = ClipPainter(render: small, framing: o.framing, look: o.look,
                                  overlay: ClipPainter.overlay(size: small, options: o, title: card || o.showTitle ? title : "", artist: artist, card: card),
                                  fade: false, total: card ? 10 : 0, art: card ? art : nil, cardStyle: o.cardStyle)
        let out: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let cg = painter.image(card ? nil : base, t: card ? 4 : 0) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        guard let out else { return nil }
        return (out, full)
    }

    /// Off the main thread (1.5.2: the brightness checks ran on it and made Clip Studio stall).
    nonisolated private static func frame(of asset: AVAsset, at seconds: Double) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 960, height: 960)
        g.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        // The asked moment, else a little later or earlier: the first one that isn't (nearly) black.
        var best: (CGImage, Double)?
        for t in [seconds, seconds + 3, seconds + 8, max(0, seconds - 5), 1] {
            if Task.isCancelled { return nil }
            guard let cg = try? await g.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image else { continue }
            let light = ClipMaker.brightness(cg)
            if light > 0.09 { return cg }
            if best == nil || light > best!.1 { best = (cg, light) }
        }
        return best.map { $0.0 }
    }
}

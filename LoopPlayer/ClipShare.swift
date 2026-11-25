import SwiftUI
import AVFoundation
import CoreImage
import UIKit

// Share a clip (1.4.0), Clip Studio (1.5.0): a clip of the playing video or song, or a photo or
// video picked from the library, in the shape, length, look and speed picked in Clip Studio,
// then sent to Snapchat (as a fresh snap), Instagram Stories or the share sheet.

/// Where a finished clip goes.
enum ClipTarget {
    /// The iPhone share sheet (every app).
    case share
    /// Straight into Instagram's story editor, not saved to Photos.
    case instagramStory
    /// Straight into Snapchat as a full-screen snap (post it to your Story or send it), not
    /// saved to Photos, not a chat attachment and not marked as a Camera Roll upload.
    case snapchat
    /// Only made: shown in Clip Studio with its details.
    case preview
}

/// What a clip is made from.
enum ClipSource: Equatable {
    case nowPlaying
    /// A video picked from Photos (copied into the app).
    case video(URL)
    /// A photo picked from Photos (copied into the app).
    case photo(URL)
}

/// One detail line of a finished clip.
struct ClipInfoRow: Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

/// A finished clip and what it came out as.
struct ClipResult: Identifiable {
    let id = UUID()
    let url: URL
    let isPhoto: Bool
    let rows: [ClipInfoRow]

    var json: String {
        var d: [String: String] = ["file": url.lastPathComponent]
        for r in rows { d[r.key] = r.value }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var summary: String { rows.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }
}

@MainActor
final class ClipMaker: ObservableObject {
    static let shared = ClipMaker()

    /// 0...1 while a clip is being made, nil otherwise.
    @Published var progress: Double?
    @Published var error: String?
    /// The last clip made (Clip Studio shows it).
    @Published var last: ClipResult?
    /// A Clip Studio sheet is on screen (the player's own progress box steps aside).
    @Published var studioShown = false
    /// Asks the main screen to open Clip Studio (Settings, loopplayer:// links).
    @Published var openStudio = false
    @Published var source: ClipSource = .nowPlaying

    private var session: AVAssetExportSession?
    private var started = Date()

    /// Snapchat only takes clips from apps with their own Snap Kit client ID. Loop Player's own
    /// Snap Kit app (Staging, Creative Kit on; works for its demo users) is the default.
    static var snapClientID: String {
        let own = (UserDefaults.standard.string(forKey: "snapClientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? "4ef4e741-377e-4be5-a85d-d51758ed5e5c" : own
    }

    /// Finished clips stay here (the newest 12) so they can be sent again.
    static let folder: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func recentClips() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.sorted { date($0) > date($1) }
    }

    private static func newFile(_ title: String, ext: String) -> URL {
        let old = recentClips()
        if old.count >= 12 { for u in old.suffix(from: 11) { try? FileManager.default.removeItem(at: u) } }
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return folder.appendingPathComponent(safeName(title) + " clip " + f.string(from: Date()) + "." + ext)
    }

    /// Quick clip with the usual choices (automatic tests).
    func make(seconds: Double, to target: ClipTarget = .share) {
        var o = ClipOptions()
        o.seconds = seconds
        make(o, to: target)
    }

    func make(_ o: ClipOptions, to target: ClipTarget) {
        guard progress == nil else { return }
        progress = 0
        started = Date()
        Task {
            if case .photo(let url) = source {
                await makePhoto(url, o, to: target)
            } else {
                await makeClip(o, to: target)
            }
        }
    }

    private func fail(_ text: String) {
        progress = nil
        session = nil
        FolderLog.append("Clip failed: \(text)")
        error = text
    }

    /// What the clip is cut from right now.
    private struct Input {
        let asset: AVAsset
        let title: String
        let artist: String
        let isVideo: Bool
        let start: Double
        let total: Double
        let rate: Double
        let art: URL?
        /// A-B loop: its exact length.
        let loopLength: Double?
    }

    private func input(_ o: ClipOptions) -> Input? {
        let player = Player.shared
        if case .video(let url) = source {
            let a = AVURLAsset(url: url)
            return Input(asset: a, title: "Video", artist: "", isVideo: true, start: 0,
                         total: CMTimeGetSeconds(a.duration), rate: 1, art: nil, loopLength: nil)
        }
        guard let track = player.current, let a = player.avPlayer.currentItem?.asset else { return nil }
        let total = player.clock.duration > 0 ? player.clock.duration : CMTimeGetSeconds(a.duration)
        var start = player.clock.time
        var loop: Double?
        switch o.start {
        case .here: break
        case .beginning: start = 0
        case .loop:
            if let la = player.loopA {
                start = la
                if let lb = player.loopB, lb > la { loop = lb - la }
            }
        }
        return Input(asset: a, title: track.title, artist: track.artist, isVideo: track.isVideo, start: start, total: total,
                     rate: Double(player.rate > 0 ? player.rate : 1),
                     art: track.hasArtwork ? AppPaths.artworkFile(for: track.id) : nil, loopLength: loop)
    }

    private func makeClip(_ o: ClipOptions, to target: ClipTarget) async {
        guard let inp = input(o) else {
            fail("Play something first, or pick a photo or video in Clip Studio.")
            return
        }
        let player = Player.shared
        let rate = o.speed > 0 ? o.speed : inp.rate
        let reps = max(1, min(5, o.repeats))
        // Seconds of the original for one round: `seconds` of clip in all, at `rate`.
        var need = inp.loopLength ?? (o.seconds / Double(reps) * rate)
        var start = inp.start
        if inp.total.isFinite, inp.total > 0 {
            if start + need > inp.total { start = max(0, inp.total - need) }   // near the end: the last part
            need = min(need, inp.total - start)
        }
        guard need > 0.2 else {
            fail("There's nothing to cut there.")
            return
        }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: need, preferredTimescale: 600))
        let comp = AVMutableComposition()
        do {
            try ClipMaker.insert(range, of: inp.asset, times: reps, into: comp)
        } catch {
            fail("This file can't be cut into a clip (\(error.localizedDescription)).")
            return
        }
        let src = inp.asset.tracks(withMediaType: .video).first
        let transform = src?.preferredTransform ?? .identity
        for t in comp.tracks(withMediaType: .video) { t.preferredTransform = transform }
        if abs(rate - 1) > 0.001 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: comp.duration),
                                toDuration: CMTimeMultiplyByFloat64(comp.duration, multiplier: 1 / rate))
        }
        let soundOnly = !inp.isVideo && o.soundOnly
        let card = !inp.isVideo && !soundOnly
        let length = CMTimeGetSeconds(comp.duration)
        if card {
            // Songs: a picture track to paint the song card on.
            guard let blank = await ClipMaker.blankVideo(seconds: length + 1),
                  let bt = AVURLAsset(url: blank).tracks(withMediaType: .video).first,
                  let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                fail("The song card couldn't be made.")
                return
            }
            try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: comp.duration), of: bt, at: .zero)
        }

        var videoComposition: AVMutableVideoComposition?
        var shape = "sound only"
        if !soundOnly {
            let natural = src?.naturalSize ?? CGSize(width: 1080, height: 1080)
            let turned = natural.applying(transform)
            let sourceSize = card ? CGSize(width: 1080, height: 1080) : CGSize(width: abs(turned.width), height: abs(turned.height))
            let render = ClipOptions.renderSize(source: sourceSize, size: o.size, quality: o.quality, target: target)
            let rateF = src?.nominalFrameRate ?? 30
            let fps = card ? Int32(30) : Int32(min(Float(60), max(Float(24), rateF.rounded())))
            let painter = ClipPainter(render: render, framing: o.framing, look: o.look, natural: natural,
                                      orientation: ClipPainter.orientation(of: transform),
                                      overlay: ClipPainter.overlay(size: render, options: o, title: inp.title, artist: inp.artist, card: card),
                                      fade: o.fade, total: length, art: card ? ClipPainter.artImage(inp.art) : nil)
            let vc = AVMutableVideoComposition(asset: comp) { req in
                req.finish(with: painter.frame(req.sourceImage, t: CMTimeGetSeconds(req.compositionTime)), context: nil)
            }
            vc.renderSize = render
            vc.frameDuration = CMTime(value: 1, timescale: fps)
            videoComposition = vc
            shape = "\(Int(render.width))x\(Int(render.height))"
        }

        var mix: AVMutableAudioMix?
        if o.fade, length > 1 {
            let f = CMTime(seconds: min(1.0, length / 4), preferredTimescale: 600)
            let m = AVMutableAudioMix()
            m.inputParameters = comp.tracks(withMediaType: .audio).map { t in
                let p = AVMutableAudioMixInputParameters(track: t)
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: f))
                p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: comp.duration - f, duration: f))
                return p
            }
            mix = m
        }

        let preset = soundOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        guard let s = AVAssetExportSession(asset: comp, presetName: preset) else {
            fail("This file can't be cut into a clip.")
            return
        }
        let type: AVFileType = soundOnly ? .m4a : (s.supportedFileTypes.contains(.mp4) ? .mp4 : .mov)
        let out = ClipMaker.newFile(inp.title, ext: type == .mp4 ? "mp4" : (type == .mov ? "mov" : "m4a"))
        s.outputURL = out
        s.outputFileType = type
        s.videoComposition = videoComposition
        s.audioMix = mix
        s.audioTimePitchAlgorithm = o.speed > 0 ? (o.keepPitch ? .spectral : .varispeed) : player.pitchAlgorithm
        s.shouldOptimizeForNetworkUse = true
        session = s
        FolderLog.append("Clip: \(Int(length)) s of \(inp.title) from \(Int(start)) s, \(shape)"
                         + (abs(rate - 1) > 0.001 ? ", \(String(format: "%.2f", rate))x" : "")
                         + (reps > 1 ? ", looped \(reps)x" : "") + (o.look == .none ? "" : ", \(o.look.title)")
                         + (card ? ", song card" : ""))

        let box = SessionBox(s)
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                self.progress = Double(box.session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.exportAsynchronously { c.resume() }
        }
        poll.cancel()
        progress = nil
        session = nil
        if box.session.status == .completed {
            finished(out, isPhoto: false, to: target)
        } else if box.session.status == .cancelled {
            try? FileManager.default.removeItem(at: out)
        } else {
            fail("The clip couldn't be made: \(box.session.error?.localizedDescription ?? "unknown error")")
        }
    }

    /// A photo in the picked shape and look, as a JPEG.
    private func makePhoto(_ file: URL, _ o: ClipOptions, to target: ClipTarget) async {
        guard let data = try? Data(contentsOf: file), let picked = UIImage(data: data) else {
            fail("The photo couldn't be read.")
            return
        }
        // Upright and at most 4096 pixels long.
        let long = max(picked.size.width, picked.size.height, 1)
        let k = min(1, 4096 / long)
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        let size = CGSize(width: (picked.size.width * k).rounded(), height: (picked.size.height * k).rounded())
        let upright = UIGraphicsImageRenderer(size: size, format: f).image { _ in picked.draw(in: CGRect(origin: .zero, size: size)) }
        guard let cg = upright.cgImage else {
            fail("The photo couldn't be read.")
            return
        }
        let render = ClipOptions.renderSize(source: size, size: o.size, quality: o.quality == .auto ? .p1080 : o.quality, target: .share)
        let painter = ClipPainter(render: render, framing: o.framing, look: o.look, natural: size, orientation: nil,
                                  overlay: ClipPainter.overlay(size: render, options: o, title: "", artist: "", card: false),
                                  fade: false, total: 0, art: nil)
        let out = ClipMaker.newFile("Photo", ext: "jpg")
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            let img = painter.frame(CIImage(cgImage: cg), t: 0)
            guard let rendered = CIContext().createCGImage(img, from: CGRect(origin: .zero, size: render)),
                  let jpg = UIImage(cgImage: rendered).jpegData(compressionQuality: 0.92) else { return false }
            return (try? jpg.write(to: out)) != nil
        }.value
        progress = nil
        guard ok else {
            fail("The photo couldn't be made.")
            return
        }
        FolderLog.append("Clip: photo \(Int(render.width))x\(Int(render.height))" + (o.look == .none ? "" : ", \(o.look.title)"))
        finished(out, isPhoto: true, to: target)
    }

    private func finished(_ out: URL, isPhoto: Bool, to target: ClipTarget) {
        let r = ClipMaker.describe(out, isPhoto: isPhoto, took: Date().timeIntervalSince(started))
        last = r
        FolderLog.append("Clip made: " + r.summary)
        writeTestInfo(r)
        send(out, to: target)
    }

    /// Sends a finished clip (or photo) on.
    func send(_ file: URL, to target: ClipTarget) {
        let photo = ["jpg", "jpeg", "png"].contains(file.pathExtension.lowercased())
        switch target {
        case .share: share(file)
        case .instagramStory: toInstagramStory(file, photo: photo)
        case .snapchat: toSnapchat(file, photo: photo)
        case .preview: break
        }
    }

    func cancel() { session?.cancelExport() }

    /// Not async on purpose: from async code Swift picks the newer async insertTimeRange.
    nonisolated static func insert(_ range: CMTimeRange, of asset: AVAsset, times: Int, into comp: AVMutableComposition) throws {
        for _ in 0..<times { try comp.insertTimeRange(range, of: asset, at: comp.duration) }
    }

    /// A black picture track `seconds` long, for song cards (one frame a second).
    static func blankVideo(seconds: Double) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blank-\(Int(seconds * 10)).mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard w.canAdd(input) else { return nil }
        w.add(input)
        guard w.startWriting() else { return nil }
        w.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) { memset(base, 0, CVPixelBufferGetDataSize(buf)) }
        CVPixelBufferUnlockBaseAddress(buf, [])
        var t = 0.0
        while t <= seconds {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(buf, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
            t += 1
        }
        input.markAsFinished()
        w.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await w.finishWriting()
        return w.status == .completed ? url : nil
    }

    /// The details of a finished clip: for checking what Snapchat and Instagram are given.
    static func describe(_ file: URL, isPhoto: Bool, took: Double) -> ClipResult {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let mb = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        var rows: [ClipInfoRow] = []
        if isPhoto {
            let px = UIImage(contentsOfFile: file.path).map { "\(Int($0.size.width * $0.scale)) × \(Int($0.size.height * $0.scale))" } ?? "?"
            rows = [ClipInfoRow(key: "Picture", value: px), ClipInfoRow(key: "Format", value: "JPEG")]
        } else {
            let a = AVURLAsset(url: file)
            let secs = CMTimeGetSeconds(a.duration)
            rows.append(ClipInfoRow(key: "Length", value: String(format: "%.1f s", secs)))
            if let v = a.tracks(withMediaType: .video).first {
                rows.append(ClipInfoRow(key: "Picture", value: "\(Int(v.naturalSize.width)) × \(Int(v.naturalSize.height))"))
                rows.append(ClipInfoRow(key: "Frame rate", value: String(format: "%.0f fps", v.nominalFrameRate)))
                rows.append(ClipInfoRow(key: "Video codec", value: codec(v)))
                rows.append(ClipInfoRow(key: "Video bitrate", value: String(format: "%.1f Mbit/s", v.estimatedDataRate / 1_000_000)))
            }
            if let s = a.tracks(withMediaType: .audio).first {
                rows.append(ClipInfoRow(key: "Audio", value: codec(s) + String(format: ", %.0f kbit/s", s.estimatedDataRate / 1000)))
            }
            if secs > 60 { rows.append(ClipInfoRow(key: "Note", value: "Stories may cut clips longer than 60 s")) }
        }
        rows.append(ClipInfoRow(key: "File size", value: mb))
        rows.append(ClipInfoRow(key: "Made in", value: String(format: "%.1f s", took)))
        return ClipResult(url: file, isPhoto: isPhoto, rows: rows)
    }

    private static func codec(_ t: AVAssetTrack) -> String {
        guard let first = t.formatDescriptions.first else { return "?" }
        let fd = first as! CMFormatDescription
        let c = CMFormatDescriptionGetMediaSubType(fd)
        switch c {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kAudioFormatMPEG4AAC: return "AAC"
        default:
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((c >> UInt32($0)) & 0xff))) }
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Automatic test only: what the clip came out as.
    private func writeTestInfo(_ r: ClipResult) {
        guard let out = ProcessInfo.processInfo.environment["TEST_CLIP_OUT"] else { return }
        let file = r.url
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var lines = ["file=\(file.lastPathComponent)", "bytes=\(size)"]
        if r.isPhoto {
            let px = UIImage(contentsOfFile: file.path).map { "\(Int($0.size.width * $0.scale))x\(Int($0.size.height * $0.scale))" } ?? "none"
            lines.append("video=\(px)")
        } else {
            let a = AVURLAsset(url: file)
            let v = a.tracks(withMediaType: .video).first
            lines += ["seconds=\(String(format: "%.1f", CMTimeGetSeconds(a.duration)))",
                      "video=\(v.map { "\(Int($0.naturalSize.width))x\(Int($0.naturalSize.height))" } ?? "none")",
                      "audio=\(!a.tracks(withMediaType: .audio).isEmpty)"]
        }
        lines.append("info=\(r.summary)")
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// Instagram's "Share to Stories": the video (or photo) goes on the pasteboard for Instagram
    /// only (for 5 minutes) and Instagram opens its story editor with it. Nothing goes to Photos.
    private func toInstagramStory(_ file: URL, photo: Bool) {
        guard let data = try? Data(contentsOf: file) else {
            error = "The clip couldn't be read."
            return
        }
        let appID = (UserDefaults.standard.string(forKey: "igAppID") ?? "").filter(\.isNumber)
        let source = appID.isEmpty ? (Bundle.main.bundleIdentifier ?? "com.necro144.loopplayer") : appID
        guard let url = URL(string: "instagram-stories://share?source_application=\(source)") else { return }
        // No canOpenURL check: sideloaded Instagram builds (ReGram on the owner's phone, 1.4.4)
        // answer instagram-stories:// but iOS still said "not installed". Just open it.
        let key = photo ? "com.instagram.sharedSticker.backgroundImage" : "com.instagram.sharedSticker.backgroundVideo"
        var item: [String: Any] = [key: data]
        if !appID.isEmpty { item["com.instagram.sharedSticker.appID"] = appID }
        UIPasteboard.general.setItems([item], options: [.expirationDate: Date().addingTimeInterval(300)])
        FolderLog.append("Clip: sent to Instagram Stories (\(data.count / 1024) KB" + (appID.isEmpty ? ", no Facebook App ID)" : ")"))
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok {
                FolderLog.append("Clip: instagram-stories:// didn't open")
                Task { @MainActor in self?.error = "Instagram didn't open its story editor. Is Instagram installed? If it is, add a Facebook App ID in Settings > Share a Clip, or use Share instead." }
            }
        }
    }

    /// Snapchat's Creative Kit (the code-only "Lite" way from Snap's own sample): the video or photo
    /// goes on the pasteboard for Snapchat (5 minutes) and Snapchat opens its snap editor with it,
    /// as a fresh snap ("Snapchat pasted from Loop Player"), not a Camera Roll upload.
    private func toSnapchat(_ file: URL, photo: Bool) {
        guard let data = try? Data(contentsOf: file, options: .uncached) else {
            error = "The clip couldn't be read."
            return
        }
        let clientID = ClipMaker.snapClientID
        // No canOpenURL check (sideloaded builds can answer the link while iOS says "not installed").
        guard var parts = URLComponents(string: "snapchat://creativekit/preview/1") else { return }
        let key = photo ? "com.snapchat.creativekit.backgroundImage" : "com.snapchat.creativekit.backgroundVideo"
        let item: [String: Any] = [key: data, "com.snapchat.creativekit.clientID": clientID,
                                   "com.snapchat.creativekit.appName": "Loop Player"]
        UIPasteboard.general.setItems([item], options: [.expirationDate: Date().addingTimeInterval(300)])
        parts.queryItems = [URLQueryItem(name: "checkcount", value: String(UIPasteboard.general.changeCount)),
                            URLQueryItem(name: "clientId", value: clientID),
                            URLQueryItem(name: "appDisplayName", value: "Loop Player")]
        guard let url = parts.url else { return }
        FolderLog.append("Clip: sent to Snapchat (\(photo ? "photo" : "video"), \(data.count / 1024) KB)")
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok {
                FolderLog.append("Clip: snapchat:// didn't open")
                Task { @MainActor in self?.error = "Snapchat didn't open. Is Snapchat installed? Use Share instead." }
            }
        }
    }

    private func share(_ file: URL) {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        guard let top = ClipMaker.topViewController() else { return }
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 1, height: 1)
        sheet.completionWithItemsHandler = { activity, done, _, err in
            if let err { FolderLog.append("Clip share failed: \(err.localizedDescription)") }
            else if done { FolderLog.append("Clip shared to \(activity?.rawValue ?? "?")") }
        }
        top.present(sheet, animated: true)
    }

    /// Save to Files (a copy).
    func saveToFiles(_ file: URL) {
        guard let top = ClipMaker.topViewController() else { return }
        top.present(UIDocumentPickerViewController(forExporting: [file], asCopy: true), animated: true)
    }

    /// loopplayer://clip?seconds=30&size=story&look=mono&to=snapchat (Shortcuts, Safari, other apps).
    /// loopplayer://studio opens Clip Studio. Values: size = original|story|square|portrait|youtube|
    /// cinematic|classic, look = none|vivid|warm|cool|mono|noir|vintage|chrome|fade|dream|pixel,
    /// framing = blur|fill|fit, start = here|beginning|loop, speed, repeat, caption, title=1, fade=1,
    /// stamp=1, quality = auto|p720|p1080|k4, to = snapchat|instagram|share|preview.
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "loopplayer" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var q: [String: String] = [:]
        for i in items where q[i.name.lowercased()] == nil { q[i.name.lowercased()] = i.value ?? "" }
        FolderLog.append("Link: \(url.absoluteString)")
        var o = ClipOptions.saved
        if let v = q["seconds"].flatMap(Double.init) { o.seconds = min(600, max(1, v)) }
        if let v = q["size"].flatMap(ClipSize.init(rawValue:)) { o.size = v }
        if let v = q["look"].flatMap(ClipLook.init(rawValue:)) { o.look = v }
        if let v = q["framing"].flatMap(ClipFraming.init(rawValue:)) { o.framing = v }
        if let v = q["start"].flatMap(ClipStart.init(rawValue:)) { o.start = v }
        if let v = q["quality"].flatMap(ClipQuality.init(rawValue:)) { o.quality = v }
        if let v = q["speed"].flatMap(Double.init) { o.speed = min(4, max(0, v)) }
        if let v = q["repeat"].flatMap(Int.init) { o.repeats = min(5, max(1, v)) }
        if let v = q["caption"] { o.caption = v }
        if let v = q["title"] { o.showTitle = v == "1" }
        if let v = q["fade"] { o.fade = v == "1" }
        if let v = q["stamp"] { o.watermark = v == "1" }
        var to: ClipTarget?
        switch q["to"]?.lowercased() {
        case "snapchat": to = .snapchat
        case "instagram": to = .instagramStory
        case "share": to = .share
        case "preview": to = .preview
        default: to = nil
        }
        source = .nowPlaying
        if url.host?.lowercased() == "clip", let to {
            make(o, to: to)
        } else {
            o.save()
            let wait = Player.shared.showFullPlayer
            Player.shared.showFullPlayer = false
            Task { @MainActor in
                if wait { try? await Task.sleep(nanoseconds: 700_000_000) }
                self.openStudio = true
            }
        }
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Loop Player" : String(clean.prefix(60))
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

/// Lets the export session cross into the progress task.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
}

/// The share button in the player: opens Clip Studio for what's playing.
struct ClipShareMenu<Label: View>: View {
    let video: Bool
    @ViewBuilder let label: () -> Label
    @State private var open = false

    var body: some View {
        Button {
            ClipMaker.shared.source = .nowPlaying
            open = true
        } label: { label() }
        .sheet(isPresented: $open) { ClipStudioView() }
    }
}

/// Progress while the clip is cut, and errors.
struct ClipProgressOverlay: View {
    /// The one inside Clip Studio; the player's own steps aside while the studio is open.
    var inStudio = false
    @ObservedObject private var maker = ClipMaker.shared

    private var mine: Bool { inStudio == maker.studioShown }

    var body: some View {
        ZStack {
            if mine, let p = maker.progress {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView(value: p).tint(Theme.accent).frame(width: 200)
                    Text("Making your clip… \(Int(p * 100))%").font(.subheadline.weight(.semibold))
                    Button("Cancel") { maker.cancel() }.tint(.white)
                }
                .padding(24)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("clip-progress")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: maker.progress == nil)
        .alert("Share a Clip", isPresented: Binding(get: { mine && maker.error != nil }, set: { if !$0 { maker.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(maker.error ?? "") }
    }
}

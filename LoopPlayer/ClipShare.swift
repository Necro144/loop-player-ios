import SwiftUI
import AVFoundation
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
    var openStudio: Bool {
        get { ClipStudioRouter.shared.open }
        set { ClipStudioRouter.shared.open = newValue }
    }
    @Published var source: ClipSource = .nowPlaying

    private var session: AVAssetExportSession?
    private var cardStop: StopFlag?
    /// Where the clip being made goes.
    private var pendingTarget: ClipTarget = .share
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
        pendingTarget = target
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
        if let out = ProcessInfo.processInfo.environment["TEST_CLIP_OUT"] {
            try? "error=\(text)".write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// A file being played is read through its own copy, not the player's (1.5.2): cutting and
    /// previewing no longer compete with playback for the same asset.
    static func ownCopy(_ a: AVAsset?) -> AVAsset? {
        if let u = a as? AVURLAsset, u.url.isFileURL { return AVURLAsset(url: u.url) }
        return a
    }

    /// There while a clip is being painted; still there at the next clip = painting closed the app.
    static let paintMarker = AppPaths.support.appendingPathComponent("painting-clip")

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
        guard let track = player.current, let a = ClipMaker.ownCopy(player.avPlayer.currentItem?.asset) else { return nil }
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
        var range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: need, preferredTimescale: 600))
        var asset = inp.asset
        if !inp.isVideo {
            // Songs: the part is first made an AAC file. MP3s and others inside a composition gave
            // "Operation Stopped" (1.5.0 test); AAC works like a video's sound.
            switch await ClipMaker.toAAC(inp.asset, range: range) {
            case .success(let u):
                asset = AVURLAsset(url: u)
                range = CMTimeRange(start: .zero, duration: asset.duration)
            case .failure(let e):
                fail("The song's sound couldn't be read: \(ClipMaker.explain(e))")
                return
            }
        }
        let comp = AVMutableComposition()
        do {
            try ClipMaker.insert(range, of: asset, times: reps, into: comp)
        } catch {
            fail("This file can't be cut into a clip (\(error.localizedDescription)).")
            return
        }
        // Tracks are loaded without blocking the screen (1.5.2: the old synchronous read could
        // freeze the app on a file still being read).
        let src = (try? await inp.asset.loadTracks(withMediaType: .video))?.first
        var transform = CGAffineTransform.identity
        var natural = CGSize(width: 1080, height: 1080)
        var rateF: Float = 30
        if let src, let v = try? await src.load(.preferredTransform, .naturalSize, .nominalFrameRate) {
            transform = v.0
            natural = v.1
            rateF = v.2
        }
        for t in comp.tracks(withMediaType: .video) { t.preferredTransform = transform }
        if abs(rate - 1) > 0.001 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: comp.duration),
                                toDuration: CMTimeMultiplyByFloat64(comp.duration, multiplier: 1 / rate))
        }
        let soundOnly = !inp.isVideo && o.soundOnly
        // Songs: a song card. Its sound is made first (as a sound-only clip), then every picture
        // is drawn and written straight into the MP4 with that sound (1.5.1).
        let card = !inp.isVideo && !soundOnly
        var target = target
        let length = CMTimeGetSeconds(comp.duration)
        let pitch: AVAudioTimePitchAlgorithm = o.speed > 0 ? (o.keepPitch ? .spectral : .varispeed) : player.pitchAlgorithm

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

        let hasVideo = !card && !soundOnly && !comp.tracks(withMediaType: .video).isEmpty
        // Nothing to paint (original size, normal look, no text, no fade): the 1.4.4 way, which
        // works on the owner's iPhone. And if painting closed the app last time, the 1.4.4 way too.
        let overlayNeeded = !o.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || o.showTitle || o.watermark
        let needsPaint = o.size != .original || o.look != .none || overlayNeeded || o.fade
        let crashedBefore = FileManager.default.fileExists(atPath: ClipMaker.paintMarker.path)
        if hasVideo, needsPaint, crashedBefore {
            FolderLog.append("Clip: painting closed Loop Player last time, so this clip is made the plain way (no size, look or text)")
            try? FileManager.default.removeItem(at: ClipMaker.paintMarker)
        }
        if hasVideo && needsPaint && !crashedBefore {
            // Videos (1.5.2): every picture is painted in Loop Player and written into the MP4 by
            // Loop Player itself. 1.5.0/1.5.1 handed the painting to an export session (a Core Image
            // video composition), which crashed iOS's media service on the iPhone ("Cannot Complete
            // Action", AVFoundationErrorDomain -11819 / OSStatus -16978) or never finished.
            let turned = natural.applying(transform)
            let sourceSize = CGSize(width: abs(turned.width), height: abs(turned.height))
            let render = ClipOptions.renderSize(source: sourceSize, size: o.size, quality: o.quality, target: target)
            let fps = Int32(min(Float(60), max(Float(24), rateF.rounded())))
            let painter = ClipPainter(render: render, framing: o.framing, look: o.look,
                                      overlay: ClipPainter.overlay(size: render, options: o, title: inp.title, artist: inp.artist, card: false),
                                      fade: o.fade, total: length, art: nil)
            let mp4 = ClipMaker.newFile(inp.title, ext: "mp4")
            FolderLog.append("Clip: \(Int(length)) s of \(inp.title) from \(Int(start)) s, \(Int(render.width))x\(Int(render.height))"
                             + (abs(rate - 1) > 0.001 ? ", \(String(format: "%.2f", rate))x" : "")
                             + (reps > 1 ? ", looped \(reps)x" : "") + (o.look == .none ? "" : ", \(o.look.title)"))
            let stop = StopFlag()
            cardStop = stop
            // Marker: if the app closes while painting, the next clip is made the plain way.
            FileManager.default.createFile(atPath: ClipMaker.paintMarker.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: ClipMaker.paintMarker) }
            do {
                try await ClipMaker.renderVideo(comp, natural: natural, transform: transform, mix: mix, pitch: pitch, painter: painter, render: render,
                                                fps: fps, length: length, to: mp4, stop: stop) { p in
                    Task { @MainActor in if self.progress != nil { self.progress = p } }
                }
                cardStop = nil
                progress = nil
                finished(mp4, isPhoto: false, to: target)
                return
            } catch {
                cardStop = nil
                try? FileManager.default.removeItem(at: mp4)
                if stop.stop {
                    progress = nil
                    return
                }
                FolderLog.append("Clip: the painted clip couldn't be made (\(ClipMaker.explain(error))); making a plain clip")
                if ProcessInfo.processInfo.environment["TEST_CLIP_OUT"] != nil {
                    fail("painted clip: \(ClipMaker.explain(error))")
                    return
                }
            }
        }
        if hasVideo {
            // Plain clip, the 1.4.4 way (no painting): the right part, speed and loops, the
            // picture as it is. Worked on the iPhone before Clip Studio.
            progress = 0
            FolderLog.append("Clip: \(Int(length)) s of \(inp.title) from \(Int(start)) s, plain"
                             + (abs(rate - 1) > 0.001 ? ", \(String(format: "%.2f", rate))x" : "") + (reps > 1 ? ", looped \(reps)x" : ""))
            let preset = target == .snapchat ? AVAssetExportPreset1280x720 : AVAssetExportPreset1920x1080
            guard let s = AVAssetExportSession(asset: comp, presetName: preset) ?? AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
                fail("This file can't be cut into a clip.")
                return
            }
            let type: AVFileType = s.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
            let out = ClipMaker.newFile(inp.title, ext: type == .mp4 ? "mp4" : "mov")
            s.outputURL = out
            s.outputFileType = type
            s.audioMix = mix
            s.audioTimePitchAlgorithm = pitch
            s.shouldOptimizeForNetworkUse = true
            await runExport(s, share: 1)
            return
        }

        // Sound only, or the sound of a song card.
        guard let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            fail("This file can't be cut into a clip.")
            return
        }
        let out = card ? FileManager.default.temporaryDirectory.appendingPathComponent("card-sound-\(UUID().uuidString).m4a")
            : ClipMaker.newFile(inp.title, ext: "m4a")
        s.outputURL = out
        s.outputFileType = .m4a
        s.audioMix = mix
        s.audioTimePitchAlgorithm = pitch
        var render = CGSize.zero
        var cardPainter: ClipPainter?
        if card {
            render = ClipOptions.renderSize(source: CGSize(width: 1080, height: 1080), size: o.size, quality: o.quality, target: target)
            cardPainter = ClipPainter(render: render, framing: o.framing, look: o.look,
                                      overlay: ClipPainter.overlay(size: render, options: o, title: inp.title, artist: inp.artist, card: true),
                                      fade: o.fade, total: length, art: ClipPainter.artImage(inp.art), cardStyle: o.cardStyle)
        }
        FolderLog.append("Clip: \(Int(length)) s of \(inp.title) from \(Int(start)) s, "
                         + (card ? "\(Int(render.width))x\(Int(render.height)) song card" : "sound only")
                         + (abs(rate - 1) > 0.001 ? ", \(String(format: "%.2f", rate))x" : "")
                         + (reps > 1 ? ", looped \(reps)x" : ""))
        guard let painter = cardPainter else {
            await runExport(s, share: 1)
            return
        }
        guard await runExport(s, share: 0.2, finish: false) else { return }
        let mp4 = ClipMaker.newFile(inp.title, ext: "mp4")
        let stop = StopFlag()
        cardStop = stop
        progress = 0.2
        do {
            try await ClipMaker.renderCard(sound: out, painter: painter, render: render, fps: 30, to: mp4, stop: stop) { p in
                Task { @MainActor in if self.progress != nil { self.progress = 0.2 + 0.8 * p } }
            }
            cardStop = nil
            progress = nil
            try? FileManager.default.removeItem(at: out)
            finished(mp4, isPhoto: false, to: target)
        } catch {
            cardStop = nil
            progress = nil
            try? FileManager.default.removeItem(at: mp4)
            if stop.stop {
                try? FileManager.default.removeItem(at: out)
                return
            }
            // The sound still goes out, through Share (Snapchat and Instagram want a picture).
            FolderLog.append("Clip: song card couldn't be made (\(ClipMaker.explain(error))); sending the sound")
            if ProcessInfo.processInfo.environment["TEST_CLIP_OUT"] != nil {
                fail("song card: \(ClipMaker.explain(error))")
                return
            }
            let m4a = ClipMaker.newFile(inp.title, ext: "m4a")
            try? FileManager.default.moveItem(at: out, to: m4a)
            if target == .snapchat || target == .instagramStory { target = .share }
            finished(m4a, isPhoto: false, to: target)
        }
    }

    /// Runs an export with a progress bar and a watchdog: an export that doesn't move for 40 s is
    /// stopped with a clear message instead of hanging forever (1.5.1 could sit at "Making your
    /// clip…" when iOS's media service died). `finish`: send the file on when done.
    @discardableResult
    private func runExport(_ s: AVAssetExportSession, share: Double, finish: Bool = true) async -> Bool {
        session = s
        let box = SessionBox(s)
        let stuck = StopFlag()
        let poll = Task { @MainActor in
            var last: Float = -1
            var since = Date()
            while !Task.isCancelled {
                let p = box.session.progress
                if p != last { last = p; since = Date() }
                else if Date().timeIntervalSince(since) > 40 {
                    stuck.stop = true
                    box.session.cancelExport()
                    return
                }
                self.progress = Double(p) * share
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.exportAsynchronously { c.resume() }
        }
        poll.cancel()
        session = nil
        let out = s.outputURL
        if box.session.status == .completed {
            if finish {
                progress = nil
                if let out { finished(out, isPhoto: false, to: pendingTarget) }
            }
            return true
        }
        progress = nil
        if let out { try? FileManager.default.removeItem(at: out) }
        if stuck.stop {
            fail("The clip got stuck (iOS stopped answering). Close Loop Player from the app switcher and try again, or try a shorter clip or 720p.")
        } else if box.session.status != .cancelled {
            fail("The clip couldn't be made: \(box.session.error.map { ClipMaker.explain($0) } ?? "unknown error")")
        }
        return false
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
        let painter = ClipPainter(render: render, framing: o.framing, look: o.look,
                                  overlay: ClipPainter.overlay(size: render, options: o, title: "", artist: "", card: false),
                                  fade: false, total: 0, art: nil)
        let out = ClipMaker.newFile("Photo", ext: "jpg")
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let rendered = painter.image(cg, t: 0),
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
        let took = Date().timeIntervalSince(started)
        Task { @MainActor in
            // Reading the finished file's details can take a moment: not on the main thread (1.5.2).
            let r = await Task.detached(priority: .userInitiated) { ClipMaker.describe(out, isPhoto: isPhoto, took: took) }.value
            self.done(r, to: target)
        }
    }

    private func done(_ r: ClipResult, to target: ClipTarget) {
        let out = r.url
        last = r
        FolderLog.append("Clip made: " + r.summary)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    func cancel() {
        session?.cancelExport()
        cardStop?.stop = true
    }

    /// An error with its code and the reason underneath (for the Player Log).
    nonisolated static func explain(_ e: Error) -> String {
        let n = e as NSError
        var s = "\(n.localizedDescription) (\(n.domain) \(n.code))"
        if let u = n.userInfo[NSUnderlyingErrorKey] as? NSError { s += " ← \(u.localizedDescription) (\(u.domain) \(u.code))" }
        if let r = n.localizedFailureReason { s += " " + r }
        return s
    }

    /// `range` of a song as an AAC file (the 1.4.0 way, no composition).
    static func toAAC(_ asset: AVAsset, range: CMTimeRange) async -> Result<URL, Error> {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clip-sound-\(UUID().uuidString).m4a")
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return .failure(NSError(domain: "LoopPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no M4A export for this file"]))
        }
        s.outputURL = out
        s.outputFileType = .m4a
        s.timeRange = range
        let box = SessionBox(s)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.exportAsynchronously { c.resume() }
        }
        if box.session.status == .completed { return .success(out) }
        return .failure(box.session.error ?? NSError(domain: "LoopPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "M4A export stopped"]))
    }

    /// Average brightness 0...1 of a picture, measured on an 8x8 copy (tests: a clip must not
    /// come out black; Clip Studio's preview skips black frames). No Core Image (1.5.4).
    nonisolated static func brightness(_ cg: CGImage) -> Double {
        guard let c = ClipPainter.context(8, 8), let data = c.data else { return 1 }
        c.interpolationQuality = .medium
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let px = data.bindMemory(to: UInt8.self, capacity: c.bytesPerRow * 8)
        var sum = 0
        for y in 0..<8 { for x in 0..<8 { let i = y * c.bytesPerRow + x * 4; sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) } }
        return Double(sum) / (64 * 3 * 255)
    }

    /// Not async on purpose: from async code Swift picks the newer async insertTimeRange.
    nonisolated static func insert(_ range: CMTimeRange, of asset: AVAsset, times: Int, into comp: AVMutableComposition) throws {
        for _ in 0..<times { try comp.insertTimeRange(range, of: asset, at: comp.duration) }
    }

    /// Song card video: every picture drawn by `painter` and written with the sound file into
    /// one MP4 (no composition, no export session).
    nonisolated static func renderCard(sound: URL, painter: ClipPainter, render: CGSize, fps: Int32, to out: URL,
                                       stop: StopFlag, progress: @escaping @Sendable (Double) -> Void) async throws {
        func failure(_ text: String) -> NSError { NSError(domain: "LoopPlayer", code: 3, userInfo: [NSLocalizedDescriptionKey: text]) }
        try? FileManager.default.removeItem(at: out)
        let audioAsset = AVURLAsset(url: sound)
        let seconds = CMTimeGetSeconds(audioAsset.duration)
        guard seconds.isFinite, seconds > 0, let aTrack = audioAsset.tracks(withMediaType: .audio).first,
              let hint = aTrack.formatDescriptions.first else { throw failure("the sound file is empty") }
        let reader = try AVAssetReader(asset: audioAsset)
        let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
        guard reader.canAdd(aOut) else { throw failure("the sound can't be read") }
        reader.add(aOut)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let w = Int(render.width), h = Int(render.height)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * 4, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: (hint as! CMFormatDescription))
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw failure("the video can't be written") }
        writer.add(vIn)
        writer.add(aIn)
        guard reader.startReading() else { throw reader.error ?? failure("the sound can't be read") }
        guard writer.startWriting() else { throw writer.error ?? failure("the video can't be written") }
        writer.startSession(atSourceTime: .zero)

        let frames = max(1, Int((seconds * Double(fps)).rounded(.up)))
        let job = CardJob(frames: frames)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "loopplayer.card.video")) {
                while vIn.isReadyForMoreMediaData && !job.videoDone {
                    if job.frame >= job.frames || stop.stop || writer.status == .failed {
                        vIn.markAsFinished()
                        job.videoDone = true
                        group.leave()
                        return
                    }
                    autoreleasepool {
                        var pb: CVPixelBuffer?
                        if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
                        if let pb {
                            let t = Double(job.frame) / Double(fps)
                            if !painter.paint(nil, t: t, to: pb) { job.appendFailed = true }
                            if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(job.frame), timescale: fps)) {
                                job.appendFailed = true
                            }
                        } else {
                            job.appendFailed = true
                        }
                    }
                    job.frame += 1
                    if job.frame % 10 == 0 { progress(Double(job.frame) / Double(job.frames)) }
                }
            }
            aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "loopplayer.card.audio")) {
                while aIn.isReadyForMoreMediaData && !job.audioDone {
                    if !stop.stop, writer.status != .failed, let sample = aOut.copyNextSampleBuffer() {
                        aIn.append(sample)
                    } else {
                        aIn.markAsFinished()
                        job.audioDone = true
                        group.leave()
                        return
                    }
                }
            }
            group.notify(queue: .global()) { c.resume() }
        }
        if stop.stop {
            writer.cancelWriting()
            reader.cancelReading()
            throw CancellationError()
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? failure("the video couldn't be finished") }
        if job.appendFailed { FolderLog.append("Clip: some song card pictures were skipped") }
    }

    /// Video clip (1.5.2): the composition's pictures are read one by one (as stored, upright
    /// turning is the painter's job), painted by `painter` in Loop Player and written with the
    /// sound (speed, pitch and fades applied while reading) into one MP4. No export session.
    nonisolated static func renderVideo(_ comp: AVComposition, natural: CGSize, transform: CGAffineTransform, mix: AVAudioMix?, pitch: AVAudioTimePitchAlgorithm,
                                        painter: ClipPainter, render: CGSize, fps: Int32, length: Double, to out: URL,
                                        stop: StopFlag, progress: @escaping @Sendable (Double) -> Void) async throws {
        func failure(_ text: String) -> NSError { NSError(domain: "LoopPlayer", code: 4, userInfo: [NSLocalizedDescriptionKey: text]) }
        try? FileManager.default.removeItem(at: out)
        let vTracks = comp.tracks(withMediaType: .video)
        let aTracks = comp.tracks(withMediaType: .audio)
        guard let vTrack = vTracks.first, length > 0 else { throw failure("there's no picture to cut") }
        let reader = try AVAssetReader(asset: comp)
        reader.timeRange = CMTimeRange(start: .zero, duration: comp.duration)

        // Pictures at the composition's times (speed and loops), turned upright by AVFoundation
        // (1.5.4: the same turning the plain clip uses, which works on the iPhone).
        let vc = AVMutableVideoComposition()
        let up = CGRect(origin: .zero, size: natural).applying(transform)
        vc.renderSize = CGSize(width: max(2, (abs(up.width) / 2).rounded() * 2), height: max(2, (abs(up.height) / 2).rounded() * 2))
        vc.frameDuration = CMTime(value: 1, timescale: fps)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -up.minX, y: -up.minY)), at: .zero)
        instruction.layerInstructions = [layer]
        vc.instructions = [instruction]
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        vOut.videoComposition = vc
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw failure("the picture can't be read") }
        try ClipMaker.objc { reader.add(vOut) }

        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            o.audioMix = mix
            o.audioTimePitchAlgorithm = pitch
            if reader.canAdd(o) {
                try ClipMaker.objc { reader.add(o) }
                aOut = o
            }
        }

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let w = Int(render.width), h = Int(render.height)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(40_000_000, w * h * 4),
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(vIn) else { throw failure("the video can't be written") }
        try ClipMaker.objc { writer.add(vIn) }
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) {
                try ClipMaker.objc { writer.add(i) }
                aIn = i
            }
        }
        FolderLog.append("Clip step: reading \(Int(vc.renderSize.width))x\(Int(vc.renderSize.height)), writing \(w)x\(h) at \(fps) fps" + (aIn == nil ? ", no sound" : ""))
        guard try ClipMaker.objc({ reader.startReading() }) else { throw reader.error ?? failure("the clip can't be read") }
        guard try ClipMaker.objc({ writer.startWriting() }) else {
            reader.cancelReading()
            throw writer.error ?? failure("the video can't be written")
        }
        try ClipMaker.objc { writer.startSession(atSourceTime: .zero) }
        FolderLog.append("Clip step: reading and writing started")

        let job = CardJob(frames: 0)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "loopplayer.clip.video")) {
                while vIn.isReadyForMoreMediaData && !job.videoDone {
                    var done = stop.stop || writer.status != .writing || reader.status == .failed
                    if !done {
                        autoreleasepool {
                            var next: CMSampleBuffer?
                            do { next = try ClipMaker.objc { vOut.copyNextSampleBuffer() } } catch {
                                job.error = "reading a picture: \(error.localizedDescription)"
                                done = true
                                return
                            }
                            guard let sample = next else { done = true; return }
                            let time = CMSampleBufferGetPresentationTimeStamp(sample)
                            guard let src = CMSampleBufferGetImageBuffer(sample) else { return }
                            var pb: CVPixelBuffer?
                            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
                            guard let pb else { job.appendFailed = true; return }
                            let t = CMTimeGetSeconds(time)
                            do {
                                let ok = try ClipMaker.objc { () -> Bool in
                                    guard painter.paint(ClipPainter.cgImage(src), t: t, to: pb) else { return false }
                                    return adaptor.append(pb, withPresentationTime: time)
                                }
                                if !ok { job.appendFailed = true }
                            } catch {
                                job.error = "painting a picture: \(error.localizedDescription)"
                                done = true
                                return
                            }
                            job.frame += 1
                            if job.frame == 1 { FolderLog.append("Clip step: first picture painted and written") }
                            if job.frame % 10 == 0 { progress(min(1, max(0, t / length))) }
                        }
                    }
                    if done {
                        try? ClipMaker.objc { vIn.markAsFinished() }
                        job.videoDone = true
                        group.leave()
                        return
                    }
                }
            }
            if let aIn, let aOut {
                group.enter()
                aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "loopplayer.clip.audio")) {
                    while aIn.isReadyForMoreMediaData && !job.audioDone {
                        var sample: CMSampleBuffer?
                        if !stop.stop, writer.status == .writing, reader.status == .reading {
                            do { sample = try ClipMaker.objc { aOut.copyNextSampleBuffer() } } catch {
                                job.error = "reading the sound: \(error.localizedDescription)"
                            }
                        }
                        if let sample, (try? ClipMaker.objc { aIn.append(sample) }) != nil {
                            continue
                        } else {
                            try? ClipMaker.objc { aIn.markAsFinished() }
                            job.audioDone = true
                            group.leave()
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { c.resume() }
        }
        if stop.stop {
            writer.cancelWriting()
            reader.cancelReading()
            throw CancellationError()
        }
        if let e = job.error {
            writer.cancelWriting()
            reader.cancelReading()
            throw failure(e)
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? failure("the clip couldn't be read")
        }
        if job.frame == 0 {
            writer.cancelWriting()
            throw failure("no pictures came out")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? failure("the video couldn't be finished") }
        if job.appendFailed { FolderLog.append("Clip: some pictures were skipped") }
    }

    /// Runs an AVFoundation call and turns an Objective-C exception into a Swift error, so a
    /// refusal makes a plain clip instead of closing the app (1.5.3).
    nonisolated static func objc<T>(_ body: () -> T) throws -> T {
        var result: T?
        var err: NSError?
        let ok = LPTry({ result = body() }, &err)
        guard ok, let result else {
            throw err ?? NSError(domain: "LoopPlayer", code: 9, userInfo: [NSLocalizedDescriptionKey: "AVFoundation refused"])
        }
        return result
    }

    /// The details of a finished clip: for checking what Snapchat and Instagram are given.
    nonisolated static func describe(_ file: URL, isPhoto: Bool, took: Double) -> ClipResult {
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

    nonisolated private static func codec(_ t: AVAssetTrack) -> String {
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
            let img = UIImage(contentsOfFile: file.path)
            let px = img.map { "\(Int($0.size.width * $0.scale))x\(Int($0.size.height * $0.scale))" } ?? "none"
            lines.append("video=\(px)")
            if let cg = img?.cgImage { lines.append("brightness=\(String(format: "%.2f", ClipMaker.brightness(cg)))") }
        } else {
            let a = AVURLAsset(url: file)
            let v = a.tracks(withMediaType: .video).first
            if v != nil {
                let g = AVAssetImageGenerator(asset: a)
                g.appliesPreferredTrackTransform = true
                // The brightest of three moments (the test video has black parts).
                let d = CMTimeGetSeconds(a.duration)
                let light = [0.25, 0.5, 0.75].compactMap { f -> Double? in
                    guard let cg = try? g.copyCGImage(at: CMTime(seconds: d * f, preferredTimescale: 600), actualTime: nil) else { return nil }
                    return ClipMaker.brightness(cg)
                }.max()
                if let light { lines.append("brightness=\(String(format: "%.2f", light))") }
            }
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
        guard ClipMaker.smallEnough(file, for: "Instagram") else {
            error = "This clip is too big for Instagram Stories (over 100 MB). Pick 720p or a shorter length, or use Share."
            return
        }
        guard let data = try? Data(contentsOf: file, options: .uncached) else {
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
        guard ClipMaker.smallEnough(file, for: "Snapchat") else {
            error = "This clip is too big for Snapchat (over 100 MB). Pick 720p or a shorter length, or use Share."
            return
        }
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

    /// Clips handed to other apps through the pasteboard are read into memory whole: very big
    /// ones made Loop Player run out of memory and close.
    static func smallEnough(_ file: URL, for app: String) -> Bool {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if bytes > 100 * 1024 * 1024 {
            FolderLog.append("Clip: \(bytes / 1_048_576) MB is too big for \(app)")
            return false
        }
        return true
    }

    private func share(_ file: URL, attempt: Int = 0) {
        // An alert or sheet still closing can't present the share sheet (it never showed: 1.5.1).
        if let top = ClipMaker.topViewController(), top.isBeingDismissed || top.isBeingPresented || top is UIAlertController, attempt < 10 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.share(file, attempt: attempt + 1)
            }
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        guard let top = ClipMaker.topViewController() else {
            FolderLog.append("Clip share: no screen to show it on")
            error = "The share sheet couldn't open. The clip is in Clip Studio > Recent clips."
            return
        }
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 1, height: 1)
        FolderLog.append("Clip share: opening the share sheet")
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

/// Opens Clip Studio from the main screen. Its own object (1.5.2): the main screen used to watch
/// ClipMaker and redrew everything, sheets included, five times a second while a clip was made.
@MainActor
final class ClipStudioRouter: ObservableObject {
    static let shared = ClipStudioRouter()
    @Published var open = false
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

/// Cancel for a song card being drawn.
final class StopFlag: @unchecked Sendable {
    var stop = false
}

/// Song card drawing progress, shared by the writer's queues.
private final class CardJob: @unchecked Sendable {
    let frames: Int
    var frame = 0
    var videoDone = false
    var audioDone = false
    var appendFailed = false
    /// An Objective-C exception caught while painting (1.5.3).
    var error: String?
    init(frames: Int) { self.frames = frames }
}

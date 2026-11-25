import SwiftUI
import AVFoundation
import UIKit

// Share a clip (1.4.0): 10 s, 20 s or 1 minute of the playing video (or song), starting where it
// is now, cut into an MP4 and handed to the iPhone share sheet: Instagram (Stories, Reels, Chats),
// Snapchat, WhatsApp, Telegram, Messages, Save Video, and any other app that takes videos.

/// Where a finished clip goes.
enum ClipTarget {
    /// The iPhone share sheet (every app).
    case share
    /// Straight into Instagram's story editor, not saved to Photos.
    case instagramStory
    /// Straight into Snapchat as a full-screen snap (post it to your Story or send it), not
    /// saved to Photos and not as a chat attachment.
    case snapchat
}

@MainActor
final class ClipMaker: ObservableObject {
    static let shared = ClipMaker()
    static let lengths: [(String, Double)] = [("10 seconds", 10), ("20 seconds", 20), ("1 minute", 60)]

    /// 0...1 while a clip is being made, nil otherwise.
    @Published var progress: Double?
    @Published var error: String?
    /// Snapchat Story was picked but there's no Snap Kit client ID yet: the length waiting.
    @Published var snapSetup: Double?

    /// Snapchat only takes clips from apps with their own Snap Kit client ID (1.4.2 on the phone:
    /// "Snapchat pasted from Loop Player", then "Something went wrong").
    static var snapClientID: String {
        (UserDefaults.standard.string(forKey: "snapClientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Snapchat Story: asks for the client ID first if there is none.
    func toSnapchat(seconds: Double) {
        if ClipMaker.snapClientID.isEmpty {
            snapSetup = seconds
        } else {
            make(seconds: seconds, to: .snapchat)
        }
    }

    /// "Paste Client ID": takes a Snap Kit client ID from the clipboard. True when one was found.
    func pasteSnapClientID() -> Bool {
        let text = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let r = text.range(of: pattern, options: .regularExpression) else { return false }
        UserDefaults.standard.set(String(text[r]), forKey: "snapClientID")
        FolderLog.append("Clip: Snap Kit client ID saved")
        return true
    }
    private var session: AVAssetExportSession?

    func make(seconds: Double, to target: ClipTarget = .share) {
        guard progress == nil else { return }
        let player = Player.shared
        guard let track = player.current, let asset = player.avPlayer.currentItem?.asset else {
            error = "Play something first."
            return
        }
        let video = track.isVideo
        // Slowed (or sped up) in the player: the clip is too, with the same pitch setting (1.4.1).
        let rate = Double(player.rate > 0 ? player.rate : 1)
        let need = seconds * rate          // seconds of the original for `seconds` of clip
        let total = player.clock.duration > 0 ? player.clock.duration : CMTimeGetSeconds(asset.duration)
        var start = player.clock.time
        // Near the end: take the last part instead of a short clip.
        if total.isFinite, total > 0, start + need > total { start = max(0, total - need) }
        let length = total.isFinite && total > 0 ? min(need, total - start) : need
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: length, preferredTimescale: 600))

        var source: AVAsset = asset
        var exportRange = range
        if abs(rate - 1) > 0.001, let c = ClipMaker.scaled(asset, range: range, rate: rate) {
            source = c
            exportRange = CMTimeRange(start: .zero, duration: c.duration)
        }

        // H.264 1080p plays everywhere (Instagram, WhatsApp, older phones). Snapchat gets 720p:
        // a smaller file for its pasteboard hand-over (1080p was 24 MB for 9 s).
        let preset = !video ? AVAssetExportPresetAppleM4A
            : (target == .snapchat ? AVAssetExportPreset1280x720 : AVAssetExportPreset1920x1080)
        guard let s = AVAssetExportSession(asset: source, presetName: preset) else {
            error = "This file can't be cut into a clip."
            return
        }
        let type: AVFileType = video ? (s.supportedFileTypes.contains(.mp4) ? .mp4 : .mov) : .m4a
        let ext = type == .mp4 ? "mp4" : (type == .mov ? "mov" : "m4a")
        let name = ClipMaker.safeName(track.title) + " clip." + ext
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)   // old clips go
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(name)
        s.outputURL = out
        s.outputFileType = type
        s.timeRange = exportRange
        s.audioTimePitchAlgorithm = player.pitchAlgorithm
        s.shouldOptimizeForNetworkUse = true
        session = s
        progress = 0
        FolderLog.append("Clip: \(Int(length)) s of \(track.title) from \(Int(start)) s" + (source === asset ? "" : " at \(String(format: "%.2f", rate))x" + (player.keepPitch ? "" : ", pitch with speed")))

        let box = SessionBox(s)
        Task {
            while box.session.status == .waiting || box.session.status == .exporting {
                self.progress = Double(box.session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        s.exportAsynchronously {
            Task { @MainActor in
                self.progress = nil
                self.session = nil
                if box.session.status == .completed {
                    self.writeTestInfo(out)
                    switch target {
                    case .share: self.share(out)
                    case .instagramStory: self.toInstagramStory(out)
                    case .snapchat: self.toSnapchat(out)
                    }
                } else if box.session.status != .cancelled {
                    let why = box.session.error?.localizedDescription ?? "unknown error"
                    FolderLog.append("Clip failed: \(why)")
                    self.error = "The clip couldn't be made: \(why)"
                }
            }
        }
    }

    func cancel() { session?.cancelExport() }

    /// The part `range` of `asset`, played at `rate` (0.8 = slowed): picture and sound stretched
    /// to the new length. The export's pitch setting decides whether the pitch follows the speed.
    static func scaled(_ asset: AVAsset, range: CMTimeRange, rate: Double) -> AVAsset? {
        let comp = AVMutableComposition()
        do {
            try comp.insertTimeRange(range, of: asset, at: .zero)
        } catch {
            FolderLog.append("Clip: couldn't change the speed (\(error.localizedDescription)); normal speed")
            return nil
        }
        if let src = asset.tracks(withMediaType: .video).first {
            for t in comp.tracks(withMediaType: .video) { t.preferredTransform = src.preferredTransform }
        }
        let whole = CMTimeRange(start: .zero, duration: comp.duration)
        comp.scaleTimeRange(whole, toDuration: CMTimeMultiplyByFloat64(comp.duration, multiplier: 1 / rate))
        return comp
    }

    /// Automatic test only: what the clip came out as.
    private func writeTestInfo(_ file: URL) {
        if let out = ProcessInfo.processInfo.environment["TEST_CLIP_OUT"] {
            let a = AVURLAsset(url: file)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            let v = a.tracks(withMediaType: .video).first
            let lines = ["file=\(file.lastPathComponent)", "bytes=\(size)",
                         "seconds=\(String(format: "%.1f", CMTimeGetSeconds(a.duration)))",
                         "video=\(v.map { "\(Int($0.naturalSize.width))x\(Int($0.naturalSize.height))" } ?? "none")",
                         "audio=\(!a.tracks(withMediaType: .audio).isEmpty)"]
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// Instagram's "Share to Stories": the video goes on the pasteboard for Instagram only (for 5
    /// minutes) and Instagram opens its story editor with it. Nothing is saved to Photos.
    private func toInstagramStory(_ file: URL) {
        guard let data = try? Data(contentsOf: file) else {
            error = "The clip couldn't be read."
            return
        }
        let appID = (UserDefaults.standard.string(forKey: "igAppID") ?? "").filter(\.isNumber)
        let source = appID.isEmpty ? (Bundle.main.bundleIdentifier ?? "com.necro144.loopplayer") : appID
        guard let url = URL(string: "instagram-stories://share?source_application=\(source)") else { return }
        guard UIApplication.shared.canOpenURL(url) else {
            error = "Instagram isn't installed on this iPhone. Use Share instead."
            return
        }
        var item: [String: Any] = ["com.instagram.sharedSticker.backgroundVideo": data]
        if !appID.isEmpty { item["com.instagram.sharedSticker.appID"] = appID }
        UIPasteboard.general.setItems([item], options: [.expirationDate: Date().addingTimeInterval(300)])
        FolderLog.append("Clip: sent to Instagram Stories (\(data.count / 1024) KB" + (appID.isEmpty ? ", no Facebook App ID)" : ")"))
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok {
                Task { @MainActor in self?.error = "Instagram didn't open its story editor. Add a Facebook App ID in Settings > Share a Clip, or use Share instead." }
            }
        }
    }

    /// Snapchat's Creative Kit (the code-only "Lite" way from Snap's own sample): the video goes on
    /// the pasteboard for Snapchat (5 minutes, cleared once Snapchat reads it) and Snapchat opens
    /// its snap editor with it ("Snapchat pasted from Loop Player"). From there: My Story or a friend.
    private func toSnapchat(_ file: URL) {
        guard let data = try? Data(contentsOf: file, options: .uncached) else {
            error = "The clip couldn't be read."
            return
        }
        let clientID = ClipMaker.snapClientID
        guard var parts = URLComponents(string: "snapchat://creativekit/preview/1"),
              let probe = parts.url, UIApplication.shared.canOpenURL(probe) else {
            error = "Snapchat isn't installed on this iPhone. Use Share instead."
            return
        }
        var item: [String: Any] = ["com.snapchat.creativekit.backgroundVideo": data,
                                   "com.snapchat.creativekit.appName": "Loop Player"]
        if !clientID.isEmpty { item["com.snapchat.creativekit.clientID"] = clientID }
        UIPasteboard.general.setItems([item], options: [.expirationDate: Date().addingTimeInterval(300)])
        var query = [URLQueryItem(name: "checkcount", value: String(UIPasteboard.general.changeCount)),
                     URLQueryItem(name: "appDisplayName", value: "Loop Player")]
        if !clientID.isEmpty { query.insert(URLQueryItem(name: "clientId", value: clientID), at: 1) }
        parts.queryItems = query
        guard let url = parts.url else { return }
        FolderLog.append("Clip: sent to Snapchat (\(data.count / 1024) KB" + (clientID.isEmpty ? ", no Snap client ID)" : ")"))
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok {
                Task { @MainActor in self?.error = "Snapchat didn't open. Use Share instead." }
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

/// "Share a Clip" menu: pick the length.
struct ClipShareMenu<Label: View>: View {
    let video: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Section(video ? "Share a clip from here" : "Share a sound clip from here") {
                ForEach(ClipMaker.lengths, id: \.1) { item in
                    Button { ClipMaker.shared.make(seconds: item.1) } label: {
                        SwiftUI.Label(item.0, systemImage: item.1 < 30 ? "timer" : "clock")
                    }
                }
            }
            if video {
                Menu {
                    ForEach(ClipMaker.lengths, id: \.1) { item in
                        Button { ClipMaker.shared.toSnapchat(seconds: item.1) } label: {
                            SwiftUI.Label(item.0, systemImage: item.1 < 30 ? "timer" : "clock")
                        }
                    }
                } label: {
                    SwiftUI.Label("Snapchat Story", systemImage: "camera.viewfinder")
                }
                Menu {
                    ForEach(ClipMaker.lengths, id: \.1) { item in
                        Button { ClipMaker.shared.make(seconds: item.1, to: .instagramStory) } label: {
                            SwiftUI.Label(item.0, systemImage: item.1 < 30 ? "timer" : "clock")
                        }
                    }
                } label: {
                    SwiftUI.Label("Instagram Story", systemImage: "camera.circle")
                }
            }
        } label: { label() }
    }
}

/// Progress while the clip is cut, and errors.
struct ClipProgressOverlay: View {
    @ObservedObject private var maker = ClipMaker.shared

    var body: some View {
        ZStack {
            if let p = maker.progress {
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
        .alert("Share a Clip", isPresented: Binding(get: { maker.error != nil }, set: { if !$0 { maker.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(maker.error ?? "") }
        .alert("Snapchat needs a client ID", isPresented: Binding(get: { maker.snapSetup != nil }, set: { if !$0 { maker.snapSetup = nil } })) {
            Button("Paste Client ID") {
                let secs = maker.snapSetup ?? 10
                maker.snapSetup = nil
                if maker.pasteSnapClientID() {
                    maker.make(seconds: secs, to: .snapchat)
                } else {
                    maker.error = "No client ID on the clipboard. Copy the Public OAuth Client ID (it looks like 1a2b3c4d-...) from kit.snapchat.com, then try again."
                }
            }
            Button("Open kit.snapchat.com") {
                maker.snapSetup = nil
                if let u = URL(string: "https://kit.snapchat.com/manage") { UIApplication.shared.open(u) }
            }
            Button("Try Anyway") {
                let secs = maker.snapSetup ?? 10
                maker.snapSetup = nil
                maker.make(seconds: secs, to: .snapchat)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Snapchat only takes clips from apps with their own free Snap Kit ID (other apps have theirs). One time, about 5 minutes: on kit.snapchat.com log in with your Snapchat, New App, any name, iOS bundle ID com.necro144.loopplayer, add your Snapchat username under Demo Users, turn on Creative Kit, then copy the Public OAuth Client ID (Development) and tap Paste Client ID here.")
        }
    }
}

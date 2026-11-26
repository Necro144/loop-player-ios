import SwiftUI
import AVFoundation
import UIKit

// Real snaps (1.5.5). Snapchat labels every photo or video another app hands it as
// "Media Upload". The one way to make a real snap is Snapchat's camera mode: Loop Player puts a
// sticker (the song card, or a picked photo) on Snapchat's live camera, and the snap is taken in
// Snapchat itself. Format from Snap's own Creative Kit Lite sample (CKLiteSample, CKLite.swift).

extension ClipMaker {
    /// Opens Snapchat's camera with `sticker` on it. `widthShare`: part of the screen width.
    func toSnapchatCamera(sticker: UIImage, caption: String? = nil, widthShare: CGFloat = 0.62, posY: Float = 0.5) {
        guard let png = sticker.pngData() else {
            error = "The sticker couldn't be made."
            return
        }
        let clientID = ClipMaker.snapClientID
        guard var parts = URLComponents(string: "snapchat://creativekit/camera/1") else { return }
        // Sizes are in points of a ~360 pt wide phone screen (Snap's sample: 200 x 200).
        let w = Int(360 * widthShare)
        let h = Int(CGFloat(w) * sticker.size.height / max(sticker.size.width, 1))
        var item: [String: Any] = [
            "com.snapchat.creativekit.clientID": clientID,
            "com.snapchat.creativekit.appName": "Loop Player",
            "com.snapchat.creativekit.stickerImage": png,
            "com.snapchat.creativekit.payloadMetadata": [
                "stickerMetadata": ["posX": Float(0.5), "posY": posY, "rotation": Float(0), "widthDp": w, "heightDp": h] as [String: Any],
            ] as [String: Any],
        ]
        if let caption, !caption.isEmpty { item["com.snapchat.creativekit.captionText"] = caption }
        UIPasteboard.general.setItems([item], options: [.expirationDate: Date().addingTimeInterval(300)])
        parts.queryItems = [URLQueryItem(name: "checkcount", value: String(UIPasteboard.general.changeCount)),
                            URLQueryItem(name: "clientId", value: clientID),
                            URLQueryItem(name: "appDisplayName", value: "Loop Player")]
        guard let url = parts.url else { return }
        FolderLog.append("Snapchat camera: sticker \(Int(sticker.size.width))x\(Int(sticker.size.height)) (\(png.count / 1024) KB), \(w)x\(h) pt")
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok {
                FolderLog.append("Snapchat camera: snapchat:// didn't open")
                Task { @MainActor in self?.error = "Snapchat didn't open. Is Snapchat installed?" }
            }
        }
    }

    /// The playing song as a sticker: its picture with rounded corners, the title and artist under it.
    nonisolated static func songSticker(title: String, artist: String, art: URL?) -> UIImage? {
        let side: CGFloat = 600
        let pad: CGFloat = 36
        let width = side + pad * 2
        let height = side + pad * 2 + 150
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        let artImage = art.flatMap { UIImage(contentsOfFile: $0.path) }
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: f).image { _ in
            let card = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 48)
            UIColor(white: 0.06, alpha: 0.88).setFill()
            card.fill()
            let box = CGRect(x: pad, y: pad, width: side, height: side)
            let clip = UIBezierPath(roundedRect: box, cornerRadius: 30)
            UIGraphicsGetCurrentContext()?.saveGState()
            clip.addClip()
            if let artImage {
                let s = max(side / artImage.size.width, side / artImage.size.height)
                let w = artImage.size.width * s, h = artImage.size.height * s
                artImage.draw(in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            } else if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [UIColor(red: 1, green: 0.27, blue: 0.47, alpha: 1).cgColor,
                                                  UIColor(red: 1, green: 0.55, blue: 0.35, alpha: 1).cgColor] as CFArray,
                                         locations: [0, 1]) {
                UIGraphicsGetCurrentContext()?.drawLinearGradient(g, start: box.origin, end: CGPoint(x: box.maxX, y: box.maxY), options: [])
                let note = NSAttributedString(string: "♪", attributes: [.font: UIFont.systemFont(ofSize: 260, weight: .bold),
                                                                        .foregroundColor: UIColor.white.withAlphaComponent(0.85)])
                let ns = note.size()
                note.draw(at: CGPoint(x: box.midX - ns.width / 2, y: box.midY - ns.height / 2))
            }
            UIGraphicsGetCurrentContext()?.restoreGState()
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: title, attributes: [.font: UIFont.systemFont(ofSize: 46, weight: .bold),
                                                           .foregroundColor: UIColor.white, .paragraphStyle: p])
                .draw(in: CGRect(x: pad, y: side + pad + 22, width: side, height: 58))
            let sub = artist.isEmpty || artist == "Unknown Artist" ? "▶︎ Loop Player" : artist + "  ·  ▶︎ Loop Player"
            NSAttributedString(string: sub, attributes: [.font: UIFont.systemFont(ofSize: 32, weight: .medium),
                                                         .foregroundColor: UIColor.white.withAlphaComponent(0.7), .paragraphStyle: p])
                .draw(in: CGRect(x: pad, y: side + pad + 86, width: side, height: 44))
        }
    }

    /// A photo as a sticker: at most 900 px, rounded corners.
    nonisolated static func photoSticker(_ img: UIImage) -> UIImage? {
        let long = max(img.size.width, img.size.height, 1)
        let k = min(1, 900 / long)
        let size = CGSize(width: max(1, (img.size.width * k).rounded()), height: max(1, (img.size.height * k).rounded()))
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: min(size.width, size.height) * 0.05).addClip()
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The playing song as a sticker on Snapchat's camera.
    func songToSnapchatCamera() {
        guard let t = Player.shared.current else {
            error = "Play a song first."
            return
        }
        let art = t.hasArtwork ? AppPaths.artworkFile(for: t.id) : nil
        Task { @MainActor in
            let img = await Task.detached(priority: .userInitiated) {
                ClipMaker.songSticker(title: t.title, artist: t.artist, art: art)
            }.value
            guard let img else {
                self.error = "The sticker couldn't be made."
                return
            }
            self.writeStickerTest(img)
            self.toSnapchatCamera(sticker: img, widthShare: 0.6, posY: 0.42)
        }
    }

    /// A photo as a sticker on Snapchat's camera.
    func photoToSnapchatCamera(_ file: URL) {
        guard let d = try? Data(contentsOf: file), let ui = UIImage(data: d), let img = ClipMaker.photoSticker(ui) else {
            error = "The photo couldn't be read."
            return
        }
        writeStickerTest(img)
        toSnapchatCamera(sticker: img, widthShare: 0.8)
    }

    /// Simulator test: the sticker's size.
    private func writeStickerTest(_ img: UIImage) {
        guard let out = ProcessInfo.processInfo.environment["TEST_STICKER_OUT"] else { return }
        try? "sticker=\(Int(img.size.width))x\(Int(img.size.height))\npng=\((img.pngData()?.count ?? 0) / 1024)".write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// Deletes the saved recent clips and picked files. Returns what was freed.
    static func clearRecent() -> String {
        let fm = FileManager.default
        var bytes = 0
        var dirs = [folder, fm.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)]
        if let tmp = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            dirs += tmp.filter { $0.lastPathComponent.hasPrefix("clip-sound-") || $0.lastPathComponent.hasPrefix("card-sound-") }
        }
        for d in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir) else { continue }
            let files = isDir.boolValue ? ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []) : [d]
            for f in files {
                bytes += (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
                try? fm.removeItem(at: f)
            }
        }
        shared.last = nil
        FolderLog.append("Recent clips cleared (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))")
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static var recentSize: String {
        let bytes = recentClips().reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

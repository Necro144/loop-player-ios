import SwiftUI
import AVFoundation
import CoreImage
import UIKit

// Clip Studio (1.5.0): the choices for a clip and the picture painter that makes them.

/// The picture shape of a clip.
enum ClipSize: String, CaseIterable, Codable, Identifiable {
    case original, story, square, portrait, youtube, cinematic, classic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .story: return "Story 9:16"
        case .square: return "Square 1:1"
        case .portrait: return "Portrait 4:5"
        case .youtube: return "YouTube 16:9"
        case .cinematic: return "Cinematic 2.39:1"
        case .classic: return "Classic 4:3"
        }
    }

    var hint: String {
        switch self {
        case .original: return "As it is"
        case .story: return "Snapchat, Instagram & TikTok stories, Reels, Shorts"
        case .square: return "Instagram feed, WhatsApp status"
        case .portrait: return "Instagram post"
        case .youtube: return "YouTube, TV, laptop"
        case .cinematic: return "Movie look"
        case .classic: return "Old TV"
        }
    }

    /// Width / height, nil = the source's own shape.
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .story: return 9.0 / 16.0
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .youtube: return 16.0 / 9.0
        case .cinematic: return 2.39
        case .classic: return 4.0 / 3.0
        }
    }
}

/// How the picture fits a shape that isn't its own.
enum ClipFraming: String, CaseIterable, Codable, Identifiable {
    case blur, fill, fit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blur: return "Blur bars"
        case .fill: return "Fill (crop)"
        case .fit: return "Black bars"
        }
    }
}

/// Colour looks (Core Image).
enum ClipLook: String, CaseIterable, Codable, Identifiable {
    case none, vivid, warm, cool, mono, noir, vintage, chrome, fade, dream, pixel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Normal"
        case .vivid: return "Vivid"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .mono: return "Mono"
        case .noir: return "Noir"
        case .vintage: return "Vintage"
        case .chrome: return "Chrome"
        case .fade: return "Faded"
        case .dream: return "Dream"
        case .pixel: return "8-bit"
        }
    }

    func apply(_ i: CIImage) -> CIImage {
        switch self {
        case .none: return i
        case .vivid: return i.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.45, "inputContrast": 1.08])
        case .warm: return i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1.08, y: 0, z: 0, w: 0),
                                                              "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                                                              "inputBVector": CIVector(x: 0, y: 0, z: 0.86, w: 0)])
        case .cool: return i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
                                                              "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                                                              "inputBVector": CIVector(x: 0, y: 0, z: 1.12, w: 0)])
        case .mono: return i.applyingFilter("CIPhotoEffectMono")
        case .noir: return i.applyingFilter("CIPhotoEffectNoir")
        case .vintage: return i.applyingFilter("CIPhotoEffectTransfer")
        case .chrome: return i.applyingFilter("CIPhotoEffectChrome")
        case .fade: return i.applyingFilter("CIPhotoEffectFade")
        case .dream: return i.applyingFilter("CIBloom", parameters: ["inputRadius": 12, "inputIntensity": 0.7]).cropped(to: i.extent)
        case .pixel:
            let scale = max(6, min(i.extent.width, i.extent.height) / 90)
            return i.applyingFilter("CIPixellate", parameters: ["inputScale": scale,
                                                    "inputCenter": CIVector(x: i.extent.midX, y: i.extent.midY)]).cropped(to: i.extent)
        }
    }
}

enum ClipQuality: String, CaseIterable, Codable, Identifiable {
    case auto, p720, p1080, k4
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .k4: return "4K"
        }
    }
    /// The long side of the picture in pixels.
    func longSide(for target: ClipTarget) -> CGFloat {
        switch self {
        case .auto: return target == .snapchat ? 1280 : 1920
        case .p720: return 1280
        case .p1080: return 1920
        case .k4: return 3840
        }
    }
}

enum ClipStart: String, CaseIterable, Codable, Identifiable {
    case here, beginning, loop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .here: return "From here"
        case .beginning: return "From the start"
        case .loop: return "A-B loop"
        }
    }
}

/// Everything picked in Clip Studio. Remembered between clips.
struct ClipOptions: Codable, Equatable {
    var seconds: Double = 15
    var start: ClipStart = .here
    var size: ClipSize = .original
    var framing: ClipFraming = .blur
    var look: ClipLook = .none
    /// 0 = the player's speed.
    var speed: Double = 0
    var keepPitch = false
    var repeats = 1
    var caption = ""
    var showTitle = false
    var watermark = false
    var fade = false
    var quality: ClipQuality = .auto
    /// Songs without a picture: a sound file instead of a song card video.
    var soundOnly = false

    static let lengthChoices: [Double] = [5, 10, 15, 20, 30, 40, 45, 60, 90, 120, 180, 300, 600]
    static let speedChoices: [Double] = [0, 0.5, 0.75, 0.8, 1, 1.25, 1.5, 2]

    static func label(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n < 60 { return "\(n) s" }
        if n % 60 == 0 { return "\(n / 60) min" }
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }

    static var saved: ClipOptions {
        guard let d = UserDefaults.standard.data(forKey: "clipOptions.v1"),
              let o = try? JSONDecoder().decode(ClipOptions.self, from: d) else { return ClipOptions() }
        return o
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "clipOptions.v1") }
    }

    /// The picture size in pixels (even numbers, as video wants).
    static func renderSize(source: CGSize, size: ClipSize, quality: ClipQuality, target: ClipTarget) -> CGSize {
        let cap = quality.longSide(for: target)
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        if let r = size.ratio {
            return r >= 1 ? CGSize(width: even(cap), height: even(cap / r)) : CGSize(width: even(cap * r), height: even(cap))
        }
        let long = max(source.width, source.height, 2)
        let k = long > cap ? cap / long : 1
        return CGSize(width: even(source.width * k), height: even(source.height * k))
    }
}

/// Where the song card's parts go (UIKit coordinates: y from the top).
struct ClipCardLayout {
    let side: CGFloat, artCenterY: CGFloat, titleY: CGFloat, barY: CGFloat, barHeight: CGFloat, captionY: CGFloat
    init(_ r: CGSize) {
        let k = min(r.width, r.height) / 1080
        side = min(r.width, r.height) * 0.55
        artCenterY = r.height * 0.42
        titleY = artCenterY + side / 2 + 70 * k
        barY = titleY + 84 * k
        barHeight = max(4, 8 * k)
        captionY = max(40 * k, (artCenterY - side / 2) / 2)
    }
}

/// Paints every frame of a clip: shape, framing, look, song card, text and fades.
/// Runs on AVFoundation's own threads, so it only holds values that never change.
final class ClipPainter: @unchecked Sendable {
    let render: CGSize
    let framing: ClipFraming
    let look: ClipLook
    let natural: CGSize
    let orientation: CGImagePropertyOrientation?
    let overlay: CIImage?
    let fade: Bool
    let total: Double
    /// Song card: the song's picture (looks already applied).
    let art: CIImage?

    init(render: CGSize, framing: ClipFraming, look: ClipLook, natural: CGSize, orientation: CGImagePropertyOrientation?,
         overlay: CIImage?, fade: Bool, total: Double, art: CIImage?) {
        self.render = render
        self.framing = framing
        self.look = look
        self.natural = natural
        self.orientation = orientation
        self.overlay = overlay
        self.fade = fade
        self.total = total
        self.art = art.map { look.apply($0) }
    }

    /// Portrait phone videos are stored sideways with a turn in the track.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation? {
        if abs(t.a) < 0.01, t.b > 0.5, t.c < -0.5 { return .right }
        if abs(t.a) < 0.01, t.b < -0.5, t.c > 0.5 { return .left }
        return nil
    }

    private var outRect: CGRect { CGRect(origin: .zero, size: render) }
    private var black: CIImage { CIImage(color: .black).cropped(to: outRect) }

    func frame(_ source: CIImage, t: Double) -> CIImage {
        var out: CIImage
        if let art {
            out = card(art, t: t)
        } else {
            var img = source
            // Turn sideways phone videos upright when AVFoundation hasn't (the frame still has the
            // stored, sideways size).
            if let o = orientation, natural.width != natural.height,
               abs(img.extent.width - natural.width) < 2, abs(img.extent.height - natural.height) < 2 {
                img = img.oriented(o)
            }
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            img = look.apply(img)
            switch framing {
            case .fill: out = place(img, scale: fillScale(img))
            case .fit: out = place(img, scale: fitScale(img)).composited(over: black)
            case .blur: out = place(img, scale: fitScale(img)).composited(over: blurred(img))
            }
        }
        if let overlay { out = overlay.composited(over: out) }
        if fade, total > 0 {
            let a = CGFloat(max(0, min(1, t / 0.6, (total - t) / 0.6)))
            if a < 1 {
                out = out.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                                                           "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                                                           "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0)])
            }
        }
        return out.composited(over: black).cropped(to: outRect)
    }

    private func fillScale(_ i: CIImage) -> CGFloat {
        max(render.width / max(i.extent.width, 1), render.height / max(i.extent.height, 1))
    }

    private func fitScale(_ i: CIImage) -> CGFloat {
        min(render.width / max(i.extent.width, 1), render.height / max(i.extent.height, 1))
    }

    /// `i` scaled and centred in the clip.
    private func place(_ i: CIImage, scale s: CGFloat, centerY: CGFloat? = nil) -> CIImage {
        let x = i.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let cy = centerY ?? render.height / 2
        return x.transformed(by: CGAffineTransform(translationX: (render.width - x.extent.width) / 2 - x.extent.minX,
                                                   y: cy - x.extent.height / 2 - x.extent.minY))
    }

    /// The picture filling the clip, blurred and a bit darker (blurred small, then stretched: fast).
    private func blurred(_ i: CIImage) -> CIImage {
        let s = fillScale(i) / 8
        let small = i.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let b = small.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: ["inputBrightness": -0.12, "inputSaturation": 1.2])
        return place(b, scale: 8).cropped(to: outRect)
    }

    /// Song card: blurred picture behind, the picture gently bouncing, a moving progress bar.
    private func card(_ art: CIImage, t: Double) -> CIImage {
        let l = ClipCardLayout(render)
        let bounce = 1 + 0.025 * CGFloat(sin(t * .pi * 2))
        let s = l.side / max(art.extent.width, art.extent.height, 1) * bounce
        let a = place(art, scale: s, centerY: render.height - l.artCenterY)
        var out = a.composited(over: blurred(art))
        let w = render.width * 0.72
        let x0 = (render.width - w) / 2
        let y0 = render.height - l.barY - l.barHeight
        let track = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.28))
            .cropped(to: CGRect(x: x0, y: y0, width: w, height: l.barHeight))
        let p = total > 0 ? CGFloat(min(1, max(0, t / total))) : 0
        let bar = CIImage(color: CIColor(red: 1, green: 0.27, blue: 0.47))
            .cropped(to: CGRect(x: x0, y: y0, width: max(l.barHeight, w * p), height: l.barHeight))
        out = bar.composited(over: track.composited(over: out))
        return out
    }

    /// The song's picture, or a Loop Player gradient when it has none.
    static func artImage(_ file: URL?) -> CIImage {
        if let file, let ui = UIImage(contentsOfFile: file.path), let cg = ui.cgImage {
            return CIImage(cgImage: cg)
        }
        let r = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        return CIImage(color: .black).cropped(to: r).applyingFilter("CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 1000), "inputColor0": CIColor(red: 1, green: 0.27, blue: 0.47),
            "inputPoint1": CIVector(x: 1000, y: 0), "inputColor1": CIColor(red: 1, green: 0.55, blue: 0.35),
        ]).cropped(to: r)
    }

    /// Text on top of the clip (title, caption, stamp), drawn once.
    static func overlay(size: CGSize, options o: ClipOptions, title: String, artist: String, card: Bool) -> CIImage? {
        let caption = o.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let showTitle = (card || o.showTitle) && !title.isEmpty
        guard !caption.isEmpty || showTitle || o.watermark else { return nil }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        let k = min(size.width, size.height) / 1080
        let layout = ClipCardLayout(size)
        let image = UIGraphicsImageRenderer(size: size, format: f).image { _ in
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = 10 * k
            shadow.shadowOffset = .zero
            func draw(_ text: String, font: UIFont, color: UIColor = .white, centerY: CGFloat, align: NSTextAlignment = .center) {
                let p = NSMutableParagraphStyle()
                p.alignment = align
                p.lineBreakMode = .byWordWrapping
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color,
                                                                      .paragraphStyle: p, .shadow: shadow])
                let w = size.width * 0.86
                let box = s.boundingRect(with: CGSize(width: w, height: size.height), options: [.usesLineFragmentOrigin], context: nil)
                s.draw(with: CGRect(x: (size.width - w) / 2, y: centerY - box.height / 2, width: w, height: ceil(box.height)),
                       options: [.usesLineFragmentOrigin], context: nil)
            }
            if showTitle {
                let line = artist.isEmpty || artist == "Unknown Artist" ? title : title + "\n" + artist
                draw(line, font: .systemFont(ofSize: 44 * k, weight: .bold), centerY: card ? layout.titleY : size.height * 0.89)
            }
            if !caption.isEmpty {
                draw(caption, font: .systemFont(ofSize: 60 * k, weight: .heavy),
                     centerY: card ? layout.captionY : size.height * (showTitle ? 0.74 : 0.8))
            }
            if o.watermark {
                draw("▶︎ Loop Player", font: .systemFont(ofSize: 28 * k, weight: .semibold),
                     color: UIColor.white.withAlphaComponent(0.75), centerY: 48 * k, align: .right)
            }
        }
        return image.cgImage.map { CIImage(cgImage: $0) }
    }
}

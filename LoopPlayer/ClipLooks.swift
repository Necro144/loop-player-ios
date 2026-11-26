import SwiftUI
import AVFoundation
import Accelerate
import VideoToolbox
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

/// Colour looks (vImage colour matrices, 1.5.4).
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
}

/// Where the caption goes.
enum CaptionPlace: String, CaseIterable, Codable, Identifiable {
    case top, middle, bottom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Caption colours.
enum CaptionColor: String, CaseIterable, Codable, Identifiable {
    case white, yellow, pink, cyan, black
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var ui: UIColor {
        switch self {
        case .white: return .white
        case .yellow: return UIColor(red: 1, green: 0.86, blue: 0.2, alpha: 1)
        case .pink: return UIColor(red: 1, green: 0.27, blue: 0.47, alpha: 1)
        case .cyan: return UIColor(red: 0.3, green: 0.9, blue: 1, alpha: 1)
        case .black: return .black
        }
    }
    var color: Color { Color(ui) }
}

/// How a song's picture moves on its song card.
enum CardStyle: String, CaseIterable, Codable, Identifiable {
    case bounce, vinyl, still
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bounce: return "Bounce"
        case .vinyl: return "Spinning vinyl"
        case .still: return "Still"
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
    var captionPlace: CaptionPlace = .bottom
    var captionColor: CaptionColor = .white
    var cardStyle: CardStyle = .bounce

    static let lengthChoices: [Double] = [5, 10, 15, 20, 30, 40, 45, 60, 90, 120, 180, 300, 600]
    static let speedChoices: [Double] = [0, 0.5, 0.75, 0.8, 1, 1.25, 1.5, 2]

    static func label(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n < 60 { return "\(n) s" }
        if n % 60 == 0 { return "\(n / 60) min" }
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }

    /// The last choices. New choices added in an update get their defaults; the old ones stay.
    static var saved: ClipOptions {
        guard let d = UserDefaults.standard.data(forKey: "clipOptions.v1"),
              let stored = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let defaults = try? JSONEncoder().encode(ClipOptions()),
              var base = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any] else { return ClipOptions() }
        base.merge(stored) { _, new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject: base),
              var o = try? JSONDecoder().decode(ClipOptions.self, from: merged) else { return ClipOptions() }
        o.seconds = min(600, max(1, o.seconds))
        o.repeats = min(5, max(1, o.repeats))
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
            // Square: 1080x1080 at 1080p (the long side of a 16:9 picture would make it 1920x1920).
            if abs(r - 1) < 0.001 { return CGSize(width: even(cap * 9 / 16), height: even(cap * 9 / 16)) }
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
/// 1.5.4: Core Graphics and vImage only. Core Image crashed inside Apple's code on the owner's
/// iPhone (signal 11 in CoreImage on the first picture, 1.5.3), and before that in iOS's media
/// service (1.5.0/1.5.1). Runs on AVFoundation's own threads; holds only values that never change.
final class ClipPainter: @unchecked Sendable {
    let render: CGSize
    let framing: ClipFraming
    let look: ClipLook
    let overlay: CGImage?
    let fade: Bool
    let total: Double
    let cardStyle: CardStyle
    /// Song card: the song's picture with the look applied, its square middle and the blurred background.
    let art: CGImage?
    private let artSquare: CGImage?
    private let artBack: CGImage?

    static let space = CGColorSpaceCreateDeviceRGB()
    /// BGRA in memory, like the video pixel buffers.
    static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(render: CGSize, framing: ClipFraming, look: ClipLook, overlay: CGImage?, fade: Bool, total: Double,
         art: CGImage?, cardStyle: CardStyle = .bounce) {
        self.render = render
        self.framing = framing
        self.look = look
        self.overlay = overlay
        self.fade = fade
        self.total = total
        self.cardStyle = cardStyle
        if let art {
            let a = ClipPainter.looked(art, look: look) ?? art
            self.art = a
            let side = min(a.width, a.height)
            artSquare = a.cropping(to: CGRect(x: (a.width - side) / 2, y: (a.height - side) / 2, width: side, height: side))
            artBack = ClipPainter.blurred(a, fill: render)
        } else {
            self.art = nil
            artSquare = nil
            artBack = nil
        }
    }

    // MARK: Painting

    /// Paints into a pixel buffer from the writer's pool (BGRA).
    func paint(_ src: CGImage?, t: Double, to pb: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: ClipPainter.space, bitmapInfo: ClipPainter.info) else { return false }
        paint(src, t: t, into: ctx)
        return true
    }

    /// One finished picture (photos and the preview).
    func image(_ src: CGImage?, t: Double) -> CGImage? {
        guard let ctx = ClipPainter.context(Int(render.width), Int(render.height)) else { return nil }
        paint(src, t: t, into: ctx)
        return ctx.makeImage()
    }

    func paint(_ src: CGImage?, t: Double, into ctx: CGContext) {
        let full = CGRect(origin: .zero, size: render)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(full)
        ctx.interpolationQuality = .medium
        if art != nil {
            card(ctx, t: t)
        } else if let src {
            var pic = src
            if look == .pixel, let p = ClipPainter.pixelated(src) { pic = p }
            let iw = CGFloat(pic.width), ih = CGFloat(pic.height)
            let fill = max(render.width / max(iw, 1), render.height / max(ih, 1))
            let fit = min(render.width / max(iw, 1), render.height / max(ih, 1))
            if framing == .blur, let b = ClipPainter.blurred(src, fill: render) {
                ctx.draw(b, in: full)
            }
            let box = place(iw, ih, scale: framing == .fill ? fill : fit, centerY: render.height / 2)
            ctx.saveGState()
            if look == .pixel { ctx.interpolationQuality = .none }
            ctx.draw(pic, in: box)
            ctx.restoreGState()
            if look == .dream, let g = ClipPainter.blurred(src, fill: box.size, darken: false) {
                ctx.saveGState()
                ctx.setBlendMode(.screen)
                ctx.setAlpha(0.45)
                ctx.draw(g, in: box)
                ctx.restoreGState()
            }
            ClipPainter.applyLook(look, to: ctx)
        }
        if let overlay { ctx.draw(overlay, in: full) }
        if fade, total > 0 {
            let a = CGFloat(max(0, min(1, t / 0.6, (total - t) / 0.6)))
            if a < 1 {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1 - a))
                ctx.fill(full)
            }
        }
    }

    /// A picture `w`x`h` scaled by `scale` and centred (y from the bottom, as Core Graphics counts).
    private func place(_ w: CGFloat, _ h: CGFloat, scale s: CGFloat, centerY: CGFloat) -> CGRect {
        CGRect(x: (render.width - w * s) / 2, y: centerY - h * s / 2, width: w * s, height: h * s)
    }

    /// Song card: blurred picture behind, the picture bouncing or spinning, a moving progress bar.
    private func card(_ ctx: CGContext, t: Double) {
        guard let art else { return }
        let l = ClipCardLayout(render)
        if let artBack { ctx.draw(artBack, in: CGRect(origin: .zero, size: render)) }
        let bounce = cardStyle == .bounce ? 1 + 0.025 * CGFloat(sin(t * .pi * 2)) : 1
        let cy = render.height - l.artCenterY
        if cardStyle == .vinyl, let sq = artSquare {
            let side = l.side * bounce
            ctx.saveGState()
            ctx.translateBy(x: render.width / 2, y: cy)
            ctx.rotate(by: -CGFloat(t) * .pi * 2 / 3)
            let r = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
            ctx.addEllipse(in: r)
            ctx.clip()
            ctx.draw(sq, in: r)
            ctx.restoreGState()
            let hole = side * 0.056
            ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: render.width / 2 - hole, y: cy - hole, width: hole * 2, height: hole * 2))
        } else {
            let s = l.side / CGFloat(max(art.width, art.height, 1)) * bounce
            ctx.draw(art, in: place(CGFloat(art.width), CGFloat(art.height), scale: s, centerY: cy))
        }
        let w = render.width * 0.72
        let x0 = (render.width - w) / 2
        let y0 = render.height - l.barY - l.barHeight
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.fill(CGRect(x: x0, y: y0, width: w, height: l.barHeight))
        let p = total > 0 ? CGFloat(min(1, max(0, t / total))) : 0
        ctx.setFillColor(CGColor(red: 1, green: 0.27, blue: 0.47, alpha: 1))
        ctx.fill(CGRect(x: x0, y: y0, width: max(l.barHeight, w * p), height: l.barHeight))
    }

    // MARK: Helpers

    static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: info)
    }

    /// A video picture as a Core Graphics image (VideoToolbox, no Core Image).
    static func cgImage(_ pb: CVPixelBuffer) -> CGImage? {
        var out: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &out)
        return out
    }

    /// The picture filling `fill`, small, blurred and a little darker; stretched when drawn.
    static func blurred(_ img: CGImage, fill: CGSize, darken: Bool = true) -> CGImage? {
        let k: CGFloat = 1 / 12
        let w = max(8, Int(fill.width * k)), h = max(8, Int(fill.height * k))
        guard let small = context(w, h) else { return nil }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = max(CGFloat(w) / max(iw, 1), CGFloat(h) / max(ih, 1))
        small.interpolationQuality = .medium
        small.draw(img, in: CGRect(x: (CGFloat(w) - iw * s) / 2, y: (CGFloat(h) - ih * s) / 2, width: iw * s, height: ih * s))
        guard let data = small.data, let out = context(w, h), let outData = out.data else { return nil }
        var src = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: small.bytesPerRow)
        var dst = vImage_Buffer(data: outData, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: out.bytesPerRow)
        let kernel = UInt32(max(3, (min(w, h) / 8) | 1))
        vImageTentConvolve_ARGB8888(&src, &dst, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
        vImageTentConvolve_ARGB8888(&dst, &src, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
        if darken { ColorMatrix.saturation(1.2).then(.brightness(-0.12)).apply(to: small) }
        return small.makeImage()
    }

    /// Big square pixels: the picture drawn small; drawn back without smoothing.
    static func pixelated(_ img: CGImage) -> CGImage? {
        let scale = max(6, CGFloat(min(img.width, img.height)) / 90)
        let w = max(4, Int(CGFloat(img.width) / scale)), h = max(4, Int(CGFloat(img.height) / scale))
        guard let c = context(w, h) else { return nil }
        c.interpolationQuality = .medium
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }

    /// `img` with `look` applied (song card pictures, once).
    static func looked(_ img: CGImage, look: ClipLook) -> CGImage? {
        guard look != .none else { return img }
        var src = img
        if look == .pixel, let p = pixelated(img) { src = p }
        let long = max(src.width, src.height)
        let k = long > 1200 ? 1200 / CGFloat(long) : 1
        let w = Int(CGFloat(img.width) * k), h = Int(CGFloat(img.height) * k)
        guard let c = context(w, h) else { return nil }
        c.interpolationQuality = look == .pixel ? .none : .high
        c.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        if look == .dream, let g = blurred(img, fill: CGSize(width: w, height: h), darken: false) {
            c.setBlendMode(.screen)
            c.setAlpha(0.45)
            c.draw(g, in: CGRect(x: 0, y: 0, width: w, height: h))
            c.setBlendMode(.normal)
            c.setAlpha(1)
        }
        applyLook(look, to: c)
        return c.makeImage()
    }

    static func applyLook(_ look: ClipLook, to ctx: CGContext) {
        look.matrix?.apply(to: ctx)
    }

    /// The song's picture, or a Loop Player gradient when it has none.
    static func artImage(_ file: URL?) -> CGImage? {
        if let file, let ui = UIImage(contentsOfFile: file.path) {
            // Upright (pictures can carry a turn).
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            let long = max(ui.size.width, ui.size.height, 1)
            let k = min(1, 1200 / long)
            let s = CGSize(width: max(1, (ui.size.width * k).rounded()), height: max(1, (ui.size.height * k).rounded()))
            if let cg = UIGraphicsImageRenderer(size: s, format: f).image(actions: { _ in ui.draw(in: CGRect(origin: .zero, size: s)) }).cgImage {
                return cg
            }
        }
        guard let c = context(1000, 1000) else { return nil }
        let colors = [CGColor(red: 1, green: 0.27, blue: 0.47, alpha: 1), CGColor(red: 1, green: 0.55, blue: 0.35, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: 1000), end: CGPoint(x: 1000, y: 0), options: [])
        }
        return c.makeImage()
    }

    /// Text on top of the clip (title, caption, stamp), drawn once.
    static func overlay(size: CGSize, options o: ClipOptions, title: String, artist: String, card: Bool) -> CGImage? {
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
                shadow.shadowColor = color == .black ? UIColor.white.withAlphaComponent(0.8) : UIColor.black.withAlphaComponent(0.75)
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
                let y: CGFloat
                switch o.captionPlace {
                case .top: y = card ? layout.captionY : size.height * 0.14
                case .middle: y = card ? layout.artCenterY : size.height * 0.5
                case .bottom: y = card ? min(size.height - 60 * k, layout.barY + 90 * k) : size.height * (showTitle ? 0.74 : 0.8)
                }
                draw(caption, font: .systemFont(ofSize: 60 * k, weight: .heavy), color: o.captionColor.ui, centerY: y)
            }
            if o.watermark {
                draw("▶︎ Loop Player", font: .systemFont(ofSize: 28 * k, weight: .semibold),
                     color: UIColor.white.withAlphaComponent(0.75), centerY: 48 * k, align: .right)
            }
        }
        return image.cgImage
    }
}

/// A colour change: out = m · (r, g, b) + bias, with 0...1 colours (vImage does the work).
struct ColorMatrix {
    /// Row by row: the new red from r, g, b; then green; then blue.
    var m: [Float]
    var bias: [Float]

    static let identity = ColorMatrix(m: [1, 0, 0, 0, 1, 0, 0, 0, 1], bias: [0, 0, 0])
    static func diagonal(_ r: Float, _ g: Float, _ b: Float) -> ColorMatrix { ColorMatrix(m: [r, 0, 0, 0, g, 0, 0, 0, b], bias: [0, 0, 0]) }
    static func saturation(_ s: Float) -> ColorMatrix {
        let lr: Float = 0.2126, lg: Float = 0.7152, lb: Float = 0.0722
        let i = 1 - s
        return ColorMatrix(m: [i * lr + s, i * lg, i * lb,
                               i * lr, i * lg + s, i * lb,
                               i * lr, i * lg, i * lb + s], bias: [0, 0, 0])
    }
    static func contrast(_ c: Float) -> ColorMatrix {
        let b = 0.5 * (1 - c)
        return ColorMatrix(m: [c, 0, 0, 0, c, 0, 0, 0, c], bias: [b, b, b])
    }
    static func brightness(_ v: Float) -> ColorMatrix { ColorMatrix(m: identity.m, bias: [v, v, v]) }

    /// This change, then `next`.
    func then(_ next: ColorMatrix) -> ColorMatrix {
        var out = [Float](repeating: 0, count: 9)
        var b = [Float](repeating: 0, count: 3)
        for r in 0..<3 {
            for c in 0..<3 {
                out[r * 3 + c] = (0..<3).reduce(0) { $0 + next.m[r * 3 + $1] * m[$1 * 3 + c] }
            }
            b[r] = (0..<3).reduce(next.bias[r]) { $0 + next.m[r * 3 + $1] * bias[$1] }
        }
        return ColorMatrix(m: out, bias: b)
    }

    /// Changes a BGRA picture in place.
    func apply(to ctx: CGContext) {
        guard let data = ctx.data else { return }
        var buf = vImage_Buffer(data: data, height: vImagePixelCount(ctx.height), width: vImagePixelCount(ctx.width), rowBytes: ctx.bytesPerRow)
        apply(to: &buf)
    }

    func apply(to buf: inout vImage_Buffer) {
        // vImage: out[d] = Σ in[s] · matrix[s * 4 + d] (channels as stored: B, G, R, A).
        let mem = [2, 1, 0]   // r, g, b → place in memory
        var vm = [Int16](repeating: 0, count: 16)
        var post = [Int32](repeating: 0, count: 4)
        let divisor: Int32 = 256
        for o in 0..<3 {
            for s in 0..<3 {
                vm[mem[s] * 4 + mem[o]] = Int16(max(-32767, min(32767, (m[o * 3 + s] * Float(divisor)).rounded())))
            }
            post[mem[o]] = Int32((bias[o] * 255 * Float(divisor)).rounded())
        }
        vm[3 * 4 + 3] = Int16(divisor)
        vImageMatrixMultiply_ARGB8888(&buf, &buf, vm, divisor, nil, post, vImage_Flags(kvImageNoFlags))
    }
}

extension ClipLook {
    /// The colour change of this look (8-bit and Dream also change the picture itself).
    var matrix: ColorMatrix? {
        switch self {
        case .none, .pixel: return nil
        case .vivid: return ColorMatrix.saturation(1.45).then(.contrast(1.08))
        case .warm: return .diagonal(1.08, 1.0, 0.86)
        case .cool: return .diagonal(0.9, 1.0, 1.12)
        case .mono: return ColorMatrix.saturation(0).then(.contrast(1.05))
        case .noir: return ColorMatrix.saturation(0).then(.contrast(1.35)).then(.brightness(-0.03))
        case .vintage: return ColorMatrix(m: [0.86, 0.22, 0.05, 0.14, 0.82, 0.12, 0.06, 0.16, 0.66], bias: [0.05, 0.03, 0.0]).then(.contrast(0.95))
        case .chrome: return ColorMatrix.saturation(1.25).then(.contrast(1.12))
        case .fade: return ColorMatrix.saturation(0.65).then(.contrast(0.85)).then(.brightness(0.05))
        case .dream: return ColorMatrix.saturation(1.1).then(.brightness(0.03)).then(.diagonal(1.04, 0.98, 1.04))
        }
    }
}

/// Paints a made-up picture in every look, shape and card style (Settings > Check clip painting,
/// and the simulator test): proves painting works on this iPhone without making a video.
enum PaintCheck {
    static func run() -> [String] {
        var lines: [String] = []
        let started = Date()
        guard let c = ClipPainter.context(64, 64) else { return ["paint check: no picture"] }
        // Pure red: tells whether the colour matrices use the right channels.
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let red = c.makeImage() else { return ["paint check: no picture"] }
        for look in ClipLook.allCases {
            let p = ClipPainter(render: CGSize(width: 64, height: 64), framing: .fill, look: look, overlay: nil, fade: false, total: 0, art: nil)
            guard let img = p.image(red, t: 0), let px = pixel(img, 32, 32) else { lines.append("look \(look.rawValue): failed"); continue }
            lines.append("look \(look.rawValue): r=\(px.0) g=\(px.1) b=\(px.2)")
        }
        let art = ClipPainter.artImage(nil)
        for size in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)] {
            for f in ClipFraming.allCases {
                let p = ClipPainter(render: size, framing: f, look: .vivid, overlay: nil, fade: true, total: 2, art: nil)
                lines.append("frame \(f.rawValue) \(Int(size.width))x\(Int(size.height)): " + (p.image(art, t: 1) == nil ? "failed" : "ok"))
            }
            for s in CardStyle.allCases {
                let p = ClipPainter(render: size, framing: .blur, look: .mono, overlay: nil, fade: false, total: 10, art: art, cardStyle: s)
                lines.append("card \(s.rawValue) \(Int(size.width))x\(Int(size.height)): " + (p.image(nil, t: 3) == nil ? "failed" : "ok"))
            }
        }
        lines.append(String(format: "paint check took %.2f s", Date().timeIntervalSince(started)))
        return lines
    }

    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int)? {
        guard let c = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let d = c.data else { return nil }
        c.draw(img, in: CGRect(x: -x, y: -y, width: img.width, height: img.height))
        let p = d.bindMemory(to: UInt8.self, capacity: 4)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }
}

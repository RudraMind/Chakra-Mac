import AppKit

/// Draws Chakra's app icon and writes an `.iconset` directory for `iconutil`.
///
/// The icon is drawn rather than shipped as a binary asset so it lives in the
/// repository as readable code, and so the shape can follow the app: eight dots
/// on the outer ring, five on the inner one, and a hole in the middle, which is
/// exactly what the wheel shows.
///
/// Proportions are all fractions of the artwork's side, so every size from 16 to
/// 1024 points is the same drawing rather than a scaled bitmap.
@main
struct MakeIcon {
    /// Every size `iconutil` expects, as (points, scale). A missing size makes
    /// macOS scale a neighbour, which looks soft in the Dock.
    static let sizes: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
        (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    static func main() {
        let directory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "build/Chakra.iconset"

        // AppKit has to be initialised before colours and gradients will draw.
        NSApplication.shared.setActivationPolicy(.prohibited)

        do {
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory): \(error)\n".utf8))
            exit(1)
        }

        for (points, scale) in sizes {
            let pixels = points * scale
            let suffix = scale == 1 ? "" : "@\(scale)x"
            let path = "\(directory)/icon_\(points)x\(points)\(suffix).png"
            guard let data = png(side: pixels) else {
                FileHandle.standardError.write(Data("cannot render \(path)\n".utf8))
                exit(1)
            }
            do {
                try data.write(to: URL(fileURLWithPath: path))
            } catch {
                FileHandle.standardError.write(Data("cannot write \(path): \(error)\n".utf8))
                exit(1)
            }
        }
        print("wrote \(sizes.count) images to \(directory)")
    }

    /// One square PNG. The bitmap is one pixel per point, so `draw` can work in
    /// points and the caller decides the resolution.
    static func png(side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Freshly allocated bitmap memory is not zeroed; an icon has to start
        // fully transparent or the rounded corners come out as noise.
        context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.imageInterpolation = .high
        draw(side: CGFloat(side))
        NSGraphicsContext.restoreGraphicsState()

        // The rep must be told its own size or the PNG records the wrong DPI.
        rep.size = NSSize(width: side, height: side)
        return rep.representation(using: .png, properties: [:])
    }

    static func draw(side: CGFloat) {
        // Apple's icon grid: the artwork sits inside the canvas with a margin, so
        // neighbouring icons in the Dock do not touch.
        let inset = side * 0.0977
        let art = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
        let squircle = NSBezierPath(roundedRect: art,
                                    xRadius: art.width * 0.2237,
                                    yRadius: art.width * 0.2237)

        // A near-black aubergine, light at the top the way every other icon in the
        // Dock is lit. The backdrop is deliberately dark and almost colourless: the
        // colour in this icon comes from the outer dots, and a saturated backdrop
        // would compete with them. Channels are written as hex over 255 so the
        // drawn result matches the reviewed mock-up exactly rather than to two
        // decimal places.
        //
        // The cost of going this dark, measured rather than assumed: the body's
        // contrast against a pure black wallpaper fell from 3.32:1 to 1.37:1, and
        // the centre from 2.22:1 to 1.18:1. On a black desktop the squircle itself
        // is effectively invisible and only the rim and the dots delineate the
        // icon. That is an accepted trade for the dots reading as the subject; it is
        // recorded here because nothing else in the file would reveal it.
        let backdrop = NSGradient(starting: NSColor(srgbRed: 0x2A / 255, green: 0x21 / 255,
                                                   blue: 0x40 / 255, alpha: 1),
                                  ending: NSColor(srgbRed: 0x0C / 255, green: 0x08 / 255,
                                                  blue: 0x17 / 255, alpha: 1))
        backdrop?.draw(in: squircle, angle: -90)

        // A hairline rim, which is what stops the squircle looking flat against a
        // dark Dock.
        //
        // Raising alpha from 0.22 to 0.26 improves the rim against its own body
        // (1.59:1 to 2.34:1) but makes it worse against a black wallpaper (5.28:1
        // to 3.21:1), because the body underneath lost 84% of its luminance and an
        // 18% alpha increase cannot offset that. Do not read this 0.26 as solving
        // the dark-wallpaper case; it does not, and raising it further is the lever
        // if that case ever matters.
        NSColor.white.withAlphaComponent(0.26).setStroke()
        squircle.lineWidth = max(side * 0.006, 0.5)
        squircle.stroke()

        let center = CGPoint(x: art.midX, y: art.midY)
        let unit = art.width

        // The two bands the dots sit on, dropped from 0.22/0.20 to 0.140/0.126
        // because white at 22% visibly turned the old violet backdrop chalky.
        //
        // Measured, the drop exactly cancels the backdrop darkening: band-against-
        // backdrop contrast is 1.259:1 here versus 1.255:1 before at 16 points, and
        // 1.288:1 versus 1.279:1 at 32 points. So these bands are no more and no
        // less visible than the old ones. Note what that also says about the
        // original intent: at 1.26:1 the bands were never really "what keeps the
        // icon reading as a ring" in either version. They are a faint hint at best.
        // Whether they earn their place at all is an open question, not a settled
        // one.
        band(center: center, radius: unit * 0.330, width: unit * 0.150, alpha: 0.140)
        band(center: center, radius: unit * 0.180, width: unit * 0.100, alpha: 0.126)

        // Eight fixed slots outside, five recents inside — the wheel itself. The
        // outer ring sweeps the whole hue circle, one step per slot, which is where
        // the app's name comes from. The inner ring stays neutral so the recents
        // read as secondary rather than as five more colours competing.
        dots(count: 8, center: center, radius: unit * 0.330, diameter: unit * 0.125,
             color: nil, alpha: 1)
        dots(count: 5, center: center, radius: unit * 0.180, diameter: unit * 0.082,
             color: .white, alpha: 0.66)
    }

    private static func band(center: CGPoint, radius: CGFloat, width: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.lineWidth = width
        path.stroke()
    }

    /// Dots starting at twelve o'clock and going clockwise, so the icon and the
    /// wheel agree about where slot 0 is.
    ///
    /// Passing `color: nil` sweeps the hue circle across the ring, one step per
    /// dot, instead of filling every dot the same. Saturation stops short of full
    /// so the hues stay legible rather than vibrating against the dark backdrop.
    ///
    /// `brightness: 1` is HSB brightness, which is not luminance, and the two must
    /// not be confused here. At `saturation: 0.85` the eight dots span relative
    /// luminances of 0.148 to 0.792 — a 5.35x spread — where the white dots this
    /// replaced were all exactly 1.0. Measured against each dot's own backdrop, at
    /// 32 points four of the eight fall below the 3:1 WCAG non-text threshold
    /// (violet 2.22:1, blue 2.47:1, red 2.76:1, magenta 3.28:1) and at 16 points
    /// all eight fall below 2:1, where the previous white dots held 2.34:1 to
    /// 3.71:1 throughout. No dot disappears — every one still perturbs its four
    /// pixels at 16x16 — but the ring reads as a bright arc and a dark arc rather
    /// than as eight equal slots, and two adjacent pairs merge under deuteranopia.
    ///
    /// This is a deliberate, owner-approved trade for an icon that matches the
    /// app's own colourful wheel (`WheelView.swift:450`, on by default per
    /// `Defaults.swift:370`). If small-size legibility is ever prioritised over
    /// that, the lever is per-hue brightness compensation, not saturation.
    private static func dots(count: Int, center: CGPoint, radius: CGFloat,
                             diameter: CGFloat, color: NSColor?, alpha: CGFloat) {
        for index in 0..<count {
            let fill = color ?? NSColor(hue: CGFloat(index) / CGFloat(count),
                                        saturation: 0.85, brightness: 1, alpha: 1)
            fill.withAlphaComponent(alpha).setFill()

            let angle = CGFloat.pi / 2 - 2 * CGFloat.pi * CGFloat(index) / CGFloat(count)
            let point = CGPoint(x: center.x + cos(angle) * radius,
                                y: center.y + sin(angle) * radius)
            NSBezierPath(ovalIn: NSRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                        width: diameter, height: diameter)).fill()
        }
    }
}

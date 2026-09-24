import AppKit

/// Renders the wheel to PNG files without putting anything on screen.
///
/// This exists because the wheel is a floating window over the desktop, and
/// screenshotting it needs Screen Recording permission. Rendering the same
/// `WheelView` and the same donut mask offscreen verifies the geometry, the
/// icons, the highlight and the centre pill with no permission at all. What it
/// cannot show is the live blur, since `NSVisualEffectView` has nothing to blur
/// offscreen — the grey ring here stands in for it.
@main
struct Preview {
    // Only apps that ship with macOS, so any Mac (and the CI runner) renders the same wheel.
    static let apps = ["/System/Applications/FaceTime.app",
                       "/System/Applications/Mail.app",
                       "/System/Applications/Calendar.app",
                       "/System/Applications/Utilities/Terminal.app",
                       "/System/Applications/Music.app",
                       "/System/Applications/Photos.app",
                       "/System/Applications/System Settings.app",
                       "/System/Applications/Maps.app"]

    static let recents = ["/System/Applications/Reminders.app",
                          "/System/Applications/App Store.app",
                          "/System/Applications/Messages.app",
                          "/System/Applications/Notes.app",
                          "/System/Applications/Preview.app"]

    static func main() {
        // Initialises AppKit for fonts and colours without showing anything.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"

        for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                   ("dark", NSAppearance.Name.darkAqua)] {
            guard let look = NSAppearance(named: appearance) else { continue }
            look.performAsCurrentDrawingAppearance {
                write(scene(outer: apps, inner: recents, colorful: false, scale: 1),
                      to: "\(outputDirectory)/preview-\(name).png")
                write(scene(outer: apps, inner: recents, colorful: true, scale: 1),
                      to: "\(outputDirectory)/preview-\(name)-colorful.png")
            }
        }

        guard let aqua = NSAppearance(named: .darkAqua) else { return }
        aqua.performAsCurrentDrawingAppearance {
            write(scene(outer: [], inner: [], colorful: false, scale: 1),
                  to: "\(outputDirectory)/preview-empty.png")
            // The two ends of the size slider, which are the sizes a user can
            // actually ask for. Any real display is roomy enough to grant both,
            // so these are rendered from the setting rather than from a screen —
            // an earlier version passed a "small screen" that in fact fitted the
            // wheel at full size, and silently produced a duplicate of the
            // scale-1 preview.
            write(scene(outer: apps, inner: recents, colorful: false,
                        scale: CGFloat(Settings.minWheelSize)),
                  to: "\(outputDirectory)/preview-small.png")
            write(scene(outer: apps, inner: recents, colorful: false,
                        scale: CGFloat(Settings.maxWheelSize)),
                  to: "\(outputDirectory)/preview-large.png")
            // Mid-turn, which is the state the wheel is in while it is being
            // scrolled and part way through the opening sweep. Both rings are
            // turned by a third of a step so nothing lands on a resting angle.
            let base = RingGeometry()
            write(scene(outer: apps, inner: recents, colorful: true, scale: 1,
                        outerRotation: base.step(.outer) / 3,
                        innerRotation: base.step(.inner) / 3),
                  to: "\(outputDirectory)/preview-turning.png")
            // And settled one whole step round, which is where a scroll leaves it.
            write(scene(outer: apps, inner: recents, colorful: true, scale: 1,
                        outerRotation: base.step(.outer),
                        innerRotation: base.step(.inner)),
                  to: "\(outputDirectory)/preview-turned.png")
        }

        write(WheelController.donutMask(geometry: RingGeometry()), to: "\(outputDirectory)/preview-mask.png")
        print("wrote previews to \(outputDirectory)/")
    }

    /// One wheel over a stand-in desktop.
    static func scene(outer: [String], inner: [String], colorful: Bool, scale: CGFloat,
                      outerRotation: CGFloat = 0, innerRotation: CGFloat = 0) -> NSImage {
        let geometry = RingGeometry(scale: scale, outerRotation: outerRotation,
                                    innerRotation: innerRotation)
        let side = (geometry.discRadius + geometry.margin) * 2
        let canvas = NSRect(x: 0, y: 0, width: side, height: side)
        let center = CGPoint(x: side / 2, y: side / 2)

        let view = WheelView(frame: canvas)
        view.geometry = geometry
        view.wheelCenter = center
        view.colorful = colorful
        view.outerItems = (0..<geometry.outerSlotCount).map { index in
            index < outer.count ? RingItem.make(path: outer[index]) : nil
        }
        view.innerItems = inner.map { RingItem.make(path: $0) }
        // Two of them get an activity dot so that path is exercised too.
        view.runningPaths = Set(outer.prefix(2).map { RingItem.normalizePath($0) })
        // Puts a highlight plate and the centre pill on the first occupied slot
        // without needing a synthetic mouse event.
        view.resetTransientState()

        let image = NSImage(size: canvas.size)
        image.lockFocus()

        // A stand-in wallpaper, so a hole in the glass is visible as a hole.
        NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.42, alpha: 1),
                            NSColor(calibratedRed: 0.42, green: 0.16, blue: 0.36, alpha: 1)])?
            .draw(in: canvas, angle: 55)

        // Where the two glass bands would be, using the app's own path.
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: dark ? 0.12 : 0.92, alpha: 0.55).setFill()
        WheelController.glassPath(geometry: geometry, center: center).fill()

        view.draw(canvas)
        image.unlockFocus()
        return image
    }

    static func write(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("could not encode \(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            print("could not write \(path): \(error.localizedDescription)")
        }
    }
}

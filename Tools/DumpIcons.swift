import AppKit

/// Dumps application icons to PNG, for the HTML design mockups.
///
/// In the repository rather than in /tmp so the mockups can be rebuilt from a fresh
/// checkout: they need the real icons to show the colours the app will actually draw,
/// and a mockup that cannot be regenerated is a mockup that quietly goes stale.
///
/// Deliberately NOT listed in `build.sh`'s sources. It carries its own `@main`, which
/// cannot coexist with the app's top-level code, and it is built on demand by
/// `dump-icons.sh`.
@main
struct DumpIcons {
    static func main() {
        let outputDirectory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "/tmp/chakra-icons"
        try? FileManager.default.createDirectory(atPath: outputDirectory,
                                                 withIntermediateDirectories: true)

        // Keyed by the file stem the mockups ask for. An app that is not installed is
        // skipped and named, so a missing colour is explained rather than mysterious.
        let apps = [
            ("slack", "/Applications/Slack.app"),
            ("teams", "/Applications/Microsoft Teams.app"),
            ("claude", "/Applications/Claude.app"),
            ("terminal", "/System/Applications/Utilities/Terminal.app"),
            ("chrome", "/Applications/Google Chrome.app"),
            ("apps", "/System/Applications/Apps.app"),
            ("finder", "/System/Library/CoreServices/Finder.app"),
            ("raycast", "/Applications/Raycast.app"),
            ("appstore", "/System/Applications/App Store.app"),
            ("settings", "/System/Applications/System Settings.app"),
            ("notes", "/System/Applications/Notes.app"),
            ("preview", "/System/Applications/Preview.app"),
        ]

        var written = 0
        var skipped: [String] = []
        for (name, path) in apps {
            guard FileManager.default.fileExists(atPath: path) else {
                skipped.append(name)
                continue
            }
            let side = 256
            let icon = NSWorkspace.shared.icon(forFile: path)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: side, pixelsHigh: side,
                                             bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bytesPerRow: side * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // Freshly allocated bitmap memory is not zeroed, so an icon with no
            // representations would read back as garbage rather than as nothing.
            context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
            written += 1
        }

        if !skipped.isEmpty {
            print("not installed, skipped: \(skipped.joined(separator: ", "))")
        }
        print("wrote \(written) icons to \(outputDirectory)")
        // A run that produced nothing would leave the mockups reading an empty
        // directory and inventing no colours at all, so it is a failure, not a warning.
        if written == 0 { exit(1) }
    }
}

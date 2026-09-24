import AppKit
import UniformTypeIdentifiers

/// One launchable thing in the wheel.
///
/// An item whose file has disappeared is still a valid `RingItem` with
/// `isMissing` set, because silently dropping a slot would hide from the user
/// that something on their ring broke.
struct RingItem {
    let url: URL
    let name: String
    let icon: NSImage
    let isMissing: Bool

    var path: String { url.path }

    /// Collapses every spelling of one file to a single canonical form, so the
    /// same app can never occupy two slots or appear on both rings at once.
    ///
    /// String canonicalisation alone is not enough. macOS hands the same app out
    /// under several names — a symlink or Finder alias, the `/Volumes/Macintosh
    /// HD` and `/System/Volumes/Data` firmlinks, and any case variant on a
    /// case-insensitive volume — and all of them must compare equal. Only the
    /// filesystem can answer that, so an existing file is resolved through
    /// `canonicalPath`. A path that does not exist falls back to string
    /// canonicalisation, which is the best that can be known about it.
    ///
    /// `canonicalPath` resolves symlinked parent directories but leaves the last
    /// component's own link alone, and that is the behaviour Chakra wants. A
    /// Homebrew cask installs `/Applications/Foo.app` as a link into a
    /// version-numbered Caskroom directory; following it would store a path that
    /// breaks at the next upgrade, while the link the user picked keeps working.
    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        if let values = try? standardized.resourceValues(forKeys: [.canonicalPathKey]),
           let canonical = values.canonicalPath, !canonical.isEmpty {
            return canonical
        }
        return standardized.path
    }

    static func make(path: String) -> RingItem {
        let normalized = normalizePath(path)
        let exists = !normalized.isEmpty && FileManager.default.fileExists(atPath: normalized)
        // The bundle's own modification date is the cache's validity stamp: an app
        // that is updated in place keeps its path but gets a new icon.
        let stamp = exists ? modificationDate(of: normalized) : nil

        cacheLock.lock()
        let cached = cache[normalized]
        let reusable = cached.map {
            isCacheEntryValid(cachedStamp: $0.stamp, currentStamp: stamp,
                              cachedMissing: $0.item.isMissing, currentlyMissing: !exists)
        } ?? false
        if reusable { cacheHits += 1 }
        cacheLock.unlock()
        if reusable, let cached { return cached.item }

        let url = URL(fileURLWithPath: normalized.isEmpty ? "/" : normalized)
        let item = RingItem(url: url,
                            name: displayName(path: normalized, url: url),
                            icon: loadIcon(path: normalized, exists: exists),
                            isMissing: !exists)
        cacheLock.lock()
        cacheMisses += 1
        // A crude eviction: the wheel holds thirteen items and onboarding a few
        // dozen, so the cache only grows without bound if something goes wrong.
        // Dropping all of it costs one rebuild per visible item.
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[normalized] = (stamp, item)
        cacheLock.unlock()
        return item
    }

    /// Built items, so reopening the wheel does not re-read thirteen icons off
    /// disk. `NSWorkspace.icon(forFile:)` renders the bundle's icon resource and
    /// `displayName(atPath:)` reads its Info.plist; both are far dearer than the
    /// two stats this cache spends to decide whether the entry is still good.
    ///
    /// A lock rather than a main-thread assumption: `make` is called from the
    /// status item, the wheel, onboarding and the settings window, and one of them
    /// moving to a background queue must not silently corrupt a dictionary.
    private static let cacheLock = NSLock()
    private static var cache: [String: (stamp: Date?, item: RingItem)] = [:]
    private static let cacheLimit = 128

    /// Counters for the tests: a cache that never hits is a cache that is broken,
    /// and nothing else about it is observable from outside.
    static var cacheHits = 0
    static var cacheMisses = 0

    /// Forgets everything, counters included. Only the tests need this; the app
    /// relies on the modification-date check instead.
    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheHits = 0
        cacheMisses = 0
        cacheLock.unlock()
    }

    /// Whether a cached entry still describes the file on disk. Split out from the
    /// I/O so the rule itself can be tested.
    ///
    /// Two entries with no stamp are only interchangeable when both are missing: a
    /// missing item's name and icon come from the path alone. A file that exists
    /// but will not report a date — an unreadable parent directory, an exotic
    /// filesystem — is rebuilt every time rather than trusted.
    static func isCacheEntryValid(cachedStamp: Date?, currentStamp: Date?,
                                 cachedMissing: Bool, currentlyMissing: Bool) -> Bool {
        guard cachedMissing == currentlyMissing else { return false }
        if currentlyMissing { return true }
        guard let cachedStamp, let currentStamp else { return false }
        return cachedStamp == currentStamp
    }

    private static func modificationDate(of path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private static func displayName(path: String, url: URL) -> String {
        guard !path.isEmpty else { return "Unknown" }
        var name = FileManager.default.displayName(atPath: path)
        if name.isEmpty { name = url.lastPathComponent }
        // Finder hides the extension for installed apps but not for paths that
        // no longer exist, so strip it either way.
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "Unknown" : name
    }

    private static func loadIcon(path: String, exists: Bool) -> NSImage {
        let base = exists
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .applicationBundle)
        // The type-based icon may be shared, so resize a copy rather than
        // mutating an image other callers hold.
        let image = (base.copy() as? NSImage) ?? base
        image.size = NSSize(width: 128, height: 128)
        return image
    }

    /// Whether a path lives on the startup disk. Apps on a mounted disk image
    /// must stay out of the recents ring, since the volume is usually gone by
    /// the time the user goes looking for them.
    static func isOnBootVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey]),
              let isRoot = values.volumeIsRootFileSystem else { return false }
        return isRoot
    }

    /// Locations an app can be running from that a slot must never point at.
    ///
    /// Written in lower case, because `isPlausibleAppPath` compares a lower-cased path
    /// against them. A capital letter here would silently never match, which is the bug
    /// this list used to have.
    private static let unstablePrefixes = [
        // A genuinely separate volume — the boot disk's own firmlink resolves away
        // in `normalizePath` — so this may be a disk image or a network share
        // whose server is gone.
        "/volumes/",
        // The per-user temporary tree. Gatekeeper runs a quarantined app from a
        // randomly named read-only copy under here (App Translocation), and that
        // copy is destroyed when the app quits, so the path is dead by the time
        // the user next opens the wheel.
        "/private/var/folders/",
        "/private/tmp/",
        "/tmp/",
    ]

    /// Whether a path could be a durable app, judged from the string alone.
    ///
    /// Pure, and separate from `isEligibleForRecents`, because the interesting
    /// cases are paths that are not on this machine: a translocated bundle, an app
    /// on a volume that is not mounted. Deciding those needs no filesystem, and
    /// the `/Volumes` and temporary-folder checks have to come before any
    /// `fileExists` call — a stale network mount would otherwise block the wheel
    /// for the mount's own timeout.
    static func isPlausibleAppPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        // Anything that activates is an application as far as the workspace
        // notification is concerned, including a bare executable with no bundle
        // around it, so the extension is what separates a real app from a tool.
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        // Lower-cased once and used for both tests. Mixing a case-insensitive suffix check
        // with a case-sensitive prefix check was a real hole: `/Volumes/Foo.app` was
        // rejected while `/volumes/Foo.app`, `/VOLUMES/Foo.app`, `/TMP/Foo.app`,
        // `/private/TMP/Foo.app` and `/private/VAR/folders/…` all passed.
        //
        // `normalizePath` closes the hole only for paths that exist, and the paths this
        // filter exists for are precisely the ones that do not — an unmounted disk image,
        // a destroyed translocation copy, a dead network share. A leaked entry survived
        // `Recents.decode` into the forty-entry queue and then reached `fileExists`, which
        // is the stall the docstring above says must never happen.
        let lowered = trimmed.lowercased()
        guard lowered.hasSuffix(".app") else { return false }
        return !unstablePrefixes.contains(where: { lowered.hasPrefix($0) })
    }

    /// The production eligibility test for the recents ring.
    static func isEligibleForRecents(_ path: String) -> Bool {
        guard isPlausibleAppPath(path) else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return isOnBootVolume(URL(fileURLWithPath: path))
    }

    /// Picks a colour that reads as "this app" by bucketing the icon's saturated
    /// pixels and taking the most populous bucket. Transparent, near-black,
    /// near-white and grey pixels are discarded first, otherwise almost every
    /// icon resolves to the same washed-out grey.
    static func dominantColor(of icon: NSImage) -> NSColor {
        let fallback = NSColor(srgbRed: 0.58, green: 0.58, blue: 0.66, alpha: 1)
        let side = 32
        guard icon.size.width > 0, icon.size.height > 0 else { return fallback }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: side, pixelsHigh: side,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return fallback }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Freshly allocated bitmap memory is not zeroed, so clear it before
        // drawing or an image with no representations reads back as garbage.
        context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = rep.bitmapData else { return fallback }
        var buckets: [Int: (r: Int, g: Int, b: Int, count: Int)] = [:]
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2]), a = Int(pixels[index + 3])
            if a < 180 { continue }
            let high = max(r, max(g, b)), low = min(r, min(g, b))
            if high < 42 || low > 226 { continue }   // near-black, near-white
            if high - low < 26 { continue }          // grey
            let key = (r >> 5) << 10 | (g >> 5) << 5 | (b >> 5)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket.r += r; bucket.g += g; bucket.b += b; bucket.count += 1
            buckets[key] = bucket
        }
        // Tie-broken on the bucket key, which is what makes this deterministic.
        //
        // `Dictionary.values.max` returns the first maximal element in iteration order,
        // and Swift seeds hashing randomly per process — so two equally populous buckets
        // resolved differently on every launch. That is not theoretical: of 83 installed
        // apps with more than one bucket, 4 tie exactly, and Passwords.app alternated
        // between #FFD61F and #0C77F3 across repeated launches while Safari, which has no
        // tie, stayed identical. Which of two tied colours wins is arbitrary; that it is
        // the same one every time is not.
        let ranked = buckets.max { left, right in
            left.value.count != right.value.count
                ? left.value.count < right.value.count
                // Reversed, because `max` returns the last element in this ordering: the
                // lower key has to compare *greater* for it to win a tie.
                : left.key > right.key
        }
        guard let best = ranked?.value, best.count > 0 else {
            return fallback
        }

        var red = CGFloat(best.r) / CGFloat(best.count)
        var green = CGFloat(best.g) / CGFloat(best.count)
        var blue = CGFloat(best.b) / CGFloat(best.count)
        let mean = (red + green + blue) / 3
        red = min(255, mean + (red - mean) * 1.45)
        green = min(255, mean + (green - mean) * 1.45)
        blue = min(255, mean + (blue - mean) * 1.45)
        return NSColor(srgbRed: max(0, red) / 255, green: max(0, green) / 255,
                       blue: max(0, blue) / 255, alpha: 1)
    }
}

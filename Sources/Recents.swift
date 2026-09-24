import AppKit
import CoreServices

/// The recency queue behind the inner ring.
///
/// Recency is observed from the whole system, not just from launches through
/// Chakra, so the inner ring reflects what the user actually did. Every change
/// is written straight through to disk: the ring must come back after a reboot
/// with its history intact, which was an explicit requirement.
final class Recents {
    static let capacity = 40
    private static let key = DefaultsKey.recents

    /// Where seeding looks for installed apps.
    static var searchDirectories: [String] {
        ["/Applications",
         "/Applications/Utilities",
         "/System/Applications",
         "/System/Applications/Utilities",
         NSHomeDirectory() + "/Applications"]
    }

    private let defaults: UserDefaults
    private let selfPath: String
    /// Canonical paths, most recently used first.
    private(set) var queue: [String]
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults, selfPath: String) {
        self.defaults = defaults
        let canonicalSelf = RingItem.normalizePath(selfPath)
        self.selfPath = canonicalSelf
        let raw = defaults.object(forKey: Self.key)
        let stored = Self.decode(raw)
        queue = stored.filter { $0 != canonicalSelf }
        // Repairs — dropping Chakra itself, de-duplicating, trimming past the cap
        // — are written back. Otherwise `record`'s early return for an app that is
        // already at the head means a broken value could sit on disk for weeks.
        if (raw as? [String]) != queue { save() }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private static func decode(_ raw: Any?) -> [String] {
        guard let stored = raw as? [String] else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for path in stored {
            let normalized = RingItem.normalizePath(path)
            // Also drops anything an older build recorded before the filter in
            // `record` existed. The caller writes the result back, so a queue that
            // collected junk repairs itself on the next launch.
            guard RingItem.isPlausibleAppPath(normalized),
                  !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            out.append(normalized)
        }
        return Array(out.prefix(capacity))
    }

    /// Moves an app to the front of the queue.
    ///
    /// Filtered here rather than only where the inner ring is built, because the
    /// queue holds forty entries and anything junk in it pushes a real app out of
    /// history. The string-only test is deliberate: this runs on every app
    /// activation, and touching the filesystem each time would be wasteful.
    func record(_ path: String) {
        let normalized = RingItem.normalizePath(path)
        guard RingItem.isPlausibleAppPath(normalized), normalized != selfPath else { return }
        guard queue.first != normalized else { return }
        queue.removeAll { $0 == normalized }
        queue.insert(normalized, at: 0)
        if queue.count > Self.capacity { queue = Array(queue.prefix(Self.capacity)) }
        save()
    }

    /// The inner ring's contents.
    ///
    /// An app that is already pinned to the outer ring does not leave a gap
    /// here — the next eligible app is pulled up in its place, so the inner ring
    /// always shows `limit` *distinct* apps that appear nowhere else on the
    /// wheel. This was the user's explicit rule.
    func inner(excluding outer: [String], limit: Int,
               isEligible: (String) -> Bool = RingItem.isEligibleForRecents) -> [String] {
        guard limit > 0 else { return [] }
        var blocked = Set(outer.map { RingItem.normalizePath($0) })
        blocked.insert(selfPath)
        var out: [String] = []
        var seen = Set<String>()
        for path in queue {
            if out.count >= limit { break }
            guard !path.isEmpty, !blocked.contains(path), !seen.contains(path) else { continue }
            guard isEligible(path) else { continue }
            seen.insert(path)
            out.append(path)
        }
        return out
    }

    /// Fills the queue from Spotlight's own last-used timestamps. Existing
    /// history always wins: seeded entries are appended underneath it, so this is
    /// safe to call more than once.
    func seedFromSpotlight() {
        merge(Self.spotlightRanking(limit: Self.capacity))
    }

    /// Seeds only when there is no history at all, off the main thread.
    ///
    /// Reading a last-used date for every installed app is a few hundred
    /// synchronous metadata reads. That is fine when the user has just clicked a
    /// button, but not while the menu-bar item is still appearing, so at launch
    /// the ranking is computed on a background queue and merged back on the main
    /// one — `queue` is only ever touched from the main thread.
    func seedIfEmptyInBackground(completion: (() -> Void)? = nil) {
        guard queue.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ranking = Self.spotlightRanking(limit: Self.capacity)
            DispatchQueue.main.async {
                guard let self, self.queue.isEmpty else { return }
                self.merge(ranking)
                completion?()
            }
        }
    }

    /// Appends candidates underneath the existing history, which always wins.
    private func merge(_ ranking: [String]) {
        guard !ranking.isEmpty else { return }
        var merged = queue
        var seen = Set(merged)
        for candidate in ranking {
            if merged.count >= Self.capacity { break }
            let path = RingItem.normalizePath(candidate)
            guard !path.isEmpty, path != selfPath, !seen.contains(path) else { continue }
            seen.insert(path)
            merged.append(path)
        }
        guard merged != queue else { return }
        queue = merged
        save()
    }

    /// Installed apps ordered by when they were last used, newest first.
    ///
    /// Reads `kMDItemLastUsedDate` through the synchronous Metadata API rather
    /// than running an `NSMetadataQuery`, because seeding happens once during
    /// onboarding and a blocking read of a few hundred files is simpler than an
    /// asynchronous query with a completion handler.
    static func spotlightRanking(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var dated: [(path: String, used: Date)] = []
        let manager = FileManager.default
        var seen = Set<String>()
        for directory in searchDirectories {
            guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
            // Case-insensitive, to agree with `isPlausibleAppPath`. A bundle named
            // `Foo.APP` was otherwise accepted by `record` but skipped by seeding.
            for entry in entries where entry.lowercased().hasSuffix(".app") {
                let path = directory + "/" + entry
                guard !seen.contains(path), let used = lastUsedDate(path) else { continue }
                guard RingItem.isEligibleForRecents(path) else { continue }
                seen.insert(path)
                dated.append((path, used))
            }
        }
        dated.sort { $0.used > $1.used }
        return dated.prefix(limit).map(\.path)
    }

    private static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }

    /// Starts observing system-wide app activations. Uses a workspace
    /// notification, which needs no Accessibility permission, unlike a global
    /// event monitor.
    func startTracking() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  // Background agents and helpers are not things a user launches.
                  app.activationPolicy == .regular,
                  let url = app.bundleURL else { return }
            self.record(url.path)
        }
    }

    /// Test seam: lets a test install a queue that `record` would never produce,
    /// such as one containing duplicates or Chakra itself.
    func forceQueueForTesting(_ paths: [String]) {
        queue = paths.map { RingItem.normalizePath($0) }
    }

    private func save() {
        defaults.set(queue, forKey: Self.key)
    }
}

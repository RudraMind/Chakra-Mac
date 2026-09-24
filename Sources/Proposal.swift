import Foundation

/// Works out which apps to offer for the outer ring, and reads the Dock's own
/// list of pinned apps.
///
/// Deliberately free of AppKit and of any window, so the two things most likely
/// to be wrong — which candidates survive filtering, and how the Dock's
/// preference format is parsed — can be tested directly instead of through a
/// button.
enum RingProposal {
    /// Apps that are always present or always running, so a fixed slot spent on
    /// one is a slot wasted. The user can still add them by hand.
    static let uninteresting = ["Finder.app", "Launchpad.app", "Chakra.app"]

    /// Candidates for the empty slots, Dock order first, then recency.
    ///
    /// Apps already on the ring are excluded rather than offered again: `set`
    /// refuses to put one app in two slots, so proposing a pinned app would
    /// silently leave a slot empty. The result is capped at `freeSlots` for the
    /// same reason — every app shown must have somewhere to go.
    static func compute(dock: [String], spotlight: [String], pinned: [String],
                        selfPath: String, freeSlots: Int,
                        isEligible: (String) -> Bool = RingItem.isEligibleForRecents) -> [String] {
        guard freeSlots > 0 else { return [] }
        let canonicalSelf = RingItem.normalizePath(selfPath)
        var blocked = Set(pinned.map { RingItem.normalizePath($0) })
        blocked.remove("")
        blocked.insert(canonicalSelf)

        var out: [String] = []
        for candidate in dock + spotlight {
            if out.count >= freeSlots { break }
            let path = RingItem.normalizePath(candidate)
            guard !path.isEmpty, !blocked.contains(path),
                  !uninteresting.contains(where: { path.hasSuffix("/" + $0) }),
                  isEligible(path) else { continue }
            blocked.insert(path)
            out.append(path)
        }
        return out
    }

    /// The apps pinned to the user's Dock, in Dock order. Reading another app's
    /// preference domain works because Chakra is not sandboxed, and reading a
    /// preference is not something macOS asks permission for.
    static func dockApps() -> [String] {
        guard let dock = UserDefaults(suiteName: "com.apple.dock"),
              let tiles = dock.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return []
        }
        return parse(tiles: tiles)
    }

    /// Pulls paths out of the Dock's `persistent-apps` structure. Anything shaped
    /// unexpectedly is skipped: this is another app's private format, and it has
    /// changed before.
    static func parse(tiles: [[String: Any]]) -> [String] {
        var out: [String] = []
        for tile in tiles {
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let raw = file["_CFURLString"] as? String else { continue }
            // The value is either a file URL or a bare path, depending on the
            // sibling _CFURLStringType field.
            let path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? "") : raw
            // Case-insensitive, to agree with `RingItem.isPlausibleAppPath`.
            let lowered = path.lowercased()
            guard !path.isEmpty,
                  lowered.hasSuffix(".app") || lowered.hasSuffix(".app/") else { continue }
            out.append(path)
        }
        return out
    }
}

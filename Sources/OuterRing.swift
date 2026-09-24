import Foundation

/// The fixed slots the user owns.
///
/// Positions never compact. Removing the app in slot 3 leaves slot 3 empty rather
/// than sliding slots 4 onwards down, because the whole value of a fixed ring is
/// that a given direction always means the same app.
///
/// Storage is always `capacity` slots long, whatever the user has chosen to show.
/// Turning the ring down from eight slots to six therefore hides the last two
/// rather than erasing them, and turning it back up brings the same apps back.
final class OuterRing {
    /// How many slots are kept on disk: the most the user is allowed to ask for.
    static let capacity = Settings.maxOuterSlots
    /// Posted whenever the slots change, whichever window did it, so the others
    /// can catch up without every caller having to know who is open.
    static let didChangeNotification = Notification.Name("local.chakra.outerRingDidChange")
    private static let key = DefaultsKey.outerSlots

    private let defaults: UserDefaults
    private let settings: Settings
    /// Canonical paths, one per stored slot. An empty string means an empty slot.
    private(set) var slots: [String]
    /// Resolved items parallel to `slots`, cached so icons are not reloaded on
    /// every redraw.
    private(set) var items: [RingItem?]

    /// How many slots are on the wheel right now.
    var visibleCount: Int { settings.outerSlotCount }
    /// The indices the user can currently see and reach.
    var visibleRange: Range<Int> { 0..<min(visibleCount, slots.count) }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.settings = Settings(defaults: defaults)
        let stored = defaults.object(forKey: Self.key)
        slots = Self.decode(stored)
        items = Array(repeating: nil, count: Self.capacity)
        rebuildItems()
        // A repair that stays in memory would be redone on every launch, and the
        // broken value would outlive the app.
        if (stored as? [String]) != slots { save() }
    }

    /// Repairs whatever is actually on disk into exactly `capacity` valid, distinct
    /// slots. A short array is padded rather than discarded so a partial write —
    /// or a ring saved by a build with a smaller capacity — costs the user only the
    /// missing entries, not their whole ring.
    private static func decode(_ raw: Any?) -> [String] {
        let empty = Array(repeating: "", count: capacity)
        guard let stored = raw as? [String] else { return empty }
        var out: [String] = []
        var seen = Set<String>()
        for entry in stored.prefix(capacity) {
            let normalized = canonical(entry)
            // A duplicate becomes an empty slot rather than a second copy of one
            // app, which `set` would then refuse to move.
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                out.append("")
                continue
            }
            seen.insert(normalized)
            out.append(normalized)
        }
        while out.count < capacity { out.append("") }
        return out
    }

    /// The canonical form of a path a slot may hold, or "" if it may not hold it.
    ///
    /// The absolute-path test comes first, before normalisation: a slot must hold
    /// an absolute path to something other than the volume root, and
    /// `URL(fileURLWithPath:)` would resolve a relative one against the process's
    /// working directory — quietly inventing a path the user never chose, which
    /// would then look perfectly valid.
    private static func canonical(_ raw: String) -> String {
        guard raw.hasPrefix("/") else { return "" }
        let normalized = RingItem.normalizePath(raw)
        guard normalized.hasPrefix("/"), normalized.count > 1 else { return "" }
        return normalized
    }

    // "Full", "the next free slot" and "what is on the ring" are all about the
    // slots the user can actually see. A hidden slot is not somewhere a drop can go,
    // and an app parked in one is not on the wheel, so it must not be excluded from
    // the recents ring either.
    var isFull: Bool { visibleRange.allSatisfy { !slots[$0].isEmpty } }
    var firstEmpty: Int? { visibleRange.first(where: { slots[$0].isEmpty }) }
    var occupiedPaths: [String] { visibleRange.map { slots[$0] }.filter { !$0.isEmpty } }

    /// How many apps the wheel is showing right now.
    var occupiedCount: Int { occupiedPaths.count }

    /// Whether the app is anywhere in storage, hidden slots included.
    ///
    /// Deliberately wider than `occupiedPaths`: an app tucked away in a hidden slot
    /// must not be added a second time, or raising the slot count would reveal a
    /// duplicate.
    func contains(_ path: String) -> Bool {
        let normalized = Self.canonical(path)
        guard !normalized.isEmpty else { return false }
        return slots.contains(normalized)
    }

    func item(at index: Int) -> RingItem? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    /// Assigns a slot, replacing whatever was there. Refuses an app that already
    /// sits in a different slot — one app, one place on the ring.
    @discardableResult
    func set(_ path: String, at index: Int) -> Bool {
        guard index >= 0, index < Self.capacity else { return false }
        let normalized = Self.canonical(path)
        guard !normalized.isEmpty else { return false }
        if let existing = slots.firstIndex(of: normalized), existing != index { return false }
        slots[index] = normalized
        save()
        return true
    }

    /// Puts an app in a slot, swapping with whichever other slot already held it.
    ///
    /// `set` refuses a duplicate, which is right for a drop onto the wheel — the
    /// user aimed at a slot and should be told the app is already elsewhere. In
    /// the settings window the same gesture means "this app belongs here now", so
    /// moving it is the useful answer.
    @discardableResult
    func assign(_ path: String, at index: Int) -> Bool {
        guard index >= 0, index < Self.capacity else { return false }
        let normalized = Self.canonical(path)
        guard !normalized.isEmpty else { return false }
        // Swapped rather than cleared. Clearing the app's old slot loses an app
        // whenever the target slot was occupied, which both breaches the three-app
        // floor and silently discards the app the user was displacing. Putting the
        // displaced app into the vacated slot keeps the count and keeps it visible.
        // When the target slot was empty this assigns "" and so behaves exactly as
        // before; when the app is already in this slot, `firstIndex` finds `index`
        // itself and the swap is skipped.
        if let existing = slots.firstIndex(of: normalized), existing != index {
            slots[existing] = slots[index]
        }
        slots[index] = normalized
        save()
        return true
    }

    /// Fills the lowest empty slot. Returns the index used, or nil if the app is
    /// already on the ring or the ring is full.
    func addToFirstEmpty(_ path: String) -> Int? {
        let normalized = Self.canonical(path)
        guard !normalized.isEmpty, !contains(normalized), let index = firstEmpty else { return nil }
        return set(normalized, at: index) ? index : nil
    }

    /// Replaces the whole ring at once, in the order given. Used where the caller
    /// has a complete list — onboarding and the settings window — so no slot can
    /// keep an app the new list does not contain, and no entry can be silently
    /// refused for already being somewhere else.
    ///
    /// The floor deliberately does not apply here. This is "the ring is now exactly
    /// this list", not a deletion, and its callers — onboarding and the settings
    /// window — pass a list they have already decided on. The floor is enforced where
    /// those lists are built instead, in Task 11.
    func replaceAll(_ paths: [String]) {
        slots = Self.decode(paths)
        save()
    }

    /// Whether a slot may be emptied.
    ///
    /// See `Settings.minOuterApps`. A ring that is already below the floor refuses
    /// too: allowing "it is already below three, so one fewer does no harm" is how a
    /// ring reaches zero. `set` and `assign` are never refused by the floor, so a
    /// slot can always be corrected by replacing it.
    func canRemove(at index: Int) -> Bool {
        guard index >= 0, index < Self.capacity, !slots[index].isEmpty else { return false }
        // A hidden slot is not on the wheel, so emptying it takes nothing away from
        // the user and cannot breach the floor.
        guard visibleRange.contains(index) else { return true }
        return occupiedCount - 1 >= Settings.minOuterApps
    }

    /// Whether the visible slot count may be set to `count`.
    ///
    /// Lowering the count deletes nothing, but it hides the tail of the ring, so it
    /// can leave the user with fewer than three reachable apps just as surely as
    /// deleting them would.
    func canSetVisibleCount(to count: Int) -> Bool {
        let clamped = min(max(count, Settings.minOuterSlots), Settings.maxOuterSlots)
        guard clamped < visibleCount else { return true }
        let reachable = (0..<min(clamped, slots.count)).filter { !slots[$0].isEmpty }.count
        // The second test is what stops a ring that is already below the floor from
        // freezing the slider: hiding slots that hold nothing takes nothing away.
        return reachable >= Settings.minOuterApps || reachable >= occupiedCount
    }

    /// Empties a slot. Returns false when the floor refuses it, so the caller can
    /// say why rather than appearing to do nothing.
    @discardableResult
    func remove(at index: Int) -> Bool {
        guard canRemove(at: index) else { return false }
        slots[index] = ""
        save()
        return true
    }

    /// Re-resolves names and icons. Called when the wheel opens so a slot whose
    /// app was reinstalled stops showing as missing.
    func reload() { rebuildItems() }

    private func rebuildItems() {
        items = slots.map { $0.isEmpty ? nil : RingItem.make(path: $0) }
    }

    private func save() {
        defaults.set(slots, forKey: Self.key)
        rebuildItems()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

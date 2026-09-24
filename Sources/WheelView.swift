import AppKit

/// Identifies one slot on the wheel. A struct rather than a tuple so it can be
/// compared through an Optional, which tuples cannot.
struct SlotRef: Equatable {
    let ring: Ring
    let index: Int
}

/// Draws the wheel and turns mouse, keyboard and drag events into intents. It
/// owns no data: the controller hands it items and receives callbacks.
final class WheelView: NSView {
    /// The wheel's measurements with no rotation applied. Assigning `geometry`
    /// splits the value into this and the two rotations below.
    private var baseGeometry = RingGeometry()

    /// Where each ring has come to rest, in radians, and the extra offset that the
    /// opening sweep is currently adding.
    private var outerRotation: CGFloat = 0
    private var innerRotation: CGFloat = 0

    /// The geometry everything else works from: the resting measurements turned by
    /// the current rotation and any animation in flight.
    ///
    /// Computed rather than stored so drawing and hit-testing cannot end up using
    /// different rotations — the bug that would show up as the wheel launching the
    /// app that *used* to be under the pointer.
    var geometry: RingGeometry {
        get {
            baseGeometry.rotated(outer: outerRotation + sweepOffset(.outer),
                                 inner: innerRotation + sweepOffset(.inner))
        }
        set {
            baseGeometry = RingGeometry(scale: newValue.scale,
                                        outerSlotCount: newValue.outerSlotCount,
                                        innerSlotCount: newValue.innerSlotCount)
            outerRotation = newValue.outerRotation
            innerRotation = newValue.innerRotation
        }
    }

    var wheelCenter: CGPoint = .zero
    /// As long as the geometry's outer slot count; nil entries are empty slots.
    var outerItems: [RingItem?] = Array(repeating: nil,
                                       count: RingGeometry.defaultOuterSlotCount) {
        didSet { validateFocus() }
    }
    /// Zero to the geometry's inner slot count of items, in recency order.
    ///
    /// Refreshed while the wheel is open — pinning a recents app removes it from
    /// here — so the keyboard focus has to be re-checked against the new contents or
    /// it can point past the end and stop responding to Return.
    var innerItems: [RingItem] = [] {
        didSet { validateFocus() }
    }
    /// Paths of apps currently running, for the activity dots.
    var runningPaths: Set<String> = []
    var colorful = false
    /// A colour wash over the glass bands, or nil for the plain system material.
    var glassTint: NSColor?
    /// How solid the glass is, 0 to 1. The tint fades with it, so 0 really means
    /// no background at all — just the icons and the centre pill.
    var glassOpacity: CGFloat = 0.85

    var onLaunch: ((RingItem, Ring, Int) -> Void)?
    var onQuit: ((RingItem) -> Void)?
    var onRemoveOuter: ((Int) -> Void)?
    var canRemoveOuter: ((Int) -> Bool)?
    /// Promote a recents item into the outer ring. A nil index means the first
    /// empty slot.
    var onPromote: ((RingItem, Int?) -> Void)?
    /// A path dropped on an outer slot. The flag says the drag started on this
    /// wheel, which makes it a move rather than an addition.
    var onDropPath: ((String, Int, Bool) -> Void)?
    var onDismiss: (() -> Void)?
    /// The wheel is being dragged to a new place on screen: move the glass to
    /// follow it.
    var onMove: ((CGPoint) -> Void)?
    /// The drag finished — remember this position for next time.
    var onMoveEnded: ((CGPoint) -> Void)?

    private var hover: SlotRef?
    private var focus: SlotRef?
    private var dropTarget: SlotRef?
    private var message: String?
    private var messageToken = 0
    private var colorCache: [String: NSColor] = [:]
    private var dragOrigin: SlotRef?
    private var mouseDownAt: NSPoint?
    private var isDraggingOut = false
    /// Set when the press landed in the hole, which is the handle for moving the
    /// whole wheel. Holds the offset from the press to the centre, so the wheel
    /// does not jump under the pointer.
    private var moveGrabOffset: CGSize?
    private var isMoving = false
    /// What the press landed on, so the release can be checked against it.
    private var pressTarget: HitTarget?
    private var rightPressTarget: HitTarget?
    /// Whether the drag currently over the view carries a file at all, worked out
    /// once when it arrives instead of on every mouse-move.
    private var dragCarriesFile = false

    // MARK: Rotation state

    /// Whether scrolling turns a ring, and whether the wheel sweeps in when opened.
    var scrollToSpin = true
    var spinOnOpen = true

    /// A ring easing back onto the nearest slot after a scroll.
    private struct Snap {
        let from: CGFloat
        let to: CGFloat
        let started: Date
    }
    private var outerSnap: Snap?
    private var innerSnap: Snap?
    /// When the opening sweep began, or nil once it has finished.
    private var sweepStarted: Date?
    /// Drives both animations. One timer, started when something needs it and
    /// stopped the moment nothing does, so an idle wheel costs nothing.
    private var animationTimer: Timer?
    /// Snaps shortly after the last scroll event, so a continuous scroll is not
    /// fighting a snap all the way.
    private var snapWork: DispatchWorkItem?

    /// A ring never rests between two apps, so the rotation the user is left with is
    /// always a whole number of slots. Told to the controller to persist.
    var onRotationSettled: ((Ring, Int) -> Void)?

    static let sweepDuration: TimeInterval = 0.25
    static let snapDuration: TimeInterval = 0.26
    /// How far each ring is offset at the start of the opening sweep. The outer ring
    /// leads and the inner follows a little further behind, which reads as one object
    /// settling rather than two rings moving independently.
    static let outerSweep: CGFloat = 0.55
    static let innerSweep: CGFloat = 0.8

    /// What an empty outer slot invites, in the one place both the click and the
    /// keyboard paths can reach it.
    ///
    /// It does not mention dropping from Finder: to start such a drag the user has
    /// to click in Finder, which takes focus away and closes the wheel, so the only
    /// drags that can land here come from the wheel's own inner ring.
    static let emptyOuterSlotHint =
        "Empty — drag an app in from the inner ring, or drop one on the menu-bar icon"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("Chakra builds its views in code") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    /// The ring can open while another app is frontmost, and the click that
    /// launches an app must not be spent activating Chakra instead.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Contents

    private func item(_ ref: SlotRef) -> RingItem? {
        switch ref.ring {
        case .outer:
            guard ref.index >= 0, ref.index < outerItems.count else { return nil }
            return outerItems[ref.index]
        case .inner:
            guard ref.index >= 0, ref.index < innerItems.count else { return nil }
            return innerItems[ref.index]
        }
    }

    private var isEmptyWheel: Bool {
        outerItems.allSatisfy { $0 == nil } && innerItems.isEmpty
    }

    // MARK: - The shelf readout

    /// How many files the shelf holds, and their total size. Set by the controller from
    /// `Shelf.total()`, which is a live directory scan — measured 0.46 ms at ten items and
    /// 38.9 ms at a thousand — so it is read once per refresh, never per frame.
    var shelfCount = 0 { didSet { if shelfCount != oldValue { invalidate() } } }
    var shelfBytes: Int64 = 0 { didSet { if shelfBytes != oldValue { invalidate() } } }
    /// Clicking the folder opens it in Finder. Declared here; wiring is a separate change.
    var onOpenShelf: (() -> Void)?

    /// The real macOS folder icon, held once. `NSWorkspace.icon(for:)` is a lookup, not a
    /// decode, but `draw(_:)` runs at 60 Hz during an animation and this is per-frame work
    /// that never changes.
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    /// Whether the readout is the thing in the hole right now.
    ///
    /// **`focus` is deliberately absent from this condition**, and that absence is the whole
    /// correctness of the feature. `resetTransientState()` ends with
    /// `focus = firstOccupiedOuter()` and `WheelWindow.swift:124` calls it on *every* wheel
    /// open, so on any non-empty ring `focus` is never nil at rest. A readout that stood down
    /// for a non-nil focus could never have appeared in the shipped app at all — the hole would
    /// always show the first occupied app's name, which is exactly the behaviour this replaces.
    /// A `hover` is different: it means the pointer is deliberately over an icon, and naming
    /// that app is the more urgent thing to say.
    /// Every file on the drag currently over the view, read once when it arrives.
    ///
    /// The pasteboard is a cross-process read and `draggingUpdated` fires continuously, which is
    /// exactly why `dragCarriesFile` above is cached the same way.
    private var dragURLs: [URL] = []

    /// Why this drag would be refused, or nil if it fits. Asked once, on arrival.
    private var dragRefusal: String?

    /// Whether the pointer is over the hub right now, so the hole shows the forecast.
    private var dragOverHub = false

    /// Asked once when a file drag arrives: nil if the drop fits, otherwise why it does not.
    ///
    /// A closure because the answer belongs to the `Shelf`, which this view has no handle on.
    var shelfDropRefusal: (([URL]) -> String?)?

    /// Files released over the hub.
    var onShelfDrop: (([URL]) -> Void)?

    /// `dragOverHub` is included, so an **empty** shelf still answers a drag: the hole has to
    /// respond to the first file as much as to the eleventh, and `shelfCount` alone is 0 then.
    private var drawsShelfReadout: Bool { (shelfCount > 0 || dragOverHub) && hover == nil }

    /// Exposed for the smoke checks, which cannot reach a private property.
    var shelfReadoutDrawsForTesting: Bool { drawsShelfReadout }

    /// The rect the folder icon occupies, or `.zero` when no readout is drawn.
    ///
    /// One source of truth: the drawing, the cursor, the press and the drag all hit-test this,
    /// so a change to the layout moves every one of them together. `.zero` contains no point, so
    /// a caller needs no separate emptiness check.
    ///
    /// Sharing the *predicate* matters as much as sharing the rect. Two predicates would allow a
    /// visible folder that drags nothing, and a release on it would fall through to `.center` and
    /// dismiss the wheel instead of opening the shelf.
    var shelfFolderRect: NSRect {
        guard drawsShelfReadout else { return .zero }
        let side = 26 * geometry.scale
        return NSRect(x: wheelCenter.x - side / 2,
                      y: wheelCenter.y + 15 * geometry.scale - side / 2,
                      width: side, height: side)
    }

    /// The folder's *target*, which is deliberately larger than the folder that is drawn.
    ///
    /// At the 0.70 minimum wheel scale the drawn icon is 18.2 pt — a third of the area of the orb,
    /// already the smallest thing Chakra ships. The padding is a flat 8 pt rather than a scaled
    /// one, because a target being hard to hit is a fact about screen points and the pointer, not
    /// about how large the user has made the wheel: 34.2 pt at 0.70, 42.0 pt at 1.00.
    ///
    /// It is still a small share of the hole, so the hole remains the wheel's move handle: 4.2% of
    /// the hole's area at every scale, leaving 95.8% of it moving the wheel as before.
    var shelfFolderHitRect: NSRect {
        let drawn = shelfFolderRect
        guard drawn != .zero else { return .zero }
        return drawn.insetBy(dx: -8, dy: -8)
    }

    /// Set by a press inside `shelfFolderHitRect`, and the reason that press does **not** arm
    /// `moveGrabOffset`. The move gesture triggers at 3 pt and a drag-out at 6 pt, so a folder
    /// press that armed the move would always start moving the wheel before it could ever drag.
    private var isShelfPressed = false

    /// Whether the live drag session is the shelf's rather than a slot's.
    ///
    /// Cleared in `mouseDown`, never in `draggingSession(_:endedAt:)`, for exactly the reason
    /// `isDraggingOut` is: AppKit may swallow the mouse-up after a drag session, and `mouseUp`
    /// has to be able to tell that this gesture was a drag so it does not also open Finder.
    private var isDraggingShelf = false

    /// Every file on the shelf, read at the moment the drag starts.
    ///
    /// A closure rather than a stored array so the drag carries what is on disk *now*: the count
    /// in the hole is refreshed on a coalesced watcher, and a drag must not promise a file Finder
    /// has since moved. One live scan costs 0.46 ms at ten items.
    var shelfURLsForDrag: (() -> [URL])?

    /// Called the instant a shelf drag begins, so the controller can get the wheel out of the way.
    ///
    /// Not politeness — necessity. The wheel is a full-screen window at level 101, above every
    /// Finder window (0) and the desktop (−2147483603), and it registers `.fileURL` and returns
    /// `.copy` from `draggingUpdated` for *every* point on screen so that a bad drop can still be
    /// explained. While it is visible the pointer can never reach Finder: the wheel eats the drop
    /// everywhere. Hiding it dissolves the interception. Measured separately: a drag session
    /// survives both `orderOut` and `close()` of the window that started it, and still reports its
    /// own end, so hiding mid-gesture is safe.
    var onShelfDragBegan: (() -> Void)?

    /// Starts a drag carrying every file on the shelf.
    ///
    /// One `NSDraggingItem` per file, each with its own frame. Measured: 30 files drag as 30 files
    /// and cost 6 ms to build, but with a shared frame they all stack under a single icon and the
    /// user cannot tell how much they are carrying. The fan is capped at five steps so a hundred
    /// files do not smear across the hole.
    /// Takes the session start, for the smoke checks only. The same seam as
    /// `Shelf.sameVolumeOverride`, and for a sharper reason than convenience: measured, a real
    /// `beginDraggingSession` succeeds even on a windowless view — it returns a live session and
    /// does not crash — and a live session *tracks the mouse*, so starting one inside a 484-check
    /// UI suite risks hijacking every mouse check that runs after it. That is a worse trade than
    /// the coverage it would buy. The one line it stands in front of is therefore covered by
    /// running the real app, and by that probe, not by the suite.
    var beginShelfDragOverride: (([NSDraggingItem]) -> Void)?

    private func beginShelfDrag(with event: NSEvent) {
        let urls = shelfURLsForDrag?() ?? []
        // No files, no drag, and `isDraggingShelf` stays false — so the release falls through to
        // `onOpenShelf`, which is the better answer anyway: a folder you cannot drag is one you
        // can still open. Reachable whenever Finder empties the folder between the hole's last
        // refresh and the press.
        guard !urls.isEmpty else { return }
        isDraggingShelf = true
        let base = shelfFolderRect
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let step = CGFloat(min(index, 5)) * 4
            // The file's own icon, not the folder's: what is being carried is the files.
            item.setDraggingFrame(base.offsetBy(dx: step, dy: -step),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        if let beginShelfDragOverride {
            beginShelfDragOverride(items)
        } else {
            beginDraggingSession(with: items, event: event, source: self)
        }
        onShelfDragBegan?()
    }

    /// The folder and the count, drawn bare in the hole.
    ///
    /// **Not routed through `drawCenterPill`**, and that is measured rather than stylistic: the
    /// pill caps text at `pillMaxTextWidth`, which is 104.0 pt at scale 1, while
    /// "2 files / 6 MB total" measures 113.6 pt at 13 pt semibold — the pill would shrink or
    /// truncate it. The hole is `holeRadius * 2`, 144.0 pt at scale 1, so drawing bare in the
    /// hole fits the user's own wording with room to spare.
    ///
    /// The size is `ShelfMessage.bytes`, so it reads the way Finder writes sizes. Counts past
    /// ninety-nine read as `99+`: three digits plus the words do not fit the hole at the 0.70
    /// minimum wheel scale.
    /// One line of text in the hole, shrunk to fit it rather than truncated.
    ///
    /// Measured against the hole, not the pill: `pillMaxTextWidth` is 104.0 pt at scale 1 and the
    /// hole is 144.0 pt, and it is the hole this draws in. The margin keeps the glyphs off the
    /// glass where the hole's edge meets the inner band.
    private func drawHoleText(_ text: String, size: CGFloat, weight: NSFont.Weight,
                              colour: NSColor, offset: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes = { (font: NSFont) -> [NSAttributedString.Key: Any] in
            [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
        }
        // The chord at this line's height, not the hole's diameter. The hole is a circle, so a line
        // 30 pt below the centre has materially less room than one on the centre line: at scale 1
        // the diameter is 144 pt but that chord is only 131 pt. Measuring against the diameter made
        // the refusal's second line shrink to exactly the rim and touch it on both sides.
        //
        // `extreme` is the glyphs' furthest reach from the centre line, approximated rather than
        // measured because the measurement depends on the font size this is about to choose.
        let extreme = abs(offset) + 8 * geometry.scale
        // Clamped **before** the root, not after: a line further out than the hole's radius would
        // give a negative, and `squareRoot()` of that is NaN, which `max` does not repair — every
        // comparison against NaN is false, so the shrink below would silently never happen.
        let squared = max(geometry.holeRadius * geometry.holeRadius - extreme * extreme, 0)
        let room = squared.squareRoot() * 2 - 8 * geometry.scale
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        var attributed = NSAttributedString(string: text, attributes: attributes(font))
        let full = attributed.size().width
        if full > room, full > 0 {
            font = NSFont.systemFont(ofSize: size * (room / full), weight: weight)
            attributed = NSAttributedString(string: text, attributes: attributes(font))
        }
        let measured = attributed.size()
        attributed.draw(at: CGPoint(x: wheelCenter.x - measured.width / 2,
                                    y: wheelCenter.y + offset - measured.height / 2))
    }

    /// The rim of the hole, drawn only while a drag is over it.
    ///
    /// The peripheral half of the drag feedback, and the pair is deliberate rather than decorative:
    /// during a drag the eye is on the pointer, so the rim is what registers without being looked
    /// at, and the number below it is what registers when it is. Either one alone is worse.
    private func drawHoleRim(_ colour: NSColor) {
        let radius = geometry.holeRadius - 4 * geometry.scale
        let path = NSBezierPath(ovalIn: NSRect(x: wheelCenter.x - radius,
                                              y: wheelCenter.y - radius,
                                              width: radius * 2, height: radius * 2))
        path.lineWidth = 3 * geometry.scale
        colour.setStroke()
        path.stroke()
    }

    private func drawShelfReadout() {
        guard drawsShelfReadout else { return }
        let scale = geometry.scale

        // A drag over the hub owns the hole, because what is about to happen matters more than what
        // is already there. Two states, one shape: the rim and the folder are in the same place
        // either way, and only the colour and the words change.
        if dragOverHub {
            if let refusal = dragRefusal {
                drawHoleRim(.systemRed.withAlphaComponent(0.85))
                // Dimmed rather than hidden: the folder is still what the hole is, and removing it
                // would read as the hub having vanished rather than having declined.
                Self.folderIcon.draw(in: shelfFolderRect, from: .zero,
                                     operation: .sourceOver, fraction: 0.35)
                drawHoleText(ShelfMessage.dropRefused, size: 14 * scale, weight: .semibold,
                             colour: .systemRed, offset: -12 * scale)
                drawHoleText(refusal, size: 11 * scale, weight: .regular,
                             colour: NSColor.labelColor.withAlphaComponent(0.7),
                             offset: -30 * scale)
            } else {
                drawHoleRim(.controlAccentColor)
                // Grown, not swapped. macOS ships no open-folder icon, and drawing one would put a
                // second visual language inside a 144 pt circle.
                Self.folderIcon.draw(in: shelfFolderRect.insetBy(dx: -3 * scale, dy: -3 * scale),
                                     from: .zero, operation: .sourceOver, fraction: 1)
                drawHoleText(ShelfMessage.dropForecast(count: dragURLs.count),
                             size: 17 * scale, weight: .bold, colour: .controlAccentColor,
                             offset: -14 * scale)
            }
            return
        }

        Self.folderIcon.draw(in: shelfFolderRect, from: .zero, operation: .sourceOver,
                             fraction: 0.95)
        let shown = shelfCount > 99 ? "99+" : "\(shelfCount)"
        let noun = shelfCount == 1 ? "file" : "files"
        drawHoleText("\(shown) \(noun) / \(ShelfMessage.bytes(shelfBytes)) total",
                     size: 13 * scale, weight: .semibold, colour: .labelColor,
                     offset: -12 * scale)
    }

    /// Only the wheel needs repainting when the pointer moves, even though the
    /// view spans the whole screen to catch clicks anywhere.
    private var wheelRect: NSRect {
        let r = geometry.discRadius + geometry.grace + 4
        return NSRect(x: wheelCenter.x - r, y: wheelCenter.y - r, width: r * 2, height: r * 2)
    }

    private func invalidate() { setNeedsDisplay(wheelRect) }

    // MARK: - Rotation

    /// Ease-out cubic: fast at first, settling gently, which is what makes a
    /// mechanical-feeling wheel rather than a linear slide.
    private static func eased(_ t: TimeInterval) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - CGFloat(clamped), 3)
    }

    /// How much the opening sweep is currently adding to a ring's rotation.
    private func sweepOffset(_ ring: Ring) -> CGFloat {
        guard let sweepStarted else { return 0 }
        let elapsed = Date().timeIntervalSince(sweepStarted) / Self.sweepDuration
        guard elapsed < 1 else { return 0 }
        let remaining = 1 - Self.eased(elapsed)
        return (ring == .outer ? Self.outerSweep : Self.innerSweep) * remaining
    }

    /// Starts the opening sweep. Called when the wheel is shown.
    func beginSweep() {
        guard spinOnOpen else { sweepStarted = nil; return }
        sweepStarted = Date()
        startAnimating()
    }

    override func scrollWheel(with event: NSEvent) {
        guard scrollToSpin else { return }
        let point = convert(event.locationInWindow, from: nil)
        // A scroll aimed at the hole or the desktop turns the outer ring, which is
        // the one the user almost always means; only a scroll actually over the
        // inner ring turns that.
        var ring = Ring.outer
        if case .slot(let hit, _) = geometry.hit(point, center: wheelCenter) { ring = hit }
        guard slotCountForRotation(ring) > 1 else { return }

        // A trackpad sends many small precise deltas; a wheel sends a few large
        // line-based ones. One factor for both would make the trackpad useless or
        // the wheel unusable.
        let delta = event.scrollingDeltaY + event.scrollingDeltaX
        guard delta != 0, delta.isFinite else { return }
        let radians = delta * (event.hasPreciseScrollingDeltas ? 0.012 : 0.15)

        // A snap in flight is abandoned: the user is turning the ring again.
        switch ring {
        case .outer: outerSnap = nil; outerRotation += radians
        case .inner: innerSnap = nil; innerRotation += radians
        }

        scheduleSnap(ring, immediately: event.phase == .ended || event.momentumPhase == .ended)
        refreshHoverFromPointer()
        invalidate()
    }

    private func slotCountForRotation(_ ring: Ring) -> Int {
        switch ring {
        case .outer: return baseGeometry.outerSlotCount
        // Turning the recents ring means turning the apps that are actually in it,
        // not the empty places after them.
        case .inner: return innerItems.count
        }
    }

    private func scheduleSnap(_ ring: Ring, immediately: Bool) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.beginSnap(ring) }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.14),
                                      execute: work)
    }

    private func beginSnap(_ ring: Ring) {
        let count = slotCountForRotation(ring)
        guard count > 1 else { return }
        let stepSize = 2 * CGFloat.pi / CGFloat(count)
        let current = ring == .outer ? outerRotation : innerRotation
        let target = (current / stepSize).rounded() * stepSize
        // Persisted as whole slots, and reported even when the ring did not have to
        // move, because the user may have turned it an exact notch.
        onRotationSettled?(ring, Int((target / stepSize).rounded()))
        guard abs(target - current) > 0.0001 else {
            setRotation(ring, target)
            invalidate()
            return
        }
        let snap = Snap(from: current, to: target, started: Date())
        switch ring {
        case .outer: outerSnap = snap
        case .inner: innerSnap = snap
        }
        startAnimating()
    }

    private func setRotation(_ ring: Ring, _ value: CGFloat) {
        switch ring {
        case .outer: outerRotation = value
        case .inner: innerRotation = value
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        // 60Hz is enough for a quarter-second sweep and costs nothing, since the
        // timer only exists while something is moving.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.stepAnimations()
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func stepAnimations() {
        let now = Date()
        var busy = false

        if let started = sweepStarted {
            if now.timeIntervalSince(started) >= Self.sweepDuration {
                sweepStarted = nil
            } else {
                busy = true
            }
        }

        for ring in [Ring.outer, Ring.inner] {
            let snap = ring == .outer ? outerSnap : innerSnap
            guard let snap else { continue }
            let progress = now.timeIntervalSince(snap.started) / Self.snapDuration
            if progress >= 1 {
                setRotation(ring, snap.to)
                switch ring {
                case .outer: outerSnap = nil
                case .inner: innerSnap = nil
                }
            } else {
                setRotation(ring, snap.from + (snap.to - snap.from) * Self.eased(progress))
                busy = true
            }
        }

        if !busy { stopAnimating() }
        // The app under the pointer changes as the ring turns.
        refreshHoverFromPointer()
        invalidate()
    }

    /// Re-reads the pointer and updates the highlight, for when the wheel moved
    /// under a stationary pointer rather than the other way round.
    private func refreshHoverFromPointer() {
        guard let window, isMoving == false else { return }
        let inWindow = window.mouseLocationOutsideOfEventStream
        updateHover(at: convert(inWindow, from: nil))
    }

    /// Shows a transient note under the wheel.
    ///
    /// Invalidates the whole view rather than just the wheel: the note is drawn
    /// outside the ring, it moves depending on how much room there is, and it is
    /// rare enough that a full repaint costs nothing.
    func flashMessage(_ text: String) {
        message = text
        messageToken += 1
        let token = messageToken
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.message = nil
            self.needsDisplay = true
        }
    }

    func resetTransientState() {
        hover = nil
        dropTarget = nil
        message = nil
        isDraggingOut = false
        isDraggingShelf = false
        isShelfPressed = false
        dragOrigin = nil
        isMoving = false
        moveGrabOffset = nil
        mouseDownAt = nil
        pressTarget = nil
        rightPressTarget = nil
        dragCarriesFile = false
        dragURLs = []
        dragRefusal = nil
        dragOverHub = false
        // Dropped so an app updated in place stops showing its old highlight colour.
        //
        // `RingItem`'s own cache is validated against the file's modification date
        // precisely so a reinstalled app gets a fresh icon; this cache had no such check
        // and is keyed on path alone, so the icon refreshed while the halo did not. It
        // also lives as long as the `WheelController`, which is a `let` on the app
        // delegate and never replaced — so without this the stale colour survived until
        // Chakra was quit. Clearing on every open bounds the staleness to one session and
        // still spares the redraws within it, which is where the cache earns its keep.
        colorCache.removeAll(keepingCapacity: true)
        // A snap left in flight from the last time the wheel was open would resume
        // mid-animation the next time it appears.
        snapWork?.cancel()
        outerSnap = nil
        innerSnap = nil
        sweepStarted = nil
        stopAnimating()
        focus = firstOccupiedOuter()
    }

    deinit {
        animationTimer?.invalidate()
        snapWork?.cancel()
    }

    private func firstOccupiedOuter() -> SlotRef? {
        for (index, item) in outerItems.enumerated() where item != nil {
            return SlotRef(ring: .outer, index: index)
        }
        return innerItems.isEmpty ? nil : SlotRef(ring: .inner, index: 0)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // A window only receives clicks where it has drawn something: the
        // WindowServer hit-tests per-pixel alpha. Without this all but invisible
        // wash, a click meant to dismiss the ring would instead land in whatever
        // app is underneath, following a link or moving a caret on the way out.
        NSColor(white: 0, alpha: 0.001).setFill()
        dirtyRect.fill()

        if let glassTint, glassOpacity > 0.01 {
            // Drawn here rather than tinting the effect view, so the wash is cut
            // to exactly the same two bands the glass is masked to, and fades out
            // with the glass instead of outliving it.
            glassTint.withAlphaComponent(0.30 * glassOpacity).setFill()
            WheelController.glassPath(geometry: geometry, center: wheelCenter).fill()
        }

        for index in 0..<geometry.outerSlotCount {
            drawSlot(SlotRef(ring: .outer, index: index))
        }
        for index in innerItems.indices {
            drawSlot(SlotRef(ring: .inner, index: index))
        }
        // Before the pill, so the pill's translucent plate is never painted over the readout.
        // Only one of the two ever draws — `drawCenterPill` stands down when the readout is on.
        drawShelfReadout()
        drawCenterPill()
        drawToast()
    }

    private func drawSlot(_ ref: SlotRef) {
        let center = geometry.slotCenter(ring: ref.ring, index: ref.index, center: wheelCenter)
        let size = geometry.iconSize(ref.ring)
        let entry = item(ref)
        let highlighted = hover == ref || focus == ref || dropTarget == ref

        if let entry {
            let side = size * (highlighted ? RingGeometry.hoverGrowth : 1)
            // The plate is sized from the grown icon, not the resting one. Sizing it
            // from the resting size left the icon overflowing its own highlight, so
            // the growth barely read as growth.
            if highlighted { drawHighlightPlate(at: center, size: side, item: entry) }
            let rect = NSRect(x: center.x - side / 2, y: center.y - side / 2,
                              width: side, height: side)
            entry.icon.draw(in: rect, from: .zero, operation: .sourceOver,
                            fraction: entry.isMissing ? 0.4 : 1)
            if entry.isMissing { drawMissingBadge(at: center, size: size) }
            if runningPaths.contains(entry.path) { drawRunningDot(at: center, size: size) }
        } else if ref.ring == .outer {
            drawEmptySlot(at: center, size: size, highlighted: highlighted)
        }
    }

    private func drawHighlightPlate(at center: CGPoint, size: CGFloat, item: RingItem) {
        let inset = RingGeometry.baseHighlightInset * geometry.scale
        let rect = NSRect(x: center.x - size / 2 - inset, y: center.y - size / 2 - inset,
                          width: size + inset * 2, height: size + inset * 2)
        let tint = colorful ? color(for: item) : NSColor.controlAccentColor

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = tint.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 22 * geometry.scale
        glow.shadowOffset = .zero
        glow.set()

        // Corner radius proportional to the plate, so a grown plate does not read as
        // a square with a nick out of each corner.
        let corner = min(rect.width, rect.height) * 0.22
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        if colorful {
            tint.withAlphaComponent(0.34).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
        }
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(colorful ? 0.9 : 1).setStroke()
        path.lineWidth = 2 * geometry.scale
        path.stroke()
    }

    private func color(for item: RingItem) -> NSColor {
        if let cached = colorCache[item.path] { return cached }
        let extracted = RingItem.dominantColor(of: item.icon)
        colorCache[item.path] = extracted
        return extracted
    }

    private func drawEmptySlot(at center: CGPoint, size: CGFloat, highlighted: Bool) {
        let side = size * 0.82
        let rect = NSRect(x: center.x - side / 2, y: center.y - side / 2,
                          width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13 * geometry.scale,
                               yRadius: 13 * geometry.scale)
        path.lineWidth = 1.5 * geometry.scale
        path.setLineDash([4 * geometry.scale, 4 * geometry.scale], count: 2, phase: 0)
        if highlighted {
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
        }
        path.stroke()

        // A plus sign, so an empty ring explains what to do with itself.
        let arm = side * 0.26
        let plus = NSBezierPath()
        plus.move(to: CGPoint(x: center.x - arm, y: center.y))
        plus.line(to: CGPoint(x: center.x + arm, y: center.y))
        plus.move(to: CGPoint(x: center.x, y: center.y - arm))
        plus.line(to: CGPoint(x: center.x, y: center.y + arm))
        plus.lineWidth = 2 * geometry.scale
        plus.lineCapStyle = .round
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        plus.stroke()
    }

    private func drawMissingBadge(at center: CGPoint, size: CGFloat) {
        let inset = 4 * geometry.scale
        let rect = NSRect(x: center.x - size / 2 - inset, y: center.y - size / 2 - inset,
                          width: size + inset * 2, height: size + inset * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14 * geometry.scale,
                               yRadius: 14 * geometry.scale)
        path.lineWidth = 1.5 * geometry.scale
        path.setLineDash([3 * geometry.scale, 3 * geometry.scale], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.75).setStroke()
        path.stroke()
    }

    private func drawRunningDot(at center: CGPoint, size: CGFloat) {
        let radius = 2.5 * geometry.scale
        let y = center.y - size / 2 - 7 * geometry.scale
        let rect = NSRect(x: center.x - radius, y: y - radius,
                          width: radius * 2, height: radius * 2)
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawCenterPill() {
        let text: String
        let missing: Bool
        // The precedence is explicit rather than `hover ?? focus`, because a third thing now wants
        // the hole. Highest first:
        //
        // 1. A *hovered* slot. The pointer is deliberately over an icon, so naming it is the most
        //    urgent thing to say.
        // 2. A non-empty shelf. The readout owns the hole and this draws nothing — including its
        //    translucent plate, which would otherwise sit on top of the folder icon.
        // 3. A *focused* slot, exactly as before. `focus` is set on every open by
        //    `resetTransientState()`, so it is the resting state on any non-empty ring.
        // 4. An empty wheel's invitation, exactly as before. Kept deliberately: a new user with no
        //    pinned apps must still be told to drop apps, and an empty shelf draws nothing that
        //    would say so.
        if let hovered = hover, let entry = item(hovered) {
            text = entry.name
            missing = entry.isMissing
        } else if drawsShelfReadout {
            // `drawsShelfReadout`, not `shelfCount > 0`: on an empty shelf a drag over the hub owns
            // the hole too, and the pill's translucent plate would otherwise sit on top of the
            // forecast.
            return
        } else if let focused = focus, let entry = item(focused) {
            text = entry.name
            missing = entry.isMissing
        } else if isEmptyWheel {
            text = "Drop apps here"
            missing = false
        } else {
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let color = missing ? NSColor.systemRed : NSColor.labelColor
        let attributes = { (font: NSFont) -> [NSAttributedString.Key: Any] in
            [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        }

        // The pill can only be as wide as the hole, which is about fifteen
        // characters. A long app name is shrunk to fit rather than cut off, down
        // to the point where a smaller size would be harder to read than an
        // ellipsis — below that the paragraph style truncates.
        let base = 13 * geometry.scale
        var font = NSFont.systemFont(ofSize: base, weight: .semibold)
        var attributed = NSAttributedString(string: text, attributes: attributes(font))
        let full = attributed.size().width
        if full > geometry.pillMaxTextWidth, full > 0 {
            let ratio = max(geometry.pillMaxTextWidth / full, 0.78)
            font = NSFont.systemFont(ofSize: base * ratio, weight: .semibold)
            attributed = NSAttributedString(string: text, attributes: attributes(font))
        }

        // The pill's widest form is sized so its corners stay inside the hole;
        // the measurements live in RingGeometry so the test that proves it can
        // read the same numbers this drawing uses.
        let textWidth = min(attributed.size().width, geometry.pillMaxTextWidth)
        let pillWidth = textWidth + geometry.pillTextInset * 2
        let pillHeight = geometry.pillHeight
        let pill = NSRect(x: wheelCenter.x - pillWidth / 2, y: wheelCenter.y - pillHeight / 2,
                          width: pillWidth, height: pillHeight)

        let path = NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textRect = NSRect(x: pill.minX + geometry.pillTextInset,
                              y: wheelCenter.y - attributed.size().height / 2,
                              width: textWidth, height: attributed.size().height)
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin])
    }

    /// A transient note, drawn under the wheel.
    ///
    /// Not in the centre pill: that has to stay inside the hole, which leaves room
    /// for roughly fifteen characters — enough for an app's name, and not enough
    /// for a sentence like "Ring is full — drag onto a slot instead", which used to
    /// arrive as "Ring is full — d…".
    private func drawToast() {
        guard let message else { return }
        let font = NSFont.systemFont(ofSize: 12.5 * geometry.scale, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: message, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])

        let edge = 8 * geometry.scale
        let inset = 14 * geometry.scale
        let height = 26 * geometry.scale
        let gap = 16 * geometry.scale
        // Wide enough for the message, but never wider than the screen it sits on.
        let room = max(bounds.width - 2 * edge - 2 * inset, 40)
        let textWidth = min(attributed.size().width, min(360 * geometry.scale, room))
        let width = textWidth + inset * 2

        var origin = CGPoint(x: wheelCenter.x - width / 2,
                             y: wheelCenter.y - geometry.outerBandOuter - gap - height)
        // Below the wheel, unless the wheel is sitting near the bottom of the
        // screen, in which case above it.
        if origin.y < edge {
            origin.y = wheelCenter.y + geometry.outerBandOuter + gap
        }
        origin.x = min(max(origin.x, edge), max(bounds.width - width - edge, edge))
        origin.y = min(max(origin.y, edge), max(bounds.height - height - edge, edge))
        let rect = NSRect(origin: origin, size: CGSize(width: width, height: height))

        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        // The note sits over the desktop with no glass behind it, so it brings its
        // own backing. The window colours follow light and dark mode themselves.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10 * geometry.scale
        shadow.shadowOffset = NSSize(width: 0, height: -2 * geometry.scale)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let textRect = NSRect(x: rect.minX + inset,
                              y: rect.midY - attributed.size().height / 2,
                              width: textWidth, height: attributed.size().height)
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin])
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; invalidate() }
        NSCursor.arrow.set()
    }

    /// An open hand over the hole is the only hint that the wheel can be dragged,
    /// so it is worth setting on every move rather than relying on a cursor rect.
    private func updateCursor(at point: NSPoint) {
        if isMoving {
            NSCursor.closedHand.set()
        } else if shelfFolderHitRect.contains(point) {
            // The folder's only affordance. Nothing about a 26 pt icon says "drag me", and the
            // open hand the rest of the hole shows would actively mislead — that one means "this
            // moves the wheel", which this 4.2% of the hole is the one part that does not.
            NSCursor.pointingHand.set()
        } else if case .center = geometry.hit(point, center: wheelCenter) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func updateHover(at point: NSPoint) {
        let target: SlotRef?
        if case .slot(let ring, let index) = geometry.hit(point, center: wheelCenter) {
            let ref = SlotRef(ring: ring, index: index)
            // Only report a slot that actually holds something, or an empty
            // outer slot, which is a real drop target.
            target = (item(ref) != nil || ring == .outer) ? ref : nil
        } else {
            target = nil
        }
        guard target != hover else { return }
        hover = target
        if target != nil { focus = target }
        invalidate()
    }

    // MARK: - Mouse

    /// Whether a press and a release belong to the same click.
    ///
    /// Without this, `mouseUp` acted on wherever the button came up: a click that
    /// began on the desktop and slid twenty points inward launched an app, and one
    /// that began on an icon and slid into the hole closed the wheel. Both are
    /// ordinary trackpad wobble, and neither is what the user asked for. The hole
    /// and the surrounding desktop count as one region, since both mean "dismiss".
    private static func isSameTarget(_ press: HitTarget, _ release: HitTarget) -> Bool {
        switch (press, release) {
        case let (.slot(pressRing, pressIndex), .slot(releaseRing, releaseIndex)):
            return pressRing == releaseRing && pressIndex == releaseIndex
        case (.slot, _), (_, .slot):
            return false
        default:
            return true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownAt = point
        // Cleared here rather than when a drag session ends: the guard it feeds
        // lives in mouseUp, and clearing it in the drag callback only works while
        // AppKit happens to swallow the mouse-up.
        isDraggingOut = false
        isDraggingShelf = false
        isShelfPressed = false
        isMoving = false
        moveGrabOffset = nil
        // A left press supersedes any right-button bookkeeping left over from an earlier
        // gesture, so a stale target cannot be matched against this one's release.
        rightPressTarget = nil
        let target = geometry.hit(point, center: wheelCenter)
        pressTarget = target
        // The folder is the shelf's handle; the rest of the hole is still the wheel's. Taken
        // before the switch below and returning early, so `moveGrabOffset` is deliberately left
        // nil — see `isShelfPressed`. `pressTarget` is still recorded, so `mouseUp`'s
        // abandoned-click guard works here exactly as it does everywhere else.
        if shelfFolderHitRect.contains(point) {
            dragOrigin = nil
            isShelfPressed = true
            return
        }
        switch target {
        case .slot(let ring, let index):
            let ref = SlotRef(ring: ring, index: index)
            dragOrigin = item(ref) != nil ? ref : nil
        case .center:
            // The hole is the wheel's handle. Remember the grab offset so the
            // wheel does not jump to sit under the pointer.
            dragOrigin = nil
            moveGrabOffset = CGSize(width: wheelCenter.x - point.x,
                                    height: wheelCenter.y - point.y)
        case .outside:
            dragOrigin = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let offset = moveGrabOffset, let start = mouseDownAt {
            // A small threshold, so a click in the hole still dismisses rather
            // than nudging the wheel a point sideways.
            guard isMoving || hypot(location.x - start.x, location.y - start.y) > 3 else { return }
            isMoving = true
            NSCursor.closedHand.set()
            move(to: CGPoint(x: location.x + offset.width, y: location.y + offset.height))
            return
        }

        // The same 6 pt the slot drag uses, so the two handles feel alike, and well clear of the
        // 3 pt that moves the wheel — a folder press never arms that, so the two cannot race.
        if isShelfPressed, !isDraggingShelf, let start = mouseDownAt {
            guard hypot(location.x - start.x, location.y - start.y) > 6 else { return }
            beginShelfDrag(with: event)
            return
        }

        guard !isDraggingOut, let origin = dragOrigin, let start = mouseDownAt,
              let entry = item(origin), !entry.isMissing else { return }
        let point = location
        guard hypot(point.x - start.x, point.y - start.y) > 6 else { return }

        isDraggingOut = true
        let size = geometry.iconSize(origin.ring)
        let center = geometry.slotCenter(ring: origin.ring, index: origin.index,
                                         center: wheelCenter)
        let frame = NSRect(x: center.x - size / 2, y: center.y - size / 2,
                           width: size, height: size)
        let draggingItem = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
        draggingItem.setDraggingFrame(frame, contents: entry.icon)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// Repositions the wheel within the screen, keeping all of it visible.
    private func move(to proposed: CGPoint) {
        let clamped = geometry.clampCenter(proposed, in: bounds.size)
        guard clamped != wheelCenter else { return }
        // A live note is drawn outside the wheel's own footprint, so its old pixels
        // would be left behind by a footprint-sized repaint. Rare enough that
        // repainting everything is the honest answer.
        guard message == nil else {
            wheelCenter = clamped
            needsDisplay = true
            onMove?(clamped)
            return
        }
        // Both the old and the new footprint need repainting, and the wheel can
        // move further than one footprint in a single event.
        let previous = wheelRect
        wheelCenter = clamped
        setNeedsDisplay(previous.union(wheelRect))
        onMove?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil; mouseDownAt = nil; moveGrabOffset = nil; pressTarget = nil
            isShelfPressed = false
        }
        // A drag that turned into a promotion must not also launch the app.
        if isDraggingOut { isDraggingOut = false; return }
        // Nor may a drag that carried the shelf away also open Finder. Checked before the branch
        // below, because both flags are set on such a gesture and only this one is true of it.
        if isDraggingShelf { return }
        // A press and release on the folder with no drag in between is a click on it. Without this
        // it would fall through to `release == .center` and *dismiss the wheel*, which is the one
        // outcome a user clicking a folder would not expect.
        if isShelfPressed {
            onOpenShelf?()
            return
        }
        // Nor may a drag that moved the wheel dismiss it: the release almost
        // never lands back inside the hole it started in.
        if isMoving {
            isMoving = false
            // The controller decides what to say: whether this position is the one
            // the wheel will open at depends on a setting it owns.
            onMoveEnded?(wheelCenter)
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let release = geometry.hit(point, center: wheelCenter)
        // A click that started somewhere else is an abandoned click, and doing
        // nothing is what the user expects from it.
        guard let press = pressTarget, Self.isSameTarget(press, release) else { return }

        switch release {
        case .center, .outside:
            onDismiss?()
        case .slot(let ring, let index):
            let ref = SlotRef(ring: ring, index: index)
            guard let entry = item(ref) else {
                if ring == .outer { flashMessage(Self.emptyOuterSlotHint) }
                return
            }
            if entry.isMissing {
                let canRemove = ring == .outer ? (canRemoveOuter?(index) ?? true) : true
                flashMessage(canRemove
                    ? "\(entry.name) is missing — right-click to remove"
                    // Not "right-click to replace": right-clicking removes, and at the
                    // floor that removal is refused. Replacing a slot happens in
                    // Settings, so that is where the message has to point.
                    : "\(entry.name) is missing — replace it in Settings")
                return
            }
            if event.modifierFlags.contains(.option) {
                onQuit?(entry)
            } else {
                onLaunch?(entry, ring, index)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // A right-press while the left button already owns a gesture is not a gesture of
        // its own, and arming here was a real defect. Sequence: press in the hole, drag
        // the wheel, then right-click without releasing. `rightMouseUp` saw press and
        // release both as `.center`, took the `default` branch of `isSameTarget`, and
        // dismissed the wheel mid-drag. `hide()` does not call `resetTransientState()`,
        // so `isMoving` stayed true — and the eventual left mouse-up still reported a
        // finished move, which wrote `savedCenterFraction`, silently switched
        // `openLocation` to `.saved`, and flashed "Chakra will open here" on a window the
        // user could no longer see. Aborting a drag must not rewrite a preference.
        // Keyed on `moveGrabOffset` and `isMoving` only, deliberately **not** on
        // `isDraggingOut`. That flag is documented as outliving its own gesture — mouseUp
        // reads it and mouseDown clears it, precisely because AppKit may swallow the
        // mouse-up after a drag session — so using it as a "the left button is down" proxy
        // would leave a stale true behind and make the *next* right-click silently do
        // nothing. `moveGrabOffset` is set only by a press in the hole and cleared in both
        // `mouseDown` and `mouseUp`'s defer, so it is a reliable signal, and either it or
        // `isMoving` is enough to catch the case this guard exists for.
        //
        // `isShelfPressed` is listed for the same reason and had to be added with the folder
        // handle: that press deliberately leaves `moveGrabOffset` nil, so on its own this guard
        // would have gone back to letting a right-click land mid-gesture and reopened exactly the
        // defect described above. It is cleared in `mouseDown` and in `mouseUp`'s defer, so like
        // `moveGrabOffset` it cannot go stale. `isDraggingShelf` is *not* listed, for the same
        // reason `isDraggingOut` is not: it outlives its own gesture on purpose.
        guard !isMoving, moveGrabOffset == nil, !isShelfPressed else { return }
        // The right button otherwise needs the same press bookkeeping as the left, or a
        // right-press on a slot released over the desktop would dismiss the wheel.
        rightPressTarget = geometry.hit(convert(event.locationInWindow, from: nil),
                                       center: wheelCenter)
    }

    override func rightMouseUp(with event: NSEvent) {
        defer { rightPressTarget = nil }
        let point = convert(event.locationInWindow, from: nil)
        let release = geometry.hit(point, center: wheelCenter)
        guard let press = rightPressTarget, Self.isSameTarget(press, release) else { return }

        guard case .slot(let ring, let index) = release else {
            onDismiss?()
            return
        }
        let ref = SlotRef(ring: ring, index: index)
        switch ring {
        case .outer:
            guard item(ref) != nil else { return }
            onRemoveOuter?(index)
        case .inner:
            guard let entry = item(ref) else { return }
            onPromote?(entry, nil)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                   // escape
            onDismiss?()
        case 123:                                  // left arrow
            step(-1)
        case 124:                                  // right arrow
            step(1)
        case 126:                                  // up arrow
            switchRing(to: .outer)
        case 125:                                  // down arrow
            switchRing(to: .inner)
        case 48:                                   // tab
            switchRing(to: focus?.ring == .outer ? .inner : .outer)
        case 36, 76:                               // return, keypad enter
            activateFocus(quit: event.modifierFlags.contains(.option))
        default:
            // A digit only counts on its own. ⌥1 used to launch slot 1 even though
            // ⌥ means "quit" everywhere else on the wheel.
            let bareDigit = event.modifierFlags
                .intersection([.command, .option, .control, .shift]).isEmpty
            if bareDigit, let characters = event.charactersIgnoringModifiers,
               let digit = Int(characters), digit >= 1,
               digit <= geometry.outerSlotCount {
                launch(SlotRef(ring: .outer, index: digit - 1), quit: false)
            }
            // Everything else is swallowed. The main menu has already had its turn:
            // key equivalents are dispatched before `keyDown` is delivered, so
            // handing an unclaimed one to `super` only reached `noResponder(for:)`
            // and set off the system beep it was meant to avoid.
        }
    }

    /// Launches, quits or explains one slot. Shared so the keyboard cannot drift
    /// from the mouse: the digit keys used to skip the missing-app check that both
    /// clicking and Return performed, and reported the wrong reason for the failure.
    private func launch(_ ref: SlotRef, quit: Bool) {
        guard let entry = item(ref) else {
            switch ref.ring {
            case .outer: flashMessage(Self.emptyOuterSlotHint)
            case .inner: break
            }
            return
        }
        if entry.isMissing {
            let canRemove = ref.ring == .outer ? (canRemoveOuter?(ref.index) ?? true) : true
            flashMessage(canRemove
                ? "\(entry.name) is missing — right-click to remove"
                // Same wording as the click path above, and for the same reason:
                // right-clicking removes, and at the floor that removal is refused, so
                // pointing the user at right-click would be pointing them at nothing.
                : "\(entry.name) is missing — replace it in Settings")
            return
        }
        if quit { onQuit?(entry) } else { onLaunch?(entry, ref.ring, ref.index) }
    }

    /// Moves the keyboard focus, skipping outer slots that hold nothing.
    ///
    /// An empty slot is not a place worth stopping: the focus ring would sit on it,
    /// the centre pill would go blank, and Return would do nothing. Stepping past it
    /// is what the user means by "next app".
    private func step(_ delta: Int) {
        guard let current = focus ?? firstOccupiedOuter() else { return }
        let count = current.ring == .outer
            ? geometry.outerSlotCount
            : max(innerItems.count, 1)

        var next = current.index
        // At most `count` hops, so a ring with nothing in it terminates rather than
        // circling forever.
        for _ in 0..<count {
            next = ((next + delta) % count + count) % count
            let candidate = SlotRef(ring: current.ring, index: next)
            if item(candidate) != nil {
                focus = candidate
                hover = nil
                invalidate()
                return
            }
        }
        // Nothing occupied anywhere on this ring: leave the focus where it was.
    }

    private func switchRing(to ring: Ring) {
        if ring == .inner, innerItems.isEmpty { return }
        let current = focus ?? SlotRef(ring: .outer, index: 0)
        guard current.ring != ring else { return }
        // Keep roughly the same direction when crossing between rings.
        let fromCount = current.ring == .outer
            ? geometry.outerSlotCount : max(innerItems.count, 1)
        let toCount = ring == .outer ? geometry.outerSlotCount : max(innerItems.count, 1)
        let fraction = CGFloat(current.index) / CGFloat(fromCount)
        let index = Int((fraction * CGFloat(toCount)).rounded()) % toCount
        focus = SlotRef(ring: ring, index: index)
        hover = nil
        invalidate()
    }

    private func activateFocus(quit: Bool) {
        guard let current = focus else { return }
        launch(current, quit: quit)
    }

    /// Keeps the keyboard focus on a slot that still exists and still holds
    /// something, after the wheel's contents have been replaced underneath it.
    private func validateFocus() {
        guard let current = focus else { return }
        if item(current) != nil { return }
        focus = firstOccupiedOuter() ?? (innerItems.isEmpty
            ? nil
            : SlotRef(ring: .inner, index: 0))
    }

    // MARK: - Drag destination

    private func outerSlot(under info: NSDraggingInfo) -> Int? {
        let point = convert(info.draggingLocation, from: nil)
        guard case .slot(.outer, let index) = geometry.hit(point, center: wheelCenter) else {
            return nil
        }
        return index
    }

    private func droppedPath(from info: NSDraggingInfo) -> String? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: options) as? [URL],
              let first = urls.first else { return nil }
        return first.path
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Read once per drag session rather than on every mouse-move: reading the
        // pasteboard is a cross-process call, and `draggingUpdated` fires
        // continuously for as long as the drag lasts.
        dragCarriesFile = droppedPath(from: sender) != nil
        // Every URL, not just the first: the hub takes the whole drop, and the count it forecasts
        // has to be the number that will really land. `droppedPath` reads only the first, which is
        // right for a slot — one slot holds one app — and wrong here.
        dragURLs = ShelfIntake.fileURLs(from: sender.draggingPasteboard)
        // Asked once, on arrival, for the same reason the pasteboard is read once. The cap check
        // walks the drop with an early bail, so this is the only place that can afford it.
        dragRefusal = dragURLs.isEmpty ? nil : shelfDropRefusal?(dragURLs)
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragCarriesFile else { return [] }
        // The hub, before the slot lookup. `geometry.hit` answers `.slot` for every point out to the
        // rim, so the hole has to be claimed first or the drop would be read as a ring drop.
        let point = convert(sender.draggingLocation, from: nil)
        if case .center = geometry.hit(point, center: wheelCenter), !dragURLs.isEmpty {
            if dropTarget != nil { dropTarget = nil; invalidate() }
            if !dragOverHub { dragOverHub = true; invalidate() }
            return .copy
        }
        if dragOverHub { dragOverHub = false; invalidate() }
        guard let index = outerSlot(under: sender) else {
            if dropTarget != nil { dropTarget = nil; invalidate() }
            // Still accepted, even though no slot is highlighted, so that releasing
            // over the hole or the gap between the rings gets an explanation.
            // Returning nothing here meant AppKit never called
            // `performDragOperation`, and the drop was silently swallowed.
            return .copy
        }
        let ref = SlotRef(ring: .outer, index: index)
        if dropTarget != ref { dropTarget = ref; invalidate() }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragCarriesFile = false
        clearDragForecast()
        if dropTarget != nil { dropTarget = nil; invalidate() }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragCarriesFile = false
        clearDragForecast()
    }

    /// Forgets everything read from a drag that has gone away.
    ///
    /// Cleared in three places because AppKit uses three: `draggingExited` when the pointer leaves,
    /// `draggingEnded` when the session finishes, and `performDragOperation` on release. A forecast
    /// left behind would keep the rim lit on a wheel with no drag over it.
    private func clearDragForecast() {
        dragURLs = []
        dragRefusal = nil
        if dragOverHub { dragOverHub = false; invalidate() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropTarget = nil; invalidate() }
        defer { dragCarriesFile = false; clearDragForecast() }
        // The hub first, matching `draggingUpdated`. Read from the pasteboard rather than from
        // `dragURLs`, so a release is never served by a stale read.
        let hubPoint = convert(sender.draggingLocation, from: nil)
        if case .center = geometry.hit(hubPoint, center: wheelCenter) {
            let urls = ShelfIntake.fileURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else {
                flashMessage(ShelfMessage.nothingDroppable)
                return false
            }
            onShelfDrop?(urls)
            return true
        }
        guard let path = droppedPath(from: sender) else { return false }
        guard let index = outerSlot(under: sender) else {
            // Counted from the geometry rather than spelled out. The ring holds anywhere
            // from four to ten slots, and this string used to say "eight" whatever the
            // user had chosen — the same small lie the settings window already fixed.
            flashMessage("Drop onto one of the \(geometry.outerSlotCount) outer slots")
            return false
        }
        let isInternal = (sender.draggingSource as? WheelView) === self
        onDropPath?(path, index, isInternal)
        return true
    }
}

extension WheelView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // A shelf item leaving the app is the *point* — it is how a file gets off the shelf — so
        // this is the one drag allowed out. `.copy` only, and never `.move`: a move would hand the
        // destination the right to delete the shelf's own copy, which is an auto-delete with no
        // undo and a direct breach of the never-auto-delete invariant.
        if isDraggingShelf { return .copy }
        // Dragging an icon out of the ring is how an app is promoted onto the
        // outer ring. Allowing the same drag to leave the app would hand Finder a
        // real file URL and have it copy the whole bundle.
        return context == .withinApplication ? .copy : []
    }

    /// Refuses to let a held modifier key rewrite the operation, for shelf drags only.
    ///
    /// Returning `.copy` above is **not** sufficient on its own. Apple's current documentation
    /// states the system combines the source's mask with the operation implied by the modifier
    /// keys, and maps ⌘ to `.move` — so a user holding ⌘ on the way to Finder could hand it a move
    /// and lose the shelf's copy. This is documented rather than measured here, and it is
    /// implemented anyway: one line against a data loss with no undo is not a trade worth thinking
    /// about.
    ///
    /// Measured: without this, the mask is re-queried on *every* mouse move during the drag; with
    /// it returning true, the opt-out is consulted in that same slot and the mask is not
    /// re-queried. So it has to be in place before the session starts, not set later.
    ///
    /// Scoped to shelf drags so a slot drag behaves exactly as it shipped. A slot drag cannot
    /// leave the app at all, which is its own protection.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        isDraggingShelf
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // `isDraggingOut` is deliberately left alone: mouseUp reads it to know
        // this gesture was a drag, and mouseDown is what clears it.
        dragOrigin = nil
    }
}

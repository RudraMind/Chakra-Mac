import AppKit

/// Draws the orb: the user's outer-ring apps as coloured dots on a dark disc.
///
/// The colour comes from the user's own apps rather than a chosen palette, so the
/// orb is a miniature of their ring and no two people's orbs look alike. Eight
/// dots is also the menu-bar glyph, which is what makes the two read as the same
/// object.
final class OrbView: NSView {
    var geometry = OrbGeometry(size: OrbGeometry.defaultSize) {
        didSet { if geometry != oldValue { needsDisplay = true } }
    }

    /// One entry per outer slot, in ring order. A nil entry is an empty slot.
    var dotColors: [NSColor?] = [] {
        didSet { needsDisplay = true }
    }

    /// The outer ring's rotation, so the orb and a turned wheel agree about which
    /// app is at the top.
    var rotation: CGFloat = 0 {
        didSet { if rotation != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    /// The orb can be clicked while another application is frontmost. Without
    /// this the first click is spent ordering the window and never reaches the
    /// view, so the orb would need two clicks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel is square; the orb is not. Returning nil outside the disc stops
    /// the corners swallowing clicks aimed at whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return geometry.contains(local) ? self : nil
    }

    var onClick: (() -> Void)?
    /// Passes both the event and the view, so the menu can be positioned at the orb
    /// rather than at the status item.
    var onRightClick: ((NSEvent, NSView) -> Void)?
    var onDropPaths: (([String]) -> Void)?
    /// Every file URL dropped on the orb that is not an application.
    ///
    /// Separate from `onDropPaths`, which adds apps to the ring and takes paths. The shelf needs
    /// URLs, and needs **all** of them — `WheelView.droppedPath` takes `urls.first`, which for a
    /// shelf would accept one file out of five and silently discard the rest.
    var onDropURLs: (([URL]) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    /// A proposed origin for the panel, in screen coordinates. The controller
    /// clamps it; the view does not know which screen it is on.
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    /// Movement under this counts as a click rather than a drag, so a slightly
    /// unsteady click still opens the wheel.
    static let clickSlop: CGFloat = 3

    /// The offset from the pointer to the panel's origin when the press landed.
    /// Held in screen coordinates: deriving it from window-relative coordinates
    /// while the window is moving is the classic cause of jitter and drift.
    private var grabOffset: CGSize?
    private var pressedAt: CGPoint?
    private var didDrag = false
    private var isTargetedByDrag = false

    /// Whether the orb is currently showing its drag highlight.
    ///
    /// Exposed for the smoke checks only, the same shape as `OrbController.panelForTesting`. It exists
    /// because `draggingEntered` now returns `.copy` unconditionally — so the return value no longer
    /// says whether the drag was usable, and the highlight is the only thing that does.
    var isHighlightedForDragTesting: Bool { isTargetedByDrag }

    /// Whether the shelf is holding anything.
    ///
    /// Presence, not a count. The orb is a miniature of the user's own ring — eight dots that are
    /// their apps — and a digit in the middle turns it into a notification widget and costs it that
    /// identity. "Is there something on my shelf?" is the question at rest; "how many exactly?" is
    /// answered in the hub.
    var shelfLoaded = false {
        didSet { if shelfLoaded != oldValue { needsDisplay = true } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
        rebuildTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        for area in trackingAreas { removeTrackingArea(area) }
        guard window != nil else { return }
        // `.activeAlways` is what makes hover work while Chakra is not the front
        // application, and it needs no permission.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways,
                                                 .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        grabOffset = CGSize(width: window.frame.origin.x - pointer.x,
                            height: window.frame.origin.y - pointer.y)
        pressedAt = pointer
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = grabOffset, let start = pressedAt else { return }
        let pointer = NSEvent.mouseLocation
        guard didDrag || hypot(pointer.x - start.x, pointer.y - start.y) > Self.clickSlop
        else { return }
        if !didDrag {
            didDrag = true
            onDragBegan?()
        }
        onDragMoved?(CGPoint(x: pointer.x + offset.width, y: pointer.y + offset.height))
    }

    override func mouseUp(with event: NSEvent) {
        defer { grabOffset = nil; pressedAt = nil }
        guard pressedAt != nil else { return }
        if didDrag {
            didDrag = false
            onDragEnded?()
            return
        }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right-clicking while dragging is treated as a separate gesture: the drag
        // continues uninterrupted and the menu appears. An alternative would be to
        // cancel the drag, but that loses the user's intended destination.
        onRightClick?(event, self)
    }

    func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        let centre = CGPoint(x: g.radius, y: g.radius)

        // A flat disc rather than an NSVisualEffectView: a blur composited over
        // every Space all day is real work, and at this size it is indistinguishable
        // from a solid plate.
        NSColor(white: 0.09, alpha: 0.82).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: g.size, height: g.size)).fill()

        let count = dotColors.count
        for (index, colour) in dotColors.enumerated() {
            let at = g.dotCenter(index: index, count: count, rotation: rotation)
            let r = index == 0 ? g.leadDotRadius : g.dotRadius
            (colour ?? NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: at.x - r, y: at.y - r,
                                        width: r * 2, height: r * 2)).fill()
        }

        if isTargetedByDrag {
            // A ring round the whole orb rather than a tint, so the feedback is
            // visible whatever colours the user's apps happen to be.
            NSColor.controlAccentColor.setStroke()
            let inset = max(1.5, g.size * 0.03)
            let path = NSBezierPath(ovalIn: NSRect(x: inset / 2, y: inset / 2,
                                                   width: g.size - inset,
                                                   height: g.size - inset))
            path.lineWidth = inset
            path.stroke()
        }

        // The centre dot grows and takes the accent colour when the shelf is loaded. At the shipped
        // 35% idle opacity this is still readable, and it costs the orb nothing when the shelf is
        // empty — the radius and the colour are both unchanged in that case.
        let cr = shelfLoaded ? g.centreDotRadius * 1.9 : g.centreDotRadius
        (shelfLoaded ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.75)).setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - cr, y: centre.y - cr,
                                    width: cr * 2, height: cr * 2)).fill()
    }

    /// Every file URL on the drag, through the same reader the pasteboard intake uses.
    ///
    /// Replaces a `paths(from:)` that mapped straight to `\.path`. The shelf needs the URLs
    /// themselves, and routing both this and the paste through `ShelfIntake.fileURLs(from:)` means
    /// there is one place where "which URLs count" is decided.
    private func urls(from info: NSDraggingInfo) -> [URL] {
        ShelfIntake.fileURLs(from: info.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargetedByDrag = !urls(from: sender).isEmpty
        needsDisplay = true
        return .copy
    }

    /// Always `.copy`, even when the drag carries nothing usable.
    ///
    /// Returning `[]` makes AppKit skip `performDragOperation` entirely, so a refusal can never be
    /// explained and reads to the user as a missed drop. `WheelView` learned this and its comment
    /// survives there. The highlight is still withheld for a useless drag — `isTargetedByDrag` above
    /// is what the user sees — so the orb does not flash for a drag it cannot use.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargetedByDrag = false
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Called when a drag session ends without the drop being performed, for
        // instance if the user cancels or drops on a target that refuses it.
        // Without this the accent ring would remain drawn permanently.
        isTargetedByDrag = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargetedByDrag = false
        needsDisplay = true
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }
        // Apps go to the ring; everything else goes to the shelf. Splitting here rather than letting
        // `Shelf` refuse the app is what makes a mixed drop do the right thing with both halves —
        // `Shelf.isApplication` would refuse the `.app` and the user would be told to drop it on the
        // wheel, which is where it just went.
        let applications = dropped.filter { $0.pathExtension.lowercased() == "app" }
        let others = dropped.filter { $0.pathExtension.lowercased() != "app" }
        if !applications.isEmpty { onDropPaths?(applications.map(\.path)) }
        if !others.isEmpty { onDropURLs?(others) }
        return true
    }
}

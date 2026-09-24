import AppKit

/// A panel that can never take keyboard focus.
///
/// Chakra is an accessory app, so activating it would take the menu bar and the
/// typing focus away from whatever the user is working in. The overrides are kept
/// even though a borderless panel already reports false for both: adding `.titled`
/// to the style mask flips `canBecomeKey` to true, and this makes that mistake
/// impossible to make silently.
final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit constrains a window so it cannot cover the menu bar. The orb sits one
    /// level below the menu bar, so that constraint applies to it and silently
    /// refuses any move above `visibleFrame.maxY - size` — which is exactly the
    /// position a tuck into the top edge asks for. Returning the proposal unchanged
    /// opts out. Nothing is lost by doing so: `OrbPlacement.clamp` already decides
    /// where the orb may sit, and the tuck deliberately goes past the edge, so
    /// AppKit's constraint was fighting our own.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Owns the floating orb: its panel, where it sits, and when it is on screen.
final class OrbController: NSObject {
    private let outer: OuterRing
    private let settings: Settings

    /// Nil when the shelf folder could not be resolved at all, which should not happen:
    /// `Application Support` is not TCC-protected and needs no permission. Optional rather than
    /// force-unwrapped because the launcher is the app and the shelf is a feature of it — a shelf
    /// that cannot be resolved must not stop the orb appearing.
    private let shelf: Shelf?

    private var panel: NSPanel?
    private var view: OrbView?

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?
    var onDropPaths: (([String]) -> Void)?
    /// Non-application URLs dropped on the orb, on their way to the shelf.
    var onDropURLs: (([URL]) -> Void)?

    private var isHovered = false
    private var isDragging = false
    /// True while the wheel is open. The orb hides then: the wheel is centred and
    /// the orb would sit on top of it.
    private var isSuppressed = false
    private var screenChangeWork: DispatchWorkItem?

    init(outer: OuterRing, settings: Settings, shelf: Shelf?) {
        self.outer = outer
        self.settings = settings
        self.shelf = shelf
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(ringChanged),
            name: OuterRing.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        screenChangeWork?.cancel()
        // NSWindow methods must be called on the main thread. Deinit runs on whichever
        // thread drops the last reference, so dispatch to main if needed.
        if let panel = panel {
            if Thread.isMainThread {
                panel.orderOut(nil)
            } else {
                DispatchQueue.main.async { panel.orderOut(nil) }
            }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The panel, exposed for smoke tests to assert that the frame actually changes
    /// when tucking and untucking. Not for use by application code.
    var panelForTesting: NSPanel? { panel }

    // MARK: - The panel

    /// Builds the panel with the window-server configuration the orb needs.
    ///
    /// Static and returning the panel so a test can assert the configuration
    /// without going through the whole controller.
    static func makePanel(size: CGFloat, hiddenFromCapture: Bool) -> NSPanel {
        let panel = OrbPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false

        // One below the menu bar: above the Dock (20) and normal windows, but not
        // drawing over the user's menu bar the way `.statusBar` (25) would.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

        // Every Space, over full-screen apps, and hidden while Mission Control is
        // up so the orb is never a stray tile. `.moveToActiveSpace` must never be
        // added: with `.canJoinAllSpaces` it raises an exception and kills the app.
        var behavior: NSWindow.CollectionBehavior =
            [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        if #available(macOS 13, *) { behavior.insert(.canJoinAllApplications) }
        panel.collectionBehavior = behavior

        // Hides the orb's pixels from recordings. It does not hide the window's
        // existence: it is still enumerated by CGWindowListCopyWindowInfo.
        panel.sharingType = hiddenFromCapture ? .none : .readOnly
        return panel
    }

    // MARK: - Lifecycle

    func show() {
        // `isSuppressed` is checked here rather than only in the callers, because
        // there are several and one of them is reached while the wheel is open:
        // dragging the wheel to a new position posts `Settings.didChangeNotification`,
        // which the app delegate turns into `settingsDidChange()`. Without this the
        // orb would reappear on top of the very wheel it is meant to stay out of.
        guard settings.showOrb, !isSuppressed else { return }
        let size = CGFloat(settings.orbSize)
        if panel == nil { build(size: size) }
        guard let panel, let view else { return }

        // Calling show() twice is idempotent: the panel is already built, so this
        // just updates its size and position rather than creating a second one.
        view.geometry = OrbGeometry(size: size)
        panel.setContentSize(NSSize(width: view.geometry.size, height: view.geometry.size))
        view.frame = NSRect(origin: .zero, size: panel.frame.size)
        refreshDots()
        // Read on every show rather than cached, so an orb that was hidden while Finder emptied the
        // folder comes back telling the truth. `total()` is a live directory scan — measured 0.46 ms
        // at ten items, which is 3% of a frame.
        view.shelfLoaded = (shelf?.total().count ?? 0) > 0

        panel.setFrameOrigin(restoredOrigin(size: view.geometry.size))
        applyIdleState(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Applies a change of setting to an orb that may or may not be on screen.
    func settingsDidChange() {
        guard settings.showOrb else {
            hide()
            // Torn down rather than merely hidden, so an orb that is off costs
            // nothing at all.
            panel = nil
            view = nil
            return
        }
        // The sharing type can be tightened at any time but never loosened: macOS
        // accepts .readOnly -> .none but refuses .none -> .readOnly. Switching the
        // setting ON (becoming more private) works without a rebuild; switching it
        // OFF (becoming less private) requires one. Rebuilding unconditionally is
        // simpler and costs little: the orb is small and this happens only when the
        // user changes the setting by hand.
        let expectedSharing: NSWindow.SharingType = settings.orbHiddenFromCapture ? .none : .readOnly
        if let panel, panel.sharingType != expectedSharing {
            panel.orderOut(nil)
            self.panel = nil
            self.view = nil
        }
        show()
    }

    func setSuppressed(_ suppressed: Bool) {
        guard isSuppressed != suppressed else { return }
        isSuppressed = suppressed
        if suppressed { hide() } else if settings.showOrb { show() }
    }

    /// Puts a stranded orb back in the middle of the main screen.
    func recentre() {
        settings.clearOrbPosition()
        show()
    }

    private func build(size: CGFloat) {
        let panel = Self.makePanel(size: size,
                                   hiddenFromCapture: settings.orbHiddenFromCapture)
        let view = OrbView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.geometry = OrbGeometry(size: size)
        view.wantsLayer = true
        panel.contentView = view

        view.onClick = { [weak self] in self?.onClick?() }
        view.onRightClick = { [weak self] event, view in self?.onRightClick?(event, view) }
        view.onDropPaths = { [weak self] paths in self?.onDropPaths?(paths) }
        view.onDropURLs = { [weak self] urls in self?.onDropURLs?(urls) }
        view.onHoverChanged = { [weak self] hovered in
            self?.isHovered = hovered
            self?.applyIdleState(animated: true)
        }
        view.onDragBegan = { [weak self] in
            self?.isDragging = true
            self?.applyIdleState(animated: false)
        }
        view.onDragMoved = { [weak self] proposed in self?.move(to: proposed) }
        view.onDragEnded = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            self.savePosition()
            self.applyIdleState(animated: true)
        }

        self.panel = panel
        self.view = view
    }

    // MARK: - Contents

    /// Tells the orb whether the shelf is holding anything.
    ///
    /// Takes the answer rather than computing it, so the caller that just changed the shelf pays for
    /// the one scan instead of this controller scanning again.
    func shelfChanged(loaded: Bool) {
        view?.shelfLoaded = loaded
    }

    @objc private func ringChanged() { refreshDots() }

    private func refreshDots() {
        guard let view else { return }
        let count = outer.visibleCount
        view.dotColors = (0..<count).map { index in
            guard let item = outer.item(at: index) else { return nil }
            return RingItem.dominantColor(of: item.icon)
        }
        view.rotation = settings.rotation(for: .outer, slotCount: count)
    }

    // MARK: - Position

    /// The screen the orb should be on, resolved from what was saved.
    ///
    /// By display id first, then by localised name, then the main screen. Display
    /// ids are not stable across reboots or GPU switches, which is why the name is
    /// the second chance rather than the only one.
    private func targetScreen() -> NSScreen? {
        let saved = settings.orbDisplayID
        if saved != 0,
           let byID = NSScreen.screens.first(where: { screen in
               (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                   as? NSNumber)?.intValue == saved
           }) {
            return byID
        }
        let name = settings.orbDisplayName
        if !name.isEmpty,
           let byName = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return byName
        }
        return NSScreen.main
    }

    private func restoredOrigin(size: CGFloat) -> CGPoint {
        guard let screen = targetScreen() else { return .zero }
        let visible = screen.visibleFrame
        guard let fraction = settings.orbFraction else {
            // Never placed. The right-hand edge, two-thirds up: out of the way of
            // the Dock and of most windows' content, and on the side the pointer
            // usually is.
            let start = CGPoint(x: visible.maxX - size - 24,
                                y: visible.minY + visible.height * 0.66)
            return OrbPlacement.clamp(start, size: size, in: visible)
        }
        return OrbPlacement.origin(fromFraction: fraction, size: size, in: visible)
    }

    private func move(to proposed: CGPoint) {
        guard let panel, let view else { return }
        let size = view.geometry.size
        // The screen under the *pointer*, so the orb can be dragged to a second
        // display. Clamping to the starting screen would refuse to cross.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? panel.screen ?? NSScreen.main
        guard let screen else { return }
        var origin = OrbPlacement.clamp(proposed, size: size, in: screen.visibleFrame)
        // Aligned to device pixels, or a fractional drag leaves the orb blurry on a
        // 2x display.
        origin = screen.backingAlignedRect(NSRect(origin: origin,
                                                  size: NSSize(width: size, height: size)),
                                           options: [.alignAllEdgesNearest]).origin
        panel.setFrameOrigin(origin)
    }

    private func savePosition() {
        guard let panel, let view else { return }
        guard let screen = panel.screen else {
            // The panel is not on any display. This can happen if a display was
            // unplugged while the orb was on it, or if the panel's frame is entirely
            // outside all screens. In this case, do not save: losing the last known
            // good position would make the orb harder to recover. The next call to
            // show() will restore it to the saved position or the default, and if
            // that is also unreachable, it lands on the main screen.
            return
        }
        let visible = screen.visibleFrame
        let size = view.geometry.size
        // The untucked origin is what gets saved: the orb must not creep further
        // off the edge every time it is saved while tucked.
        let origin = untuckedOrigin(of: panel.frame.origin, size: size, in: visible)
        settings.orbFraction = OrbPlacement.fraction(ofOrigin: origin, size: size,
                                                     in: visible)
        settings.orbDisplayID =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.intValue ?? 0
        settings.orbDisplayName = screen.localizedName
    }

    /// Where the orb would be if it were not tucked, given where it is now.
    private func untuckedOrigin(of origin: CGPoint, size: CGFloat,
                                in visible: CGRect) -> CGPoint {
        OrbPlacement.clamp(origin, size: size, in: visible)
    }

    // MARK: - Idle, hover, tuck

    private func applyIdleState(animated: Bool) {
        guard let panel, let view else { return }
        let hot = isHovered || isDragging
        let size = view.geometry.size
        // If panel.screen is nil — the panel is off all displays — fall back to the main
        // screen's visible frame. An orb stranded on a disconnected display must still
        // compute a sensible position to return to.
        //
        // Bailing out rather than substituting `.zero`, which was not sensible: clamping
        // into an empty rect yields origin (0, 0), `nearestEdge` then reports `.left`
        // because 0 - 0 is within the threshold, and the tuck slides the orb to
        // x = -34.72 — 62% off the left edge of the main display, where
        // `OrbPanel.constrainFrameRect` deliberately will not pull it back. Leaving the
        // orb exactly where it is costs nothing; the next `show()` repositions it from
        // the saved fraction anyway.
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let resting = untuckedOrigin(of: panel.frame.origin, size: size, in: visible)

        var origin = resting
        if !hot, settings.orbTucksAtEdge {
            let edge = OrbPlacement.nearestEdge(origin: resting, size: size, in: visible)
            origin = OrbPlacement.tuckedOrigin(resting, size: size, in: visible, edge: edge)
        }
        let opacity = hot ? 1 : CGFloat(settings.orbIdleOpacity)

        guard animated else {
            panel.alphaValue = opacity
            panel.setFrameOrigin(origin)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = opacity
            panel.animator().setFrame(NSRect(origin: origin, size: panel.frame.size),
                                      display: false)
        }
    }

    // MARK: - Displays

    @objc private func screensChanged() {
        // Fires several times in a burst while a display is being reconfigured, so
        // the work is debounced rather than done per notification.
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.settings.showOrb, !self.isSuppressed else { return }
            self.show()
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

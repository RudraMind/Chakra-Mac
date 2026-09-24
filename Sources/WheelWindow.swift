import AppKit

/// A borderless window still has to be allowed to take key focus, otherwise the
/// wheel could not receive key events and could not tell when to dismiss.
final class WheelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the wheel's window, decides where it appears, and turns the view's
/// intents into actions on the two stores.
final class WheelController: NSObject, NSWindowDelegate {
    /// Why the wheel is being hidden. Only a hide that was forced by losing focus
    /// needs the guard against immediately reopening.
    enum HideReason {
        case user
        case lostFocus
    }

    private let outer: OuterRing
    private let recents: Recents
    private let settings: Settings
    /// The file shelf, or nil when its folder could not be resolved. Read only for
    /// the hub's count and size; the wheel works without it.
    private let shelf: Shelf?

    private var window: WheelWindow?
    private var disc: NSVisualEffectView?
    private var wheel: WheelView?
    private var geometry = RingGeometry()
    /// The scale the glass mask was last built for, so it is only rebuilt when the
    /// wheel actually changes size.
    private var maskedScale: CGFloat?
    /// The part of the screen the window covers, in screen coordinates.
    private var screenFrame: CGRect = .zero

    private(set) var isVisible = false
    /// Called whenever the wheel appears or disappears.
    ///
    /// A list rather than a single closure: the menu-bar item uses it for its
    /// highlight and the orb uses it to get out of the way, and a second
    /// assignment to a single property would silently discard the first.
    private var visibilityObservers: [(Bool) -> Void] = []
    private var lastResignHide = Date.distantPast
    /// Bumped on every show. A fade-out that finishes after a new show has begun
    /// must not order the window out from under it.
    private var generation = 0

    /// Clicking the menu-bar item makes the status window key, which resigns the
    /// wheel's key status and hides it. Without this guard the click that should
    /// close the wheel would immediately reopen it.
    private var recentlyHidden: Bool { Date().timeIntervalSince(lastResignHide) < 0.35 }

    /// `shelf` defaults to nil so a caller that has no shelf — the smoke tool, and any
    /// future one — keeps compiling and gets a wheel whose hub simply reads empty.
    init(outer: OuterRing, recents: Recents, settings: Settings, shelf: Shelf? = nil) {
        self.outer = outer
        self.recents = recents
        self.settings = settings
        self.shelf = shelf
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func observeVisibility(_ observer: @escaping (Bool) -> Void) {
        visibilityObservers.append(observer)
    }

    private func reportVisibility(_ visible: Bool) {
        for observer in visibilityObservers { observer(visible) }
    }

    @objc private func screensChanged() {
        // The window was sized to a screen that may no longer exist.
        if isVisible { hide() }
    }

    // MARK: - Presentation

    /// Opens the wheel if it is closed, closes it if open.
    ///
    /// The `ignoringRecentHide` parameter exists for the orb, which is hidden while
    /// the wheel is open and therefore cannot be the click that dismissed the wheel.
    /// The menu-bar item stays visible, so a click on it can both dismiss and reopen
    /// in one physical action, which is why the guard exists. The orb needs to bypass
    /// it or it would be unresponsive for 0.35s after every wheel closure.
    func toggle(atCursor: Bool, ignoringRecentHide: Bool = false) {
        if isVisible {
            hide()
        } else if ignoringRecentHide || !recentlyHidden {
            show(atCursor: atCursor)
        }
    }

    func show(atCursor: Bool, message: String? = nil) {
        guard !isVisible else {
            refresh()
            if let message { wheel?.flashMessage(message) }
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { return }

        // `visibleFrame` rather than `frame`: the window must not reach over the
        // menu bar or the Dock. It would both cover them and, because the view
        // claims every click on its frame, swallow clicks meant for them.
        let frame = screen.visibleFrame
        guard frame.width > 0, frame.height > 0 else { return }
        screenFrame = frame

        let window = makeWindowIfNeeded()
        window.setFrame(frame, display: false)
        guard let container = window.contentView, let wheel else { return }
        container.frame = NSRect(origin: .zero, size: frame.size)
        wheel.frame = container.bounds

        // Reset first: it stops any animation left over from the last time the wheel
        // was open, and the sweep below has to be the only one running.
        wheel.resetTransientState()
        applyLayout(center: requestedCenter(atCursor: atCursor, mouse: mouse, frame: frame))
        populate()
        wheel.beginSweep()
        wheel.needsDisplay = true

        isVisible = true
        reportVisibility(true)
        generation += 1
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        // The cooperative `activate()` added in macOS 14 is documented as
        // refusable, and from an accessory app it is in fact refused. When that
        // happens the window never becomes key: no keyboard, and no
        // `windowDidResignKey`, which is the whole dismissal mechanism.
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(wheel)
        if let message { wheel.flashMessage(message) }

        NSAnimationContext.runAnimationGroup { context in
            // Matched to the wheel's opening sweep, so the fade and the rotation
            // finish together instead of the wheel snapping solid mid-turn.
            context.duration = settings.spinOnOpen ? WheelView.sweepDuration - 0.03 : 0.12
            window.animator().alphaValue = 1
        }
    }

    func hide(reason: HideReason = .user) {
        guard isVisible, let window else { return }
        isVisible = false
        reportVisibility(false)
        if reason == .lostFocus {
            // Only a focus-driven hide needs this: the click that took focus away
            // may be the one on the menu-bar icon, which would otherwise be read
            // as a request to reopen. A hide the user asked for explicitly must
            // not block the next open.
            lastResignHide = Date()
        }
        NSCursor.arrow.set()
        let token = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A show() that arrived during the fade owns the window now. Ordering
            // it out here would leave `isVisible` true with nothing on screen, and
            // the ring could never be opened again.
            guard let self else {
                window.orderOut(nil)
                return
            }
            guard self.generation == token, !self.isVisible else { return }
            window.orderOut(nil)
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere outside dismisses. Using key status rather than a
        // global event monitor is what keeps Chakra free of an Accessibility
        // permission prompt.
        hide(reason: .lostFocus)
    }

    /// Where the wheel should open, in window coordinates and before clamping.
    private func requestedCenter(atCursor: Bool, mouse: CGPoint, frame: CGRect) -> CGPoint {
        let middle = CGPoint(x: frame.width / 2, y: frame.height / 2)
        switch settings.openLocation {
        case .center:
            return middle
        case .saved:
            guard let fraction = settings.savedCenterFraction else { return middle }
            return CGPoint(x: frame.width * fraction.x, y: frame.height * fraction.y)
        case .pointer:
            // Opened from the menu bar the cursor sits at the top of the screen,
            // so centring on it would push most of the wheel off the display.
            return atCursor
                ? CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
                : middle
        }
    }

    /// Resolves size and position together, so drawing, hit-testing and the glass
    /// can never be working from different numbers.
    private func applyLayout(center raw: CGPoint) {
        guard let wheel else { return }
        let size = screenFrame.size
        let outerCount = settings.outerSlotCount
        let innerCount = settings.innerSlotCount
        geometry = RingGeometry(scale: RingGeometry.scale(forScreen: size,
                                                          userSize: settings.wheelSize),
                                outerSlotCount: outerCount,
                                innerSlotCount: innerCount,
                                // The ring comes back turned to wherever the user
                                // last left it, which is the point of remembering it.
                                outerRotation: settings.rotation(for: .outer,
                                                                 slotCount: outerCount),
                                innerRotation: settings.rotation(for: .inner,
                                                                 slotCount: innerCount))
        let center = geometry.clampCenter(raw, in: size)
        wheel.geometry = geometry
        wheel.wheelCenter = center
        applyAppearance()
        positionGlass(at: center)
    }

    private func positionGlass(at center: CGPoint) {
        guard let disc else { return }
        let diameter = geometry.discRadius * 2
        disc.frame = NSRect(x: center.x - geometry.discRadius, y: center.y - geometry.discRadius,
                            width: diameter, height: diameter)
        // The mask depends only on the scale, and this runs once per mouse-move
        // while the wheel is being dragged, so rebuilding it every time meant
        // rendering four ovals into a 454-point bitmap for nothing.
        if maskedScale != geometry.scale {
            disc.maskImage = Self.donutMask(geometry: geometry)
            maskedScale = geometry.scale
        }
    }

    private func applyAppearance() {
        guard let wheel, let disc else { return }
        let opacity = CGFloat(settings.glassOpacity)
        disc.alphaValue = opacity
        // Hidden rather than merely transparent at zero: an invisible blur is
        // still work for the compositor, and zero means "no glass at all".
        disc.isHidden = opacity <= 0.01
        wheel.glassOpacity = opacity
        wheel.glassTint = settings.glassTint.color
        wheel.colorful = settings.colorfulHighlights
        wheel.scrollToSpin = settings.scrollToSpin
        wheel.spinOnOpen = settings.spinOnOpen
    }

    /// Re-reads every setting and applies it to a wheel that is already open, so
    /// changes in the settings window can be watched as they are made.
    func settingsDidChange() {
        guard isVisible, let wheel else { return }
        applyLayout(center: wheel.wheelCenter)
        populate()
        wheel.needsDisplay = true
    }

    // MARK: - Moving

    private func moved(to center: CGPoint) {
        positionGlass(at: center)
    }

    private func moveEnded(at center: CGPoint) {
        settings.savedCenterFraction = RingGeometry.fraction(ofCenter: center,
                                                            in: screenFrame.size)
        // Dragging the wheel somewhere is a statement about where it belongs, so
        // it also becomes where the wheel opens. The setting stays visible in the
        // settings window for anyone who wants the pointer or the centre back.
        settings.openLocation = .saved
        // Two settings just changed without anybody touching the control that shows
        // them, so a settings window that is already open has to catch up.
        settings.postDidChange()
        wheel?.flashMessage("Chakra will open here")
    }

    // MARK: - Contents

    /// Refreshes what the wheel shows. Safe to call while it is open.
    func refresh() {
        guard isVisible, let wheel else { return }
        populate()
        applyAppearance()
        wheel.needsDisplay = true
    }

    private func populate() {
        guard let wheel else { return }
        outer.reload()
        let pinned = outer.occupiedPaths
        wheel.outerItems = (0..<settings.outerSlotCount).map { outer.item(at: $0) }
        wheel.innerItems = recents
            .inner(excluding: pinned, limit: settings.innerSlotCount)
            .map { RingItem.make(path: $0) }
        wheel.runningPaths = Self.runningAppPaths()
        // `total()` is a live directory scan — 0.46 ms at ten items, 38.9 ms at a
        // thousand — so it is read exactly once here, the single funnel every show,
        // refresh and settings change already passes through, and never per frame.
        // No shelf means an empty hub rather than a hidden one: nil is survivable.
        let shelved = shelf?.total()
        wheel.shelfCount = shelved?.count ?? 0
        wheel.shelfBytes = shelved?.bytes ?? 0
    }

    private static func runningAppPaths() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap {
            guard let path = $0.bundleURL?.path else { return nil }
            return RingItem.normalizePath(path)
        })
    }

    /// The glass is two separate bands, one per ring, with see-through desktop in
    /// the middle, between them, and outside them. Nesting four circles under the
    /// even-odd rule fills a point only when an odd number of circles contain it,
    /// which alternates band, gap, band as the radius grows.
    ///
    /// Internal rather than private so `WheelView` can wash the same shape with a
    /// tint, and `Tools/Preview.swift` can draw it, instead of either keeping a
    /// copy that could drift out of step.
    static func glassPath(geometry g: RingGeometry, center: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        for radius in [g.outerBandOuter, g.outerBandInner, g.innerBandOuter, g.innerBandInner] {
            path.append(NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2)))
        }
        path.windingRule = .evenOdd
        return path
    }

    /// Masking an `NSVisualEffectView` through `maskImage` is the supported route
    /// for a non-rectangular blur; a CALayer mask can defeat it.
    ///
    /// Drawn through a handler rather than `lockFocus`, which bakes a single
    /// bitmap at whatever scale the current screen has — the mask would stay soft
    /// after the wheel moved to a display with a different backing scale.
    static func donutMask(geometry: RingGeometry) -> NSImage {
        let diameter = geometry.discRadius * 2
        let center = CGPoint(x: geometry.discRadius, y: geometry.discRadius)
        let image = NSImage(size: NSSize(width: diameter, height: diameter),
                            flipped: false) { _ in
            NSColor.black.setFill()
            glassPath(geometry: geometry, center: center).fill()
            return true
        }
        // Stretch rather than tile, so a mask that is ever a pixel off the view's
        // size scales instead of repeating into a mess.
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Window construction

    private func makeWindowIfNeeded() -> WheelWindow {
        if let window { return window }

        let created = WheelWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.level = .popUpMenu
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.alphaValue = 0

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        container.addSubview(effect)

        let view = WheelView(frame: container.bounds)
        container.addSubview(view)
        created.contentView = container

        view.onLaunch = { [weak self] item, _, _ in self?.launch(item) }
        view.onQuit = { [weak self] item in self?.quit(item) }
        view.onRemoveOuter = { [weak self] index in self?.removeOuter(index) }
        view.canRemoveOuter = { [weak self] index in self?.outer.canRemove(at: index) ?? false }
        view.onPromote = { [weak self] item, index in self?.promote(item, to: index) }
        view.onDropPath = { [weak self] path, index, isMove in
            self?.drop(path: path, at: index, isMove: isMove)
        }
        view.onDismiss = { [weak self] in self?.hide() }
        // Read at the moment of the drag rather than handed over with the count, so the drag
        // promises only what is on disk when it starts.
        view.shelfURLsForDrag = { [weak self] in
            self?.shelf?.items().map(\.url) ?? []
        }
        // `.user`, not `.lostFocus`: this hide is not a focus loss, and `.lostFocus` would set
        // `lastResignHide` and make the next open look like an accidental reopen.
        view.onShelfDragBegan = { [weak self] in self?.hide() }
        // Asked once per drag, on arrival. `exceedsCap` is the same arithmetic `add(_:)` uses, so
        // the hub cannot predict one answer and then refuse with another.
        view.shelfDropRefusal = { [weak self] urls in
            guard let shelf = self?.shelf else { return nil }
            let existing = shelf.total().bytes
            guard shelf.exceedsCap(urls, existing: existing) else { return nil }
            return ShelfMessage.capForecast(existing: existing, cap: Shelf.capBytes)
        }
        view.onShelfDrop = { [weak self] urls in self?.shelveOnHub(urls) }
        view.onOpenShelf = { [weak self] in
            guard let self, let shelf = self.shelf else { return }
            // Hidden first. Opening Finder takes focus and would hide the wheel anyway, so doing
            // it explicitly is the difference between a deterministic order and a race.
            self.hide()
            NSWorkspace.shared.open(shelf.root)
        }
        view.onMove = { [weak self] center in self?.moved(to: center) }
        view.onMoveEnded = { [weak self] center in self?.moveEnded(at: center) }
        view.onRotationSettled = { [weak self] ring, steps in
            guard let self else { return }
            switch ring {
            case .outer: self.settings.outerRotationSteps = steps
            case .inner: self.settings.innerRotationSteps = steps
            }
        }

        window = created
        disc = effect
        wheel = view
        return created
    }

    // MARK: - Actions

    private func launch(_ item: RingItem) {
        // A pinned slot may hold a folder rather than an app; the two need
        // different calls, and openApplication would fail on a folder.
        guard item.url.pathExtension.lowercased() == "app" else {
            // `open` answers immediately, so the ring can stay up to report a
            // failure instead of closing and reopening.
            if NSWorkspace.shared.open(item.url) {
                recents.record(item.path)
                hide()
            } else {
                NSSound.beep()
                wheel?.flashMessage("Could not open \(item.name)")
            }
            return
        }

        // Launching an app can take seconds when it is cold, and holding the ring
        // open that long would make every click feel slow. So it closes at once
        // and comes back with the message if the launch actually failed.
        hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) {
            [weak self] _, error in
            // This completion runs off the main thread.
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    NSSound.beep()
                    self.show(atCursor: false, message: "Could not open \(item.name)")
                } else {
                    self.recents.record(item.path)
                }
            }
        }
    }

    private func quit(_ item: RingItem) {
        let matches = NSWorkspace.shared.runningApplications.filter {
            guard let path = $0.bundleURL?.path else { return false }
            return RingItem.normalizePath(path) == item.path
        }
        guard !matches.isEmpty else {
            wheel?.flashMessage("\(item.name) isn't running")
            return
        }
        for app in matches { app.terminate() }
        wheel?.flashMessage("Quitting \(item.name)")
        // The wheel stays open so several apps can be quit in one visit.
        wheel?.runningPaths = Self.runningAppPaths()
        wheel?.needsDisplay = true
    }

    private func removeOuter(_ index: Int) {
        guard let item = outer.item(at: index) else { return }
        guard outer.remove(at: index) else {
            wheel?.flashMessage("The ring keeps at least \(Settings.minOuterApps) apps")
            return
        }
        refresh()
        wheel?.flashMessage("Removed \(item.name)")
    }

    /// Files dropped on the hub.
    ///
    /// The wheel stays open, unlike a drop on the orb, which opens it to report. It is already open
    /// and the user is looking at the hole they dropped into, so the readout updating in place *is*
    /// the report — and closing the wheel under a pointer that has just released would be the
    /// opposite of feedback.
    private func shelveOnHub(_ urls: [URL]) {
        guard let shelf else { return }
        let outcome = shelf.add(urls)
        // Before the message, so the count under the pointer is already right when it is read.
        populate()
        // No explicit repaint: `shelfCount`/`shelfBytes` invalidate on assignment, and
        // `flashMessage` invalidates for its own note.
        wheel?.flashMessage(ShelfMessage.summary(outcome, shelf: shelf))
    }

    private func promote(_ item: RingItem, to index: Int?) {
        if let index {
            guard outer.set(item.path, at: index) else {
                NSSound.beep()
                wheel?.flashMessage("\(item.name) is already on the ring")
                return
            }
        } else if outer.addToFirstEmpty(item.path) == nil {
            NSSound.beep()
            wheel?.flashMessage(outer.isFull
                ? "Ring is full — drag onto a slot instead"
                : "\(item.name) is already on the ring")
            return
        }
        refresh()
        wheel?.flashMessage("Pinned \(item.name)")
    }

    private func drop(path: String, at index: Int, isMove: Bool) {
        let item = RingItem.make(path: path)
        guard !item.isMissing else {
            wheel?.flashMessage("That item no longer exists")
            return
        }
        // A drag that started on this wheel means "put it here", so the slot it
        // came from is cleared rather than the drop being refused as a duplicate.
        // That is also what makes dragging one outer slot onto another a move.
        if isMove {
            let wasPinned = outer.contains(item.path)
            guard outer.assign(item.path, at: index) else { return }
            refresh()
            wheel?.flashMessage(wasPinned ? "Moved \(item.name)" : "Pinned \(item.name)")
            return
        }
        guard outer.set(item.path, at: index) else {
            NSSound.beep()
            wheel?.flashMessage("\(item.name) is already on the ring")
            return
        }
        refresh()
        wheel?.flashMessage("Added \(item.name)")
    }
}

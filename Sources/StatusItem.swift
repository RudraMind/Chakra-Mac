import AppKit

/// A transparent overlay on the status-bar button.
///
/// `NSStatusBarButton` is not a drag destination, so accepting a dropped app on
/// the menu-bar icon means putting a view that is one on top of it. That view
/// then has to handle the clicks too, since it swallows them.
final class StatusDropView: NSView {
    var onLeftClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDropPaths: (([String]) -> Void)?

    private var isTargeted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("Chakra builds its views in code") }

    override func draw(_ dirtyRect: NSRect) {
        guard isTargeted else { return }
        let rect = bounds.insetBy(dx: 1, dy: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(event)
        } else {
            onLeftClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    private func paths(from info: NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: options) as? [URL] else {
            return []
        }
        return urls.map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !paths(from: sender).isEmpty else { return [] }
        isTargeted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
        needsDisplay = true
    }

    /// Called when a drag session ends without the drop being performed — the user
    /// cancelled, or released over a target that refused it.
    ///
    /// `draggingExited` is documented only as "the dragged image exits the destination's
    /// bounds"; Apple does not promise it for a session that ends *in place*, and names
    /// `draggingEnded` as the end-of-session hook. Without this the accent wash in
    /// `draw` would stay painted on the menu bar, and nothing else clears it —
    /// `statusItem.button?.highlight(_:)` targets the button, not this overlay.
    ///
    /// `OrbView` already carries the same override for the same reason. This view was
    /// the only one of the three drop targets missing it.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        isTargeted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        needsDisplay = true
        let dropped = paths(from: sender)
        guard !dropped.isEmpty else { return false }
        onDropPaths?(dropped)
        return true
    }
}

/// The menu-bar presence: icon, click handling, drop target and menu.
final class StatusItemController: NSObject {
    private let outer: OuterRing
    private let wheel: WheelController
    private let settings: Settings
    private let statusItem: NSStatusItem
    private let dropView: StatusDropView

    /// Set by the app delegate after it tries to claim the shortcut: why it is not
    /// working, or nil when it is.
    var hotkeyFailure: HotKey.Failure?
    var onSetUpRing: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(outer: OuterRing, wheel: WheelController, settings: Settings) {
        self.outer = outer
        self.wheel = wheel
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        dropView = StatusDropView(frame: .zero)
        super.init()

        guard let button = statusItem.button else { return }
        button.image = Self.icon()
        button.imagePosition = .imageOnly
        button.toolTip = "Chakra — click for your app ring, or drop an app here to add it"

        dropView.frame = button.bounds
        dropView.autoresizingMask = [.width, .height]
        dropView.toolTip = button.toolTip
        button.addSubview(dropView)

        dropView.onLeftClick = { [weak self] in self?.wheel.toggle(atCursor: false) }
        dropView.onRightClick = { [weak self] event in self?.showMenu(with: event) }
        dropView.onDropPaths = { [weak self] paths in self?.add(paths) }

        // The overlay swallows the clicks the button would otherwise highlight
        // itself for, so the highlight follows the wheel instead — which is also
        // more honest, since it tracks the ring however it was opened.
        wheel.observeVisibility { [weak self] visible in
            self?.statusItem.button?.highlight(visible)
        }
    }

    /// Eight dots on a ring, drawn rather than pulled from SF Symbols so it
    /// cannot depend on a particular symbol existing, and marked as a template
    /// so macOS handles menu-bar tinting.
    ///
    /// Drawn through a handler rather than `lockFocus`, which bakes one bitmap at
    /// the current screen's scale: the same image is used at 54 points in the
    /// welcome window and on displays with different backing scales.
    static func icon() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            let center = CGPoint(x: side / 2, y: side / 2)
            let radius: CGFloat = 6.1
            for index in 0..<8 {
                let angle = CGFloat.pi / 2 - 2 * CGFloat.pi * CGFloat(index) / 8
                let point = CGPoint(x: center.x + cos(angle) * radius,
                                    y: center.y + sin(angle) * radius)
                // The top dot is larger so the ring has a visible orientation.
                let dot: CGFloat = index == 0 ? 2.2 : 1.5
                NSBezierPath(ovalIn: NSRect(x: point.x - dot, y: point.y - dot,
                                            width: dot * 2, height: dot * 2)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.1, y: center.y - 1.1,
                                        width: 2.2, height: 2.2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Adding apps

    /// Adds whatever was dropped on the icon, and says exactly what happened to
    /// each item. Dropping five apps onto a ring with two free slots used to report
    /// "Added 2 apps" and leave the other three unaccounted for.
    ///
    /// Internal rather than private: the orb calls this so dropping an app on either
    /// entry point behaves identically.
    func add(_ paths: [String]) {
        var added: [String] = []
        var missing = 0
        var duplicates = 0
        var noRoom = 0

        for path in paths {
            let item = RingItem.make(path: path)
            if item.isMissing {
                missing += 1
            } else if outer.contains(item.path) {
                duplicates += 1
            } else if outer.addToFirstEmpty(item.path) != nil {
                added.append(item.name)
            } else {
                noRoom += 1
            }
        }

        var skipped: [String] = []
        if noRoom > 0 { skipped.append("\(noRoom) didn't fit") }
        if duplicates > 0 { skipped.append("\(duplicates) already there") }
        if missing > 0 { skipped.append("\(missing) no longer exists") }

        let message: String
        if added.isEmpty {
            NSSound.beep()
            if noRoom > 0 {
                message = "Ring is full — drop onto a slot to replace what's there"
            } else if duplicates > 0 {
                message = duplicates == 1
                    ? "That app is already on the ring"
                    : "All \(duplicates) are already on the ring"
            } else {
                message = "That item no longer exists"
            }
        } else {
            let head = added.count == 1 ? "Added \(added[0])" : "Added \(added.count) apps"
            message = skipped.isEmpty ? head : head + " — " + skipped.joined(separator: ", ")
            if !skipped.isEmpty { NSSound.beep() }
        }
        // Opening the wheel is the useful response either way: the user can see
        // the result, and drop onto a specific slot to replace what is there.
        wheel.show(atCursor: false, message: message)
    }

    @objc private func addAppFromPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add to Ring"
        panel.message = "Choose apps for the outer ring"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        add(panel.urls.map(\.path))
    }

    // MARK: - Menu

    /// Shows the menu-bar menu, positioned relative to the given view.
    ///
    /// Internal rather than private: the orb calls this so right-clicking either
    /// entry point shows the same menu, and passing the view ensures the menu
    /// appears at the orb rather than up at the status item.
    func showMenu(with event: NSEvent, relativeTo view: NSView? = nil) {
        // `popUpContextMenu` runs its own tracking loop and returns once the menu
        // has gone, so the highlight can simply be bracketed around it.
        let button = statusItem.button
        button?.highlight(true)
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: view ?? dropView)
        button?.highlight(wheel.isVisible)
    }

    /// The menu is rebuilt from current state every time it opens, so checkmarks
    /// and the slot count are always accurate without any invalidation dance.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "Open Ring", action: #selector(openRing), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Add App…", action: #selector(addAppFromPanel),
                                 keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        let setUp = NSMenuItem(title: "Set Up Ring…", action: #selector(setUpRing),
                               keyEquivalent: "")
        setUp.target = self
        menu.addItem(setUp)

        // Everything that used to be a menu toggle now lives here, where the eight
        // slots, the size and the colours can be seen at once.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        if settings.hotkeyEnabled, let failure = hotkeyFailure {
            // Not an enabled control: for a taken combination the fix is to pick a
            // different one, which is what Settings is for, and for the other there
            // is no fix from here at all. Saying so beats a dead menu item.
            let title: String
            switch failure {
            case .combinationTaken:
                title = "\(settings.hotkeyDisplay) is in use — pick another in Settings"
            case .cannotListen:
                title = "Keyboard shortcuts are unavailable — use this icon"
            }
            let unavailable = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }

        // A Dock icon is the one appearance choice worth reaching without opening
        // Settings: it is how the user gets Chakra out of the menu bar entirely.
        let dock = NSMenuItem(title: "Keep Chakra in the Dock", action: #selector(toggleDock),
                              keyEquivalent: "")
        dock.target = self
        dock.state = settings.showInDock ? .on : .off
        menu.addItem(dock)
        if settings.showInDock {
            // The Dock only keeps a running app's icon until it quits. Apple's own
            // way to make it permanent is the Dock icon's own menu, so say so
            // rather than rewriting the Dock's preferences behind its back.
            let keep = NSMenuItem(
                title: "   To keep it there after quitting: right-click the Dock icon → "
                    + "Options → Keep in Dock",
                action: nil, keyEquivalent: "")
            keep.isEnabled = false
            menu.addItem(keep)
        }
        menu.addItem(.separator())

        let filled = outer.occupiedPaths.count
        let info = NSMenuItem(
            title: "\(filled) of \(outer.visibleCount) slots filled", action: nil,
            keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        let tip = NSMenuItem(title: "Drag an app onto this icon to add it", action: nil,
                             keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Chakra", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleDock() {
        DockPresence.set(!settings.showInDock, in: settings)
    }

    @objc private func openRing() { wheel.show(atCursor: false) }
    @objc private func setUpRing() { onSetUpRing?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

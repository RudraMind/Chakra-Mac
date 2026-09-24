import AppKit

/// First-launch setup: either build the ring from what the user already uses, or
/// start empty and let them fill it by hand. Shown once, and reachable again
/// from the menu.
final class OnboardingController: NSObject, NSWindowDelegate {
    private let outer: OuterRing
    private let recents: Recents
    private let settings: Settings

    private var window: NSWindow?
    private var completion: (() -> Void)?
    private var proposal: [String] = []
    /// The empty slots the proposal will be poured into, captured when it is
    /// computed so the rows the user confirms are the slots that get filled.
    private var targetSlots: [Int] = []

    var onOpenSettings: (() -> Void)?

    init(outer: OuterRing, recents: Recents, settings: Settings) {
        self.outer = outer
        self.recents = recents
        self.settings = settings
        super.init()
    }

    func presentIfNeeded(completion: @escaping () -> Void) {
        guard !settings.didOnboard else {
            completion()
            return
        }
        present(completion: completion)
    }

    func present(completion: @escaping () -> Void) {
        // A second call while the window is open must not strand the first
        // completion handler.
        if self.completion != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        self.completion = completion
        showWelcome()
    }

    // MARK: - Window

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
                               styleMask: [.titled, .closable],
                               backing: .buffered, defer: false)
        created.title = "Chakra"
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.center()
        window = created
        return created
    }

    private func show(_ content: NSView) {
        let window = ensureWindow()
        // The confirmation step's height depends on how many apps were proposed, so
        // the window is sized to its content rather than to a guess. Without this, a
        // long list is clipped by the window it was put into.
        let fitting = content.fittingSize
        let width = max(460, fitting.width)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        // The clamp has to be against the space left for *content*, not against the
        // whole visible frame: `setContentSize` excludes the title bar, so clamping
        // to the visible height produced a window one title bar too tall, and
        // `center()` then tucked the title bar under the menu bar.
        let chrome = window.frame.height - (window.contentView?.frame.height ?? window.frame.height)
        let room = max(visible.height - max(chrome, 0) - 24, 200)

        if fitting.height > room {
            // Taller than the display can hold. Scrolling rather than clamping: a
            // clamp alone left the "Use These 8 Apps" button below the window's
            // bottom edge with no way to reach it.
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: room))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            content.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = content
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            ])
            window.contentView = scroll
            window.setContentSize(NSSize(width: width, height: room))
        } else {
            window.contentView = content
            if fitting.height > 0 {
                window.setContentSize(NSSize(width: width, height: fitting.height))
            }
        }
        window.center()
        // Not the cooperative `activate()`: from an accessory app that is not
        // frontmost it is refused, and the first-launch window would open unfocused.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window is a decision too: start empty.
        finish()
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        settings.didOnboard = true
        window?.orderOut(nil)
        completion()
    }

    // MARK: - Step one

    private func showWelcome() {
        let stack = verticalStack()

        let logo = NSImageView()
        logo.image = StatusItemController.icon()
        logo.contentTintColor = .controlAccentColor
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 54).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 54).isActive = true
        stack.addView(logo, in: .top)

        stack.addView(title("Welcome to Chakra"), in: .top)
        // The counts are read rather than written into the copy: they are settings,
        // and telling a user with a six-slot ring that they have eight would be a
        // small lie that is easy to leave behind.
        let outerCount = outer.visibleCount
        let innerCount = settings.innerSlotCount
        let innerSentence = innerCount == 0
            ? "The inner ring is currently switched off; turn it on in Settings to see "
              + "what you used most recently."
            : "The \(innerCount) inner slots fill themselves with whatever you used "
              + "most recently."
        stack.addView(body("""
            Chakra puts your apps in a ring. Click the ring in your menu bar, or \
            press \(settings.hotkeyDisplay), and it opens wherever your pointer is.

            The \(outerCount) outer slots are yours — they never move, so a direction \
            always means the same app. \(innerSentence)

            Drag the middle of the wheel to move it, and it will open there next \
            time. Everything else — how many apps, how big, what colour, which app \
            sits where — is in Settings, under the menu-bar icon.

            How would you like to start?
            """), in: .top)

        let seed = NSButton(title: "Set Up from My Dock and Recent Apps",
                            target: self, action: #selector(chooseSeed))
        seed.bezelStyle = .rounded
        seed.keyEquivalent = "\r"
        stack.addView(seed, in: .top)

        let choose = NSButton(title: "Choose Them Myself", target: self,
                              action: #selector(chooseManually))
        choose.bezelStyle = .rounded
        stack.addView(choose, in: .top)

        // Deliberately names the menu-bar icon rather than the wheel: starting a
        // drag from Finder means clicking in Finder, which takes focus away and
        // closes the wheel, so an app cannot be dropped onto a slot from outside.
        stack.addView(footnote("You can change any slot later — drop an app on the "
                               + "menu-bar icon, or pick one in Settings."),
                      in: .top)
        show(stack)
    }

    /// Marks onboarding done and opens Settings, where the user can fill the ring by
    /// hand. This replaced a "Start Empty" button: an empty ring is the one state the
    /// three-app floor exists to prevent, and offering it as a first-run choice made
    /// the floor look arbitrary the first time the user hit it.
    @objc private func chooseManually() {
        settings.didOnboard = true
        window?.orderOut(nil)
        onOpenSettings?()
    }

    @objc private func chooseSeed() {
        // Only the empty slots are up for grabs: re-running setup from the menu
        // must not overwrite a ring the user has already arranged.
        // Only the visible slots: filling a hidden one would look like nothing
        // happened.
        targetSlots = outer.visibleRange.filter { outer.slots[$0].isEmpty }
        proposal = RingProposal.compute(dock: RingProposal.dockApps(),
                                        spotlight: Recents.spotlightRanking(limit: 40),
                                        pinned: outer.occupiedPaths,
                                        selfPath: Bundle.main.bundleURL.path,
                                        freeSlots: targetSlots.count)
        guard !proposal.isEmpty else {
            // Either the ring is already full or nothing eligible was found.
            // Saying so beats a window that closes on its own.
            showNothingFound(ringIsFull: targetSlots.isEmpty)
            return
        }
        showConfirmation()
    }

    // MARK: - Step two

    private func showConfirmation() {
        let stack = verticalStack()
        let isFresh = targetSlots.count == outer.visibleCount
        stack.addView(title(isFresh ? "Start with these?" : "Fill your empty slots with these?"),
                      in: .top)
        stack.addView(body("These came from your Dock and your most recently used apps. "
                           + "Remove any you don't want, then add the rest later in Settings."),
                      in: .top)

        // Enforce the floor only if we're proposing at least minOuterApps apps.
        // A machine that turned up only one or two apps has nothing to enforce with.
        let proposalCount = proposal.count
        let enforceFloor = proposalCount >= Settings.minOuterApps
        for (index, path) in proposal.enumerated() {
            let canRemove = !enforceFloor || proposalCount - 1 >= Settings.minOuterApps
            stack.addView(row(path: path, index: index, canRemove: canRemove), in: .top)
        }

        let accept = NSButton(title: proposal.count == 1
                                ? "Use This App" : "Use These \(proposal.count) Apps",
                              target: self, action: #selector(acceptProposal))
        accept.bezelStyle = .rounded
        accept.keyEquivalent = "\r"
        stack.addView(accept, in: .top)

        let back = NSButton(title: "Back", target: self, action: #selector(goBack))
        back.bezelStyle = .rounded
        stack.addView(back, in: .top)
        show(stack)
    }

    private func row(path: String, index: Int, canRemove: Bool) -> NSView {
        let item = RingItem.make(path: path)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = item.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
        row.addView(icon, in: .leading)

        let number = NSTextField(labelWithString: "\(index + 1).")
        number.textColor = .secondaryLabelColor
        row.addView(number, in: .leading)

        let name = NSTextField(labelWithString: item.name)
        row.addView(name, in: .leading)

        let remove = NSButton(title: "Remove", target: self, action: #selector(removeProposed(_:)))
        remove.bezelStyle = .inline
        remove.controlSize = .small
        remove.tag = index
        remove.isEnabled = canRemove
        row.addView(remove, in: .trailing)
        return row
    }

    @objc private func removeProposed(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < proposal.count else { return }
        proposal.remove(at: sender.tag)
        guard !proposal.isEmpty else {
            showWelcome()
            return
        }
        // Rebuilt from scratch so the row tags match the new indices.
        showConfirmation()
    }

    @objc private func goBack() {
        showWelcome()
    }

    @objc private func acceptProposal() {
        // Paired with the slots captured when the proposal was computed, and
        // `assign` rather than `set` so nothing can be silently refused.
        for (position, path) in proposal.enumerated() where position < targetSlots.count {
            outer.assign(path, at: targetSlots[position])
        }
        // Give the inner ring history to work with straight away, so the wheel is
        // not half empty on first open.
        recents.seedFromSpotlight()
        finish()
    }

    /// Reached from the menu when the Dock and the recency list turn up nothing
    /// new — which is normal once the ring is mostly full. Saying so beats a
    /// window that vanishes on its own.
    private func showNothingFound(ringIsFull: Bool) {
        let stack = verticalStack()
        stack.addView(title(ringIsFull ? "Your ring is already full" : "Nothing new to add"),
                      in: .top)
        // The count is read rather than written, for the reason given in `showWelcome`:
        // telling a user with a six-slot ring that they have eight is a small lie that is
        // easy to leave behind. This line was doing exactly that.
        stack.addView(body(ringIsFull
            ? "All \(outer.visibleCount) slots hold an app. Open Settings to choose what "
              + "goes where, or drop an app on the menu-bar icon to take the first free slot."
            : "Everything in your Dock and your recent apps is already on the ring. Drop an "
              + "app on the menu-bar icon, or pick one in Settings, to add something else."),
                      in: .top)
        let done = NSButton(title: "Done", target: self, action: #selector(finishOnboarding))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        stack.addView(done, in: .top)
        show(stack)
    }

    @objc private func finishOnboarding() {
        finish()
    }

    // MARK: - Small view builders

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 24, right: 26)
        return stack
    }

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.alignment = .center
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func footnote(_ text: String) -> NSTextField {
        let label = body(text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }
}

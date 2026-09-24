import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// The login item, wrapped so the menu and the settings window say the same thing
/// and fail the same way.
enum LoginItem {
    /// What macOS reports, reduced to the four cases a checkbox has to show.
    ///
    /// `requiresApproval` is the case that matters: `register()` returns without
    /// throwing, but the item does not run until the user approves it in System
    /// Settings. Treating it as "off" — which is what comparing against `.enabled`
    /// alone does — makes the checkbox refuse to stay ticked with no explanation,
    /// forever, because every further click repeats the same successful
    /// registration.
    enum State {
        case on
        case off
        case needsApproval
        /// macOS cannot find a registerable app here, which is what happens when
        /// Chakra is run from a build folder rather than from Applications.
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .off
        }
    }

    /// Whether the checkbox should read as ticked. Awaiting approval counts: the
    /// user asked for it and Chakra did register it.
    static var isEnabled: Bool {
        let state = state
        return state == .on || state == .needsApproval
    }

    /// Returns the state after the attempt, so a checkbox that was refused can be
    /// put back rather than lying about what happened.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> State {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if state != .off {
                // Unregistering something that is already unregistered throws, and
                // the resulting alert would blame the wrong thing. This happens for
                // real: the user can switch Chakra off in System Settings while the
                // settings window is open and still showing the box ticked.
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = enabled
                ? "Could not open Chakra at login"
                : "Could not stop opening Chakra at login"
            var detail = error.localizedDescription
            // Only ever offered for the registration path, and only when macOS
            // actually reports that it cannot find a registerable app. Appending it
            // to every failure told the user the wrong thing about half the time.
            if enabled, state == .unavailable {
                detail += "\n\nmacOS could not find a registerable copy of Chakra. "
                    + "This usually means it is running from a build folder rather "
                    + "than from your Applications folder."
            }
            alert.informativeText = detail
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        return state
    }

    /// Opens the pane where a pending login item is approved.
    static func showSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// A button that captures one key combination.
///
/// The capture uses a *local* event monitor. A global monitor is what would make
/// macOS demand Accessibility access, and Chakra never asks for a permission —
/// while this button is armed the app is frontmost anyway, so local is enough.
final class ShortcutRecorder: NSButton {
    /// Key code, Carbon modifier mask, and how the key should be spelled.
    var onRecorded: ((Int, Int, String) -> Void)?
    /// Advice to show under the button, or nil to clear it.
    var onHint: ((String?) -> Void)?

    private var monitor: Any?
    private var restingTitle = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("Chakra builds its views in code") }

    var isRecording: Bool { monitor != nil }

    /// The shortcut to show while not recording.
    func show(_ text: String) {
        restingTitle = text
        if !isRecording { title = text }
    }

    @objc private func clicked() {
        if isRecording {
            stopRecording()
            onHint?(nil)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        title = "Type a shortcut…"
        onHint?("Hold ⌘, ⌥ or ⌃ and press a key. Esc cancels.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // A local monitor sees every key press delivered anywhere in the app,
            // not just the ones aimed at this button, and returning nil swallows
            // them. Without this check an armed recorder ate Escape on its way to
            // the wheel, and ⌘⇧G on its way to an open panel.
            guard let self, let window = self.window,
                  event.window === window else { return event }
            return self.handle(event) ? nil : event
        }
        // Anything that moves focus elsewhere — the wheel opening, an open panel,
        // another app coming forward — means the user is no longer typing a
        // shortcut. Scoped to this window: with a nil object it would disarm on any
        // window in the app losing focus.
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowLostFocus),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowLostFocus() {
        guard isRecording else { return }
        stopRecording()
        onHint?(nil)
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape),
           Shortcut.carbonModifiers(from: event.modifierFlags) == 0 {
            stopRecording()
            onHint?(nil)
            return true
        }
        let keyCode = Int(event.keyCode)
        let modifiers = Shortcut.carbonModifiers(from: event.modifierFlags)
        if let reason = Shortcut.unavailableReason(keyCode: keyCode, carbonModifiers: modifiers) {
            onHint?(reason + " Press Esc to stop.")
            return true
        }
        let label = Shortcut.keyLabel(for: event)
        stopRecording()
        onHint?(nil)
        onRecorded?(keyCode, modifiers, label)
        return true
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: nil)
        title = restingTitle
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A monitor left installed after the view went away would swallow every
        // key press in the app.
        if window == nil { stopRecording() }
    }

    deinit {
        // Belt and braces: a monitor outlives the object that installed it, so one
        // left behind here would swallow key presses for the rest of the session.
        if let monitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }
}

/// The settings window: which app sits in each slot, how big the wheel is, how
/// solid it looks, where it opens, and how it is opened.
///
/// Everything is applied the moment it is changed, and a wheel that is already on
/// screen is updated in place, so the window doubles as a preview.
final class SettingsController: NSObject, NSWindowDelegate {
    /// Fixed content width: the window is not resizable, so every row can be laid
    /// out against one number instead of chasing the clip view.
    private static let contentWidth: CGFloat = 452
    private static let labelWidth: CGFloat = 132

    private let outer: OuterRing
    private let settings: Settings
    private let wheel: WheelController

    /// The shortcut has to be re-registered when it changes, which only the app
    /// delegate can do.
    var onHotkeyChanged: (() -> Void)?
    /// Re-run first-launch setup.
    var onSetUpRing: (() -> Void)?

    private var window: NSWindow?
    private var slotIcons: [NSImageView] = []
    private var slotNames: [NSTextField] = []
    private var slotClears: [NSButton] = []
    /// One row per stored slot; the rows past the chosen count are hidden.
    private var slotRows: [NSView] = []
    private var clearOthersButton: NSButton?
    private var outerCountSlider: NSSlider?
    private var outerCountValue: NSTextField?
    private var outerCountNote: NSTextField?
    private var slotCountNoteWork: DispatchWorkItem?
    private var innerCountSlider: NSSlider?
    private var innerCountValue: NSTextField?
    private var scrollToSpinBox: NSButton?
    private var spinOnOpenBox: NSButton?
    private var resetRotationButton: NSButton?

    // Every control whose displayed value comes from a setting is held onto, so
    // `refreshEverything` can put all of them back in step. Keeping only the
    // read-out labels was not enough: the knob and the percentage beside it could
    // disagree, and each of these settings has a second way in.
    private var sizeSlider: NSSlider?
    private var sizeValue: NSTextField?
    private var opacitySlider: NSSlider?
    private var opacityValue: NSTextField?
    private var tintPopUp: NSPopUpButton?
    private var colorfulBox: NSButton?
    private var forgetButton: NSButton?
    private var locationPopUp: NSPopUpButton?
    private var recorder: ShortcutRecorder?
    private var hotkeyNote: NSTextField?
    private var hotkeyEnabledBox: NSButton?
    private var loginBox: NSButton?
    private var loginNote: NSTextField?
    private var dockBox: NSButton?

    private var orbBox: NSButton?
    private var orbSizeSlider: NSSlider?
    private var orbSizeValue: NSTextField?
    private var orbDimSlider: NSSlider?
    private var orbDimValue: NSTextField?
    private var orbTuckBox: NSButton?
    private var orbCaptureBox: NSButton?
    private var orbRecentreButton: NSButton?

    /// The app delegate owns the orb, so putting it back in the middle has to be
    /// asked for rather than done here.
    var onRecentreOrb: (() -> Void)?

    /// True while this window is applying a change of its own.
    ///
    /// `postDidChange()` is how the app delegate hears about a setting, so the window
    /// has to post; but it also observes that notification, and answering its own post
    /// with a full refresh resets the control the user is still dragging.
    private var isApplyingOwnChange = false

    /// Incremented every time refreshEverything runs. Exposed for testing the
    /// re-entrancy guard: without it a continuous slider would trigger a refresh
    /// on every tick of a drag.
    private(set) var refreshCountForTesting = 0

    /// Why the shortcut is not working, or nil when it is.
    private var hotkeyFailure: HotKey.Failure?

    init(outer: OuterRing, settings: Settings, wheel: WheelController) {
        self.outer = outer
        self.settings = settings
        self.wheel = wheel
        super.init()
        // The ring can also be changed from the wheel itself or by a drop on the
        // menu-bar icon while this window is open.
        NotificationCenter.default.addObserver(
            self, selector: #selector(ringChanged),
            name: OuterRing.didChangeNotification, object: nil)
        // And so can several of the settings: the Dock icon from the menu-bar menu,
        // where the wheel opens by dragging the wheel itself.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChangedElsewhere),
            name: Settings.didChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// `isVisible` is false for a miniaturised window, so a window in the Dock is
    /// refreshed when it comes back rather than being skipped here and left stale.
    private var needsRefreshOnReturn = false

    @objc private func ringChanged() {
        guard window != nil else { return }
        guard window?.isVisible == true else { needsRefreshOnReturn = true; return }
        refreshSlots()
    }

    @objc private func settingsChangedElsewhere() {
        guard !isApplyingOwnChange else { return }
        guard window != nil else { return }
        guard window?.isVisible == true else { needsRefreshOnReturn = true; return }
        refreshEverything()
    }

    /// Stores a setting, tells the rest of the app, and does not let the answer come
    /// back round to this window.
    private func applyingOwnChange(_ body: () -> Void) {
        // Saved and restored rather than set true then false. `postDidChange` is
        // synchronous, so a nested call would otherwise clear the flag on its way out and
        // the *outer* post would then be read as coming from elsewhere — triggering the
        // full refresh that resets the control the user is still dragging, which is the
        // exact bug this flag exists to prevent. Nothing nests today; the shelf is about
        // to add more settings paths through here, and a guard that fails this way is not
        // worth leaving armed.
        let wasApplyingOwnChange = isApplyingOwnChange
        isApplyingOwnChange = true
        defer { isApplyingOwnChange = wasApplyingOwnChange }
        body()
        settings.postDidChange()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard needsRefreshOnReturn else { return }
        needsRefreshOnReturn = false
        refreshEverything()
    }

    // MARK: - Presentation

    func show() {
        let window = ensureWindow()
        refreshEverything()
        needsRefreshOnReturn = false
        // A miniaturised window ignores `makeKeyAndOrderFront`, so without this the
        // second Settings… after minimising the window did nothing at all — and with
        // no Dock icon in the default configuration there was no other way back to
        // it.
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Not the cooperative `activate()`: from an accessory app that is not
        // frontmost it is refused, and the window would open without focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Called after the app delegate has tried to claim the shortcut, so the note
    /// under the recorder can tell the truth about it.
    func hotkeyStateChanged(failure: HotKey.Failure?) {
        hotkeyFailure = failure
        refreshHotkeySection()
    }

    func windowWillClose(_ notification: Notification) {
        // A recorder left armed would keep swallowing key presses.
        recorder?.stopRecording()
    }

    /// Room for a scroller that is always shown.
    ///
    /// With "Show scroll bars: Always" in System Settings the vertical scroller is
    /// laid out inside the clip view instead of floating over it. The stack is
    /// pinned to both edges of the clip view and needs its full width, so without
    /// this allowance that width no longer fits: an unsatisfiable constraint, and
    /// the Choose… and Clear buttons clipped off the right-hand edge.
    private static var scrollerAllowance: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    private var windowWidth: CGFloat { Self.contentWidth + 44 + Self.scrollerAllowance }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 620),
                               styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: false)
        created.title = "Chakra Settings"
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.contentView = buildContent()

        // Never taller than the screen it opens on; the scroll view takes care of
        // the rest.
        let screenHeight = (created.screen ?? NSScreen.main)?.visibleFrame.height ?? 620
        created.setContentSize(NSSize(width: windowWidth,
                                      height: min(620, screenHeight - 40)))
        created.center()
        window = created
        return created
    }

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 24, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        buildAppsSection(into: stack)
        buildRecentsSection(into: stack)
        buildRotationSection(into: stack)
        buildOrbSection(into: stack)
        buildSizeSection(into: stack)
        buildAppearanceSection(into: stack)
        buildOpeningSection(into: stack)
        buildShortcutSection(into: stack)
        buildGeneralSection(into: stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        return scroll
    }

    // MARK: - Apps

    private func buildAppsSection(into stack: NSStackView) {
        stack.addView(header("Apps on the outer ring"), in: .top)
        stack.addView(note("The positions never move, so a direction always means the same "
                           + "app. Turning the count down hides the last slots rather than "
                           + "emptying them, so turning it back up brings the same apps back."),
                      in: .top)

        let outerValue = NSTextField(labelWithString: "")
        outerValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        outerValue.textColor = .secondaryLabelColor
        outerValue.alignment = .right
        outerCountValue = outerValue

        let outerSlider = NSSlider(value: Double(settings.outerSlotCount),
                                   minValue: Double(Settings.minOuterSlots),
                                   maxValue: Double(Settings.maxOuterSlots),
                                   target: self, action: #selector(outerCountChanged(_:)))
        // Whole slots only: a ring cannot be divided into eight and a half.
        outerSlider.numberOfTickMarks = Settings.maxOuterSlots - Settings.minOuterSlots + 1
        outerSlider.allowsTickMarkValuesOnly = true
        outerCountSlider = outerSlider
        stack.addView(sliderRow("How many apps", slider: outerSlider, value: outerValue),
                      in: .top)

        let outerNote = note("")
        outerCountNote = outerNote
        stack.addView(outerNote, in: .top)

        // Every stored slot gets a row; the ones past the chosen count are hidden
        // rather than left out, so the rows and the stored slots keep the same
        // indices and no bookkeeping has to be rebuilt when the count changes.
        for index in 0..<OuterRing.capacity {
            let row = slotRow(index)
            slotRows.append(row)
            stack.addView(row, in: .top)
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addView(button("Fill from My Dock", #selector(fillFromDock)), in: .leading)
        buttons.addView(button("Set Up Ring…", #selector(setUpRing)), in: .leading)
        let clearOthers = button("Clear the Others", #selector(clearOthers))
        clearOthersButton = clearOthers
        buttons.addView(clearOthers, in: .leading)
        stack.addView(buttons, in: .top)
        stack.addView(note("Empties every slot except the first \(Settings.minOuterApps) "
                           + "apps, which move to the top of the ring. The ring keeps at "
                           + "least \(Settings.minOuterApps) apps, so there is always "
                           + "something to flick to."), in: .top)
        stack.addView(separator(), in: .top)
    }

    private func slotRow(_ index: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let number = NSTextField(labelWithString: "\(index + 1)")
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.textColor = .secondaryLabelColor
        number.alignment = .right
        number.translatesAutoresizingMaskIntoConstraints = false
        number.widthAnchor.constraint(equalToConstant: 16).isActive = true
        row.addView(number, in: .leading)

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.addView(icon, in: .leading)
        slotIcons.append(icon)

        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 232).isActive = true
        row.addView(name, in: .leading)
        slotNames.append(name)

        let choose = button("Choose…", #selector(chooseSlot(_:)))
        choose.tag = index
        choose.controlSize = .small
        row.addView(choose, in: .trailing)

        let clear = button("Clear", #selector(clearSlot(_:)))
        clear.tag = index
        clear.controlSize = .small
        row.addView(clear, in: .trailing)
        slotClears.append(clear)
        return row
    }

    private func refreshSlots() {
        let visible = outer.visibleCount
        for index in 0..<OuterRing.capacity {
            guard index < slotIcons.count else { break }
            // A row past the chosen count is hidden, not removed: the apps in those
            // slots are still stored, and turning the count back up shows them again.
            if index < slotRows.count {
                let row = slotRows[index]
                row.isHidden = index >= visible
                if let stack = row.superview as? NSStackView {
                    stack.setVisibilityPriority(index < visible ? .mustHold : .notVisible,
                                                for: row)
                }
            }
            let item = outer.item(at: index)
            slotIcons[index].image = item?.icon
            slotIcons[index].alphaValue = item?.isMissing == true ? 0.4 : 1
            // Greyed out at the floor rather than refusing on click, so the limit is
            // visible before the user tries.
            slotClears[index].isEnabled = item != nil && outer.canRemove(at: index)
            let name = slotNames[index]
            if let item {
                name.stringValue = item.isMissing ? "\(item.name) — missing" : item.name
                name.textColor = item.isMissing ? .systemRed : .labelColor
            } else {
                name.stringValue = "Empty"
                name.textColor = .tertiaryLabelColor
            }
        }
        clearOthersButton?.isEnabled = outer.occupiedCount > Settings.minOuterApps
    }

    @objc private func outerCountChanged(_ sender: NSSlider) {
        let wanted = Int(sender.doubleValue.rounded())
        guard outer.canSetVisibleCount(to: wanted) else {
            // Snapped back rather than left where the user dragged it, so the slider
            // never shows a count that is not in force.
            //
            // The refused value is handed to the note explicitly. Reading it back off the
            // slider afterwards was a real defect: the line above has already reset the
            // slider, so the note described the count still in force rather than the one
            // being refused. Dragging 8 down to 4 produced "Turning it down to 8 would
            // leave you with 3 apps. The ring keeps at least 3." — the wrong number, and
            // a comparison that reads as no violation at all.
            sender.doubleValue = Double(settings.outerSlotCount)
            flashSlotCountNote(refused: wanted)
            return
        }
        settings.outerSlotCount = wanted
        outerCountValue?.stringValue = "\(settings.outerSlotCount)"
        // The warning described a refusal that no longer applies.
        clearSlotCountNote()
        refreshSlots()
        wheel.settingsDidChange()
    }

    @objc private func innerCountChanged(_ sender: NSSlider) {
        settings.innerSlotCount = Int(sender.doubleValue.rounded())
        innerCountValue?.stringValue = settings.innerSlotCount == 0
            ? "off"
            : "\(settings.innerSlotCount)"
        wheel.settingsDidChange()
    }

    @objc private func chooseSlot(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < OuterRing.capacity else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose the app for position \(index + 1)"
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        // `assign` rather than `set`: picking an app that is already on the ring
        // means "move it here", and refusing the choice would be baffling when the
        // user is looking at every slot at once.
        outer.assign(url.path, at: index)
        applied()
    }

    @objc private func clearSlot(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < OuterRing.capacity else { return }
        // The button is greyed at the floor, so this is only reached by a route that
        // bypassed it — a key equivalent, or an accessibility client.
        guard outer.remove(at: sender.tag) else {
            presentFloorNote()
            return
        }
        applied()
    }

    @objc private func fillFromDock() {
        let dock = RingProposal.compute(dock: RingProposal.dockApps(),
                                        spotlight: Recents.spotlightRanking(limit: 40),
                                        pinned: [],
                                        selfPath: Bundle.main.bundleURL.path,
                                        freeSlots: outer.visibleCount)
        guard !dock.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to fill from"
            alert.informativeText = "Chakra could not read your Dock, and your recently used "
                + "apps turned up nothing. Use Choose… to pick apps by hand."
            alert.alertStyle = .informational
            NSApp.activate()
            alert.runModal()
            return
        }
        // Replaces the ring wholesale, which is what "fill from my Dock" says, so
        // it is worth asking first.
        let alert = NSAlert()
        // Counted from the ring, for the reason stated under "Empty the other slots?"
        // below: the number of slots is a setting, and this line said "eight" whatever
        // the user had chosen.
        alert.messageText = "Replace all \(outer.visibleCount) slots?"
        alert.informativeText = "Chakra will use the first \(dock.count) "
            + (dock.count == 1 ? "app" : "apps") + " from your Dock and recent apps."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        outer.replaceAll(dock)
        applied()
    }

    /// Empties every visible slot except the apps the floor requires, keeping the
    /// lowest-numbered ones — the slots nearest twelve o'clock, which is where a user
    /// who is starting over would expect to keep working.
    ///
    /// Built as a list and handed to `replaceAll` rather than removed slot by slot.
    /// `remove(at:)` consults the floor against the count as it shrinks, so the last
    /// removals would be refused half way through; and `set("", at:)` cannot clear a
    /// slot at all, because `canonical("")` is empty and `set` refuses an empty path.
    /// `replaceAll` is "the ring is now exactly this list", which is what this is.
    @objc private func clearOthers() {
        let kept = Array(outer.visibleRange
            .map { outer.slots[$0] }
            .filter { !$0.isEmpty }
            .prefix(Settings.minOuterApps))

        let alert = NSAlert()
        alert.messageText = "Empty the other slots?"
        // Counted from the ring rather than spelled out: the number of slots is a
        // setting now, and the old copy said "eight" whatever the user had chosen.
        alert.informativeText = "Chakra will keep \(kept.count) "
            + (kept.count == 1 ? "app" : "apps")
            + " and move them to the top of the ring. Your recently used apps in the "
            + "inner ring are not affected."
        alert.addButton(withTitle: "Empty the Others")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        outer.replaceAll(kept)
        applied()
    }

    @objc private func setUpRing() {
        onSetUpRing?()
    }

    // MARK: - Size

    // MARK: - Recents ring

    private func buildRecentsSection(into stack: NSStackView) {
        stack.addView(header("Apps on the inner ring"), in: .top)

        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        innerCountValue = value

        let slider = NSSlider(value: Double(settings.innerSlotCount),
                              minValue: Double(Settings.minInnerSlots),
                              maxValue: Double(Settings.maxInnerSlots),
                              target: self, action: #selector(innerCountChanged(_:)))
        slider.numberOfTickMarks = Settings.maxInnerSlots - Settings.minInnerSlots + 1
        slider.allowsTickMarkValuesOnly = true
        innerCountSlider = slider
        stack.addView(sliderRow("How many apps", slider: slider, value: value), in: .top)
        stack.addView(note("The inner ring fills itself with the apps you used most "
                           + "recently, skipping anything already on the outer ring. Set it "
                           + "to zero to switch it off and leave the middle empty."), in: .top)
        stack.addView(separator(), in: .top)
    }

    // MARK: - Rotation

    private func buildRotationSection(into stack: NSStackView) {
        stack.addView(header("Turning"), in: .top)

        let scroll = NSButton(checkboxWithTitle: "Scroll over a ring to turn it",
                              target: self, action: #selector(scrollToSpinChanged(_:)))
        scroll.state = settings.scrollToSpin ? .on : .off
        scrollToSpinBox = scroll
        stack.addView(indented(scroll), in: .top)

        let spin = NSButton(checkboxWithTitle: "Sweep into place when the wheel opens",
                            target: self, action: #selector(spinOnOpenChanged(_:)))
        spin.state = settings.spinOnOpen ? .on : .off
        spinOnOpenBox = spin
        stack.addView(indented(spin), in: .top)

        let reset = button("Straighten the Rings", #selector(resetRotation))
        resetRotationButton = reset
        stack.addView(indented(reset), in: .top)

        stack.addView(note("Turning a ring changes which app is at the top; it does not "
                           + "change the order, so a direction still always means the same "
                           + "app relative to its neighbours. Where you leave it is where it "
                           + "opens next time."), in: .top)
        stack.addView(separator(), in: .top)
    }

    @objc private func scrollToSpinChanged(_ sender: NSButton) {
        settings.scrollToSpin = sender.state == .on
        wheel.settingsDidChange()
    }

    @objc private func spinOnOpenChanged(_ sender: NSButton) {
        settings.spinOnOpen = sender.state == .on
        wheel.settingsDidChange()
    }

    @objc private func resetRotation() {
        settings.outerRotationSteps = 0
        settings.innerRotationSteps = 0
        refreshRotationSection()
        wheel.settingsDidChange()
    }

    private func refreshRotationSection() {
        scrollToSpinBox?.state = settings.scrollToSpin ? .on : .off
        spinOnOpenBox?.state = settings.spinOnOpen ? .on : .off
        // Nothing to straighten when both rings are already at rest.
        resetRotationButton?.isEnabled =
            settings.outerRotationSteps != 0 || settings.innerRotationSteps != 0
    }

    // MARK: - Orb

    private func buildOrbSection(into stack: NSStackView) {
        stack.addView(header("Floating orb"), in: .top)

        let show = NSButton(checkboxWithTitle: "Show the orb on screen",
                            target: self, action: #selector(showOrbChanged(_:)))
        show.state = settings.showOrb ? .on : .off
        orbBox = show
        stack.addView(indented(show), in: .top)

        let sizeValue = NSTextField(labelWithString: "")
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeValue.textColor = .secondaryLabelColor
        sizeValue.alignment = .right
        orbSizeValue = sizeValue

        let sizeSlider = NSSlider(value: settings.orbSize,
                                  minValue: Double(OrbGeometry.minSize),
                                  maxValue: Double(OrbGeometry.maxSize),
                                  target: self, action: #selector(orbSizeChanged(_:)))
        orbSizeSlider = sizeSlider
        stack.addView(sliderRow("Size", slider: sizeSlider, value: sizeValue), in: .top)

        let dimValue = NSTextField(labelWithString: "")
        dimValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimValue.textColor = .secondaryLabelColor
        dimValue.alignment = .right
        orbDimValue = dimValue

        let dimSlider = NSSlider(value: settings.orbIdleOpacity,
                                 minValue: Settings.minOrbOpacity, maxValue: 1,
                                 target: self, action: #selector(orbDimChanged(_:)))
        orbDimSlider = dimSlider
        stack.addView(sliderRow("Dim when idle", slider: dimSlider, value: dimValue), in: .top)

        let tuck = NSButton(checkboxWithTitle: "Tuck into the screen edge when idle",
                            target: self, action: #selector(orbTuckChanged(_:)))
        tuck.state = settings.orbTucksAtEdge ? .on : .off
        orbTuckBox = tuck
        stack.addView(indented(tuck), in: .top)

        let capture = NSButton(checkboxWithTitle: "Hide the orb from screen recordings",
                               target: self, action: #selector(orbCaptureChanged(_:)))
        capture.state = settings.orbHiddenFromCapture ? .on : .off
        orbCaptureBox = capture
        stack.addView(indented(capture), in: .top)

        let recentre = button("Put the Orb Back in the Middle", #selector(recentreOrb))
        orbRecentreButton = recentre
        stack.addView(indented(recentre), in: .top)

        stack.addView(note("The orb floats above your other windows and opens the wheel "
                           + "when you click it. Drag it anywhere; it stays there. Hiding it "
                           + "from recordings also keeps it out of your own screenshots."),
                      in: .top)
        stack.addView(separator(), in: .top)
    }

    @objc private func showOrbChanged(_ sender: NSButton) {
        applyingOwnChange {
            settings.showOrb = sender.state == .on
        }
        refreshOrbSection()
    }

    @objc private func orbSizeChanged(_ sender: NSSlider) {
        applyingOwnChange {
            settings.orbSize = sender.doubleValue
            orbSizeValue?.stringValue = "\(Int(settings.orbSize.rounded()))pt"
        }
    }

    @objc private func orbDimChanged(_ sender: NSSlider) {
        applyingOwnChange {
            settings.orbIdleOpacity = sender.doubleValue
            orbDimValue?.stringValue = Self.percent(settings.orbIdleOpacity)
        }
    }

    @objc private func orbTuckChanged(_ sender: NSButton) {
        applyingOwnChange {
            settings.orbTucksAtEdge = sender.state == .on
        }
    }

    @objc private func orbCaptureChanged(_ sender: NSButton) {
        applyingOwnChange {
            settings.orbHiddenFromCapture = sender.state == .on
        }
    }

    @objc private func recentreOrb() {
        onRecentreOrb?()
    }

    private func refreshOrbSection() {
        let on = settings.showOrb
        orbBox?.state = on ? .on : .off
        orbSizeSlider?.doubleValue = settings.orbSize
        orbSizeValue?.stringValue = "\(Int(settings.orbSize.rounded()))pt"
        orbDimSlider?.doubleValue = settings.orbIdleOpacity
        orbDimValue?.stringValue = Self.percent(settings.orbIdleOpacity)
        orbTuckBox?.state = settings.orbTucksAtEdge ? .on : .off
        orbCaptureBox?.state = settings.orbHiddenFromCapture ? .on : .off
        // Every control below the switch is meaningless with no orb on screen.
        for control in [orbSizeSlider, orbDimSlider] { control?.isEnabled = on }
        for control in [orbTuckBox, orbCaptureBox] { control?.isEnabled = on }
        // The recentre button needs a saved position to forget, and the orb must be on.
        orbRecentreButton?.isEnabled = on && settings.orbFraction != nil
    }

    // MARK: - Size

    private func buildSizeSection(into stack: NSStackView) {
        stack.addView(header("Size"), in: .top)

        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        sizeValue = value

        let slider = NSSlider(value: settings.wheelSize,
                              minValue: Settings.minWheelSize,
                              maxValue: Settings.maxWheelSize,
                              target: self, action: #selector(sizeChanged(_:)))
        sizeSlider = slider
        stack.addView(sliderRow("Wheel size", slider: slider, value: value), in: .top)
        stack.addView(note("One size for the whole wheel: the inner circle, the outer circle "
                           + "and the icons scale together. A wheel too big for the screen is "
                           + "shrunk to fit."), in: .top)
        stack.addView(separator(), in: .top)
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        settings.wheelSize = sender.doubleValue
        sizeValue?.stringValue = Self.percent(settings.wheelSize)
        wheel.settingsDidChange()
    }

    // MARK: - Appearance

    private func buildAppearanceSection(into stack: NSStackView) {
        stack.addView(header("Background"), in: .top)

        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        opacityValue = value

        let slider = NSSlider(value: settings.glassOpacity, minValue: 0, maxValue: 1,
                              target: self, action: #selector(opacityChanged(_:)))
        opacitySlider = slider
        stack.addView(sliderRow("Frosted glass", slider: slider, value: value), in: .top)

        let tint = NSPopUpButton(frame: .zero, pullsDown: false)
        tint.addItems(withTitles: GlassTint.allCases.map(\.label))
        tint.selectItem(at: GlassTint.allCases.firstIndex(of: settings.glassTint) ?? 0)
        tint.target = self
        tint.action = #selector(tintChanged(_:))
        tintPopUp = tint
        stack.addView(controlRow("Colour", control: tint, width: 180), in: .top)

        let colorful = NSButton(checkboxWithTitle: "Highlight with each app's own colour",
                                target: self, action: #selector(colorfulChanged(_:)))
        colorful.state = settings.colorfulHighlights ? .on : .off
        colorfulBox = colorful
        stack.addView(indented(colorful), in: .top)
        stack.addView(note("At 0% there is no glass at all — the icons float on your desktop. "
                           + "Turn the colour highlight off to use your system accent colour "
                           + "instead."), in: .top)
        stack.addView(separator(), in: .top)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        settings.glassOpacity = sender.doubleValue
        opacityValue?.stringValue = Self.percent(settings.glassOpacity)
        wheel.settingsDidChange()
    }

    @objc private func tintChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < GlassTint.allCases.count else { return }
        settings.glassTint = GlassTint.allCases[index]
        wheel.settingsDidChange()
    }

    @objc private func colorfulChanged(_ sender: NSButton) {
        settings.colorfulHighlights = sender.state == .on
        wheel.settingsDidChange()
    }

    // MARK: - Opening

    private func buildOpeningSection(into stack: NSStackView) {
        stack.addView(header("Where it opens"), in: .top)

        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: OpenLocation.allCases.map(\.label))
        popUp.selectItem(at: OpenLocation.allCases.firstIndex(of: settings.openLocation) ?? 0)
        popUp.target = self
        popUp.action = #selector(locationChanged(_:))
        locationPopUp = popUp
        stack.addView(controlRow("Open the wheel", control: popUp, width: 260), in: .top)

        let forget = button("Forget Saved Position", #selector(forgetPosition))
        forgetButton = forget
        stack.addView(indented(forget), in: .top)
        stack.addView(note("Drag the middle of the wheel to move it. Wherever you drop it "
                           + "becomes the position it opens at next time."), in: .top)
        stack.addView(separator(), in: .top)
    }

    @objc private func locationChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < OpenLocation.allCases.count else { return }
        settings.openLocation = OpenLocation.allCases[index]
        refreshOpening()
    }

    @objc private func forgetPosition() {
        settings.savedCenterFraction = nil
        // Nothing to fall back on any more, so the setting has to move to the
        // actual default, or "the position I dragged it to" would quietly mean
        // something the user never chose.
        if settings.openLocation == .saved { settings.openLocation = .center }
        refreshOpening()
    }

    private func refreshOpening() {
        locationPopUp?.selectItem(at: OpenLocation.allCases
            .firstIndex(of: settings.openLocation) ?? 0)
        forgetButton?.isEnabled = settings.savedCenterFraction != nil
    }

    // MARK: - Shortcut

    private func buildShortcutSection(into stack: NSStackView) {
        stack.addView(header("Keyboard shortcut"), in: .top)

        let box = NSButton(checkboxWithTitle: "Open Chakra with a keyboard shortcut",
                           target: self, action: #selector(hotkeyEnabledChanged(_:)))
        box.state = settings.hotkeyEnabled ? .on : .off
        hotkeyEnabledBox = box
        stack.addView(indented(box), in: .top)

        let recorder = ShortcutRecorder(frame: .zero)
        recorder.show(settings.hotkeyDisplay)
        recorder.onRecorded = { [weak self] keyCode, modifiers, label in
            self?.recorded(keyCode: keyCode, modifiers: modifiers, label: label)
        }
        recorder.onHint = { [weak self] hint in
            guard let self else { return }
            if let hint {
                self.hotkeyNote?.stringValue = hint
                self.hotkeyNote?.textColor = .secondaryLabelColor
            } else {
                self.refreshHotkeySection()
            }
        }
        self.recorder = recorder
        stack.addView(controlRow("Shortcut", control: recorder, width: 150), in: .top)

        let hotkeyNote = note("")
        self.hotkeyNote = hotkeyNote
        stack.addView(hotkeyNote, in: .top)
        stack.addView(separator(), in: .top)
    }

    private func recorded(keyCode: Int, modifiers: Int, label: String) {
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        settings.hotkeyLabel = label
        // Recording a shortcut is also a request to use it.
        settings.hotkeyEnabled = true
        hotkeyEnabledBox?.state = .on
        recorder?.show(settings.hotkeyDisplay)
        // The delegate re-registers and reports back whether it worked, which is
        // what fills in the note below the button.
        onHotkeyChanged?()
    }

    @objc private func hotkeyEnabledChanged(_ sender: NSButton) {
        settings.hotkeyEnabled = sender.state == .on
        onHotkeyChanged?()
    }

    private func refreshHotkeySection() {
        recorder?.show(settings.hotkeyDisplay)
        hotkeyEnabledBox?.state = settings.hotkeyEnabled ? .on : .off
        // The button stays clickable even when the shortcut could not be claimed:
        // picking a different combination is exactly how that is recovered from.
        recorder?.isEnabled = true
        guard let note = hotkeyNote else { return }
        switch (settings.hotkeyEnabled, hotkeyFailure) {
        case (false, _):
            note.stringValue = "The menu-bar icon still opens the wheel."
            note.textColor = .secondaryLabelColor
        case (true, nil):
            note.stringValue = "\(settings.hotkeyDisplay) opens and closes the wheel."
            note.textColor = .secondaryLabelColor
        case (true, .combinationTaken):
            note.stringValue = "\(settings.hotkeyDisplay) is already in use by another app — "
                + "click the button and type a different one."
            note.textColor = .systemRed
        case (true, .cannotListen):
            // Distinct from the case above on purpose: no other combination would
            // work either, so telling the user to pick one would be a loop with no
            // way out.
            note.stringValue = "Chakra could not listen for keyboard shortcuts on this Mac. "
                + "Use the menu-bar icon instead, or quit and open Chakra again."
            note.textColor = .systemRed
        }
    }

    // MARK: - General

    private func buildGeneralSection(into stack: NSStackView) {
        stack.addView(header("General"), in: .top)

        let dock = NSButton(checkboxWithTitle: "Show Chakra in the Dock",
                            target: self, action: #selector(showInDockChanged(_:)))
        dock.state = settings.showInDock ? .on : .off
        dockBox = dock
        stack.addView(indented(dock), in: .top)

        let login = NSButton(checkboxWithTitle: "Open Chakra at login",
                             target: self, action: #selector(loginChanged(_:)))
        login.state = LoginItem.isEnabled ? .on : .off
        loginBox = login
        stack.addView(indented(login), in: .top)

        let loginNote = note("")
        self.loginNote = loginNote
        stack.addView(loginNote, in: .top)

        stack.addView(note("Chakra normally lives only in the menu bar. You can also drag "
                           + "Chakra from your Applications folder onto the Dock to keep it "
                           + "there — clicking it opens the wheel."), in: .top)
    }

    @objc private func showInDockChanged(_ sender: NSButton) {
        // Through `DockPresence` rather than open-coded: it is the one place that
        // keeps the stored value, the activation policy and the other control in
        // step, and it checks whether macOS actually accepted the change.
        let actual = DockPresence.set(sender.state == .on, in: settings)
        sender.state = actual ? .on : .off
    }

    @objc private func loginChanged(_ sender: NSButton) {
        LoginItem.setEnabled(sender.state == .on)
        // Read back rather than trusting the click: registering can succeed and
        // still leave the item waiting for the user's approval, which counts as on.
        refreshLoginSection()
    }

    private func refreshLoginSection() {
        let state = LoginItem.state
        loginBox?.state = LoginItem.isEnabled ? .on : .off
        guard let note = loginNote else { return }
        switch state {
        case .needsApproval:
            // The one case that used to look like a bug: the box refused to stay
            // ticked because macOS reports "registered, awaiting approval" and only
            // `.enabled` was treated as on.
            note.stringValue = "Waiting for your approval in System Settings › "
                + "General › Login Items."
            note.textColor = .systemOrange
        case .unavailable:
            note.stringValue = "macOS cannot register this copy of Chakra. Move it to your "
                + "Applications folder and try again."
            note.textColor = .systemRed
        case .on, .off:
            note.stringValue = ""
            note.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Shared refresh

    /// Applies a change to the ring: the settings rows, and any wheel on screen.
    private func applied() {
        refreshSlots()
        wheel.settingsDidChange()
    }

    /// Puts every control back in step with what is actually stored.
    ///
    /// The knobs themselves are set here, not just the labels beside them. Setting
    /// only the read-out meant a slider could show one value while the percentage
    /// next to it showed another, and the popups and checkboxes kept whatever they
    /// were built with even after the same setting had been changed elsewhere.
    private func refreshEverything() {
        refreshCountForTesting += 1
        // Putting every control back in step has to include the transient warnings, or a
        // refusal from an earlier visit reappears attached to state that has changed.
        clearSlotCountNote()
        refreshSlots()
        refreshOpening()
        refreshHotkeySection()
        refreshLoginSection()
        refreshRotationSection()
        refreshOrbSection()

        outerCountSlider?.doubleValue = Double(settings.outerSlotCount)
        outerCountValue?.stringValue = "\(settings.outerSlotCount)"
        innerCountSlider?.doubleValue = Double(settings.innerSlotCount)
        innerCountValue?.stringValue = settings.innerSlotCount == 0
            ? "off"
            : "\(settings.innerSlotCount)"
        sizeSlider?.doubleValue = settings.wheelSize
        sizeValue?.stringValue = Self.percent(settings.wheelSize)
        opacitySlider?.doubleValue = settings.glassOpacity
        opacityValue?.stringValue = Self.percent(settings.glassOpacity)
        tintPopUp?.selectItem(at: GlassTint.allCases.firstIndex(of: settings.glassTint) ?? 0)
        colorfulBox?.state = settings.colorfulHighlights ? .on : .off
        dockBox?.state = settings.showInDock ? .on : .off
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - Small view builders

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = Self.contentWidth
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return label
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let created = NSButton(title: title, target: self, action: selector)
        created.bezelStyle = .rounded
        return created
    }

    /// Explains the three-app floor, in the note under the slot-count slider.
    ///
    /// A label rather than an alert, for the same reason the slot-count refusal uses one,
    /// and for one more: `runModal` blocks until somebody clicks, so an alert on a path
    /// that automated runs exercise stops the smoke suite dead rather than failing it.
    /// Putting `clearSlot:` on the smoke tool's modal skip list instead would have left
    /// this refusal untested for good.
    ///
    /// Only ever reached by a route that bypassed the greyed-out Clear button — a key
    /// equivalent, or an accessibility client — since the button is disabled at the floor.
    private func presentFloorNote() {
        guard let note = outerCountNote else { return }
        note.stringValue = "The ring keeps at least \(Settings.minOuterApps) apps. "
            + "Use Choose… to replace this one instead."
        note.textColor = .systemOrange
    }

    /// Shown under the slot-count slider when a narrower ring is refused. A label
    /// rather than an alert: this fires while the user is dragging, and a modal in the
    /// middle of a drag would be intolerable.
    ///
    /// `refused` is the count the user asked for, passed in rather than read back off the
    /// slider — by the time this runs the slider has already been snapped back, so reading
    /// it described the wrong number twice over.
    private func flashSlotCountNote(refused: Int) {
        guard let note = outerCountNote else { return }
        // Mirrors `canSetVisibleCount`: how many apps would still be reachable at the
        // count that was refused.
        let clamped = min(max(refused, Settings.minOuterSlots), Settings.maxOuterSlots)
        let reachable = (0..<min(clamped, outer.slots.count)).filter { !outer.slots[$0].isEmpty }.count
        note.stringValue = "Turning it down to \(clamped) would leave you with "
            + "\(reachable) \(reachable == 1 ? "app" : "apps"). The ring keeps at least "
            + "\(Settings.minOuterApps)."
        note.textColor = .systemOrange
    }

    /// Clears whichever warning is under the slot-count slider.
    ///
    /// Nothing used to clear it: not a later successful change, not `refreshEverything`,
    /// and not closing the window, since the controller caches it and the window is not
    /// released. An orange refusal therefore sat there for the rest of the process,
    /// describing a state that had long since stopped being true.
    private func clearSlotCountNote() {
        guard let note = outerCountNote else { return }
        note.stringValue = ""
        note.textColor = .secondaryLabelColor
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return box
    }

    /// A control preceded by a label, so the section reads as a form.
    private func controlRow(_ title: String, control: NSView, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        row.addView(label, in: .leading)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.addView(control, in: .leading)
        return row
    }

    private func sliderRow(_ title: String, slider: NSSlider, value: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        row.addView(label, in: .leading)

        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        row.addView(slider, in: .leading)

        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 46).isActive = true
        row.addView(value, in: .leading)
        return row
    }

    /// Lines a checkbox or a lone button up with the labelled controls above it.
    private func indented(_ view: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
        row.addView(spacer, in: .leading)
        row.addView(view, in: .leading)
        return row
    }
}

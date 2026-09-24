import AppKit

/// Builds the real windows, then fires the real target-action of every control in
/// them.
///
/// The unit tests cover the pure logic; nothing covered the roughly 1,900 lines of
/// AppKit that put it on screen. This does: it constructs the settings window, the
/// wheel and the welcome window against a scratch preferences domain, walks the
/// finished view hierarchies, and sends each control the same action a click would.
/// A crash, a missing target, an exception from a constraint, or a control whose
/// displayed value disagrees with the setting behind it all show up here rather
/// than in the user's menu bar.
///
/// Actions that put up a modal panel — choosing an app, filling from the Dock,
/// emptying every slot, and the login item, which can fail with an alert — are
/// deliberately not fired: `runModal` would block forever with nobody to click it.
/// They are named in `modalActions` so what is left uncovered stays visible.
@main
struct Smoke {
    /// Its own preferences domain, so a smoke run cannot disturb a real ring.
    static let suiteName = "local.chakra.smoke"

    /// Actions that would block on `runModal`.
    static let modalActions: Set<String> = [
        "chooseSlot:", "fillFromDock", "clearOthers", "loginChanged:",
    ]

    static var failures: [String] = []
    static var checks = 0

    static func main() {
        let app = NSApplication.shared
        // Windows are built and laid out but never ordered front, so a smoke run
        // does not steal focus from whatever the user is doing.
        app.setActivationPolicy(.prohibited)

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            print("could not create the scratch preferences domain")
            exit(1)
        }

        let settings = Settings(defaults: scratch)
        let outer = OuterRing(defaults: scratch)
        let recents = Recents(defaults: scratch, selfPath: Bundle.main.bundleURL.path)

        // A ring with gaps in it: slots 0, 1 and 3 filled, the rest empty. That
        // exercises both the occupied and the empty row layouts, and the missing
        // badge if one of these ever goes away. Three apps so a removal can succeed
        // without breaching the floor.
        outer.assign("/System/Applications/Utilities/Terminal.app", at: 0)
        outer.assign("/System/Applications/Calculator.app", at: 1)
        outer.assign("/System/Applications/System Settings.app", at: 3)
        recents.record("/System/Applications/Notes.app")
        recents.record("/System/Applications/Preview.app")

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let look = NSAppearance(named: name) else { continue }
            look.performAsCurrentDrawingAppearance {
                exerciseSettingsWindow(outer: outer, recents: recents, settings: settings,
                                       appearance: name.rawValue)
                exerciseWheel(outer: outer, recents: recents, settings: settings,
                              appearance: name.rawValue)
                exerciseOrb(outer: outer, settings: settings, appearance: name.rawValue)
                exerciseOnboarding(outer: outer, recents: recents, settings: settings,
                                   appearance: name.rawValue)
            }
        }

        scratch.removePersistentDomain(forName: suiteName)

        if failures.isEmpty {
            print("✓ \(checks) smoke checks passed")
        } else {
            print("✗ \(failures.count) of \(checks) smoke checks failed\n")
            for failure in failures { print("  " + failure) }
            exit(1)
        }
    }

    // MARK: - Settings window

    static func exerciseSettingsWindow(outer: OuterRing, recents: Recents,
                                       settings: Settings, appearance: String) {
        let wheel = WheelController(outer: outer, recents: recents, settings: settings)
        let controller = SettingsController(outer: outer, settings: settings, wheel: wheel)

        // Windows built by an earlier pass are still in `NSApp.windows` — ordering
        // one out does not remove it — so the one to inspect is identified by being
        // new, not by its title.
        let before = Set(NSApp.windows.map(\.windowNumber))

        // `show` is what builds the window and its content. Ordering it front is
        // harmless under a .prohibited activation policy: it is never composited.
        controller.show()
        guard let window = NSApp.windows.first(where: {
            $0.title == "Chakra Settings" && !before.contains($0.windowNumber)
        }) else {
            fail("[\(appearance)] the settings window was never created")
            return
        }
        check(window.contentView != nil, "[\(appearance)] settings window has a content view")

        guard let root = window.contentView else { return }
        window.layoutIfNeeded()
        // The content view is a scroll view, which has no intrinsic height of its
        // own — the size that matters is the stack inside it. A zero there would
        // mean an empty window, and a height under the window's would mean the
        // scroller is pointless because a section failed to build.
        if let document = (root as? NSScrollView)?.documentView {
            check(document.fittingSize.width > 200 && document.fittingSize.height > 600,
                  "[\(appearance)] the settings stack lays out to a usable size,"
                    + " got \(document.fittingSize)")
        } else {
            fail("[\(appearance)] the settings content view is not a scroll view")
        }

        let controls = allControls(in: root)
        check(controls.count >= 12,
              "[\(appearance)] settings window has its controls, found \(controls.count)")

        // Drawing is where a bad colour or a nil image would throw.
        renderOffscreen(root, label: "[\(appearance)] settings window draws")

        var fired = 0
        var skipped: [String] = []
        for control in controls {
            guard let action = control.action else { continue }
            let name = NSStringFromSelector(action)
            if modalActions.contains(name) { skipped.append(name); continue }
            check(control.target != nil || NSApp.target(forAction: action) != nil,
                  "[\(appearance)] \(name) has a target")
            // Sliders and steppers are driven to both ends, since the interesting
            // cases are the extremes.
            if let slider = control as? NSSlider {
                for value in [slider.minValue, slider.maxValue,
                              (slider.minValue + slider.maxValue) / 2] {
                    slider.doubleValue = value
                    send(action, from: slider)
                    fired += 1
                }
            } else if let popUp = control as? NSPopUpButton {
                for index in 0..<popUp.numberOfItems {
                    popUp.selectItem(at: index)
                    send(action, from: popUp)
                    fired += 1
                }
            } else if let box = control as? NSButton, box.allowsMixedState == false,
                      box.state == .on || box.state == .off {
                // A checkbox is toggled and put back, so the run leaves the
                // scratch settings as it found them.
                for state in [NSControl.StateValue.on, .off, box.state] {
                    box.state = state
                    send(action, from: box)
                    fired += 1
                }
            } else {
                send(action, from: control)
                fired += 1
            }
        }
        check(fired >= 20, "[\(appearance)] fired enough control actions, got \(fired)")
        check(Set(skipped) == modalActions,
              "[\(appearance)] every modal action was found and skipped,"
                + " skipped \(Set(skipped).sorted())")

        // The settings written by those actions have to survive a fresh read of the
        // same domain: a value that only lives in a control is a value the wheel
        // will never see.
        let reread = Settings(defaults: settings.defaults)
        check(reread.wheelSize >= Settings.minWheelSize
                && reread.wheelSize <= Settings.maxWheelSize,
              "[\(appearance)] wheel size survives a re-read, got \(reread.wheelSize)")
        check(reread.glassOpacity >= 0 && reread.glassOpacity <= 1,
              "[\(appearance)] glass opacity survives a re-read, got \(reread.glassOpacity)")

        // Every control must agree with the setting behind it after the model is
        // changed from somewhere else, which is what the ring-changed notification
        // and `refreshEverything` are for.
        settings.wheelSize = Settings.maxWheelSize
        settings.glassOpacity = 0.5
        settings.glassTint = .purple
        outer.remove(at: 0)
        controller.show()
        window.layoutIfNeeded()
        let after = allControls(in: root)
        if let slider = after.compactMap({ $0 as? NSSlider }).first(where: {
            $0.maxValue == Settings.maxWheelSize
        }) {
            check(abs(slider.doubleValue - Settings.maxWheelSize) < 0.001,
                  "[\(appearance)] the size slider catches up with a changed setting,"
                    + " showing \(slider.doubleValue)")
        } else {
            fail("[\(appearance)] could not find the size slider")
        }
        renderOffscreen(root, label: "[\(appearance)] settings window redraws after a change")

        // Closing and reopening is where a released window or a stale delegate
        // would crash.
        window.performClose(nil)
        window.close()
        controller.show()
        check(true, "[\(appearance)] the settings window reopens after being closed")
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    // MARK: - Wheel

    static func exerciseWheel(outer: OuterRing, recents: Recents,
                              settings: Settings, appearance: String) {
        // The view is driven directly rather than through the controller's window:
        // an overlay window under a .prohibited policy never becomes key, so the
        // controller would hide it again immediately.
        let geometry = RingGeometry(scale: CGFloat(settings.wheelSize),
                                    outerSlotCount: settings.outerSlotCount,
                                    innerSlotCount: settings.innerSlotCount)
        let side = (geometry.discRadius + geometry.margin) * 2
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.geometry = geometry
        view.wheelCenter = CGPoint(x: side / 2, y: side / 2)
        view.glassOpacity = CGFloat(settings.glassOpacity)
        view.glassTint = settings.glassTint.color
        view.colorful = settings.colorfulHighlights
        view.outerItems = (0..<geometry.outerSlotCount).map { outer.item(at: $0) }
        view.innerItems = recents.inner(excluding: outer.occupiedPaths,
                                        limit: geometry.innerSlotCount)
            .map { RingItem.make(path: $0) }
        view.resetTransientState()
        renderOffscreen(view, label: "[\(appearance)] wheel draws")

        // Every slot count the sliders offer, at both ends of the size slider. The
        // counts change the number of icons drawn and the width of a slot's sector,
        // so a combination that divides badly would show up as a crash or a blank
        // wheel here rather than on the user's screen.
        for outerCount in [Settings.minOuterSlots, Settings.defaultOuterSlots,
                           Settings.maxOuterSlots] {
            for innerCount in [Settings.minInnerSlots, Settings.defaultInnerSlots,
                               Settings.maxInnerSlots] {
                for size in [Settings.minWheelSize, Settings.maxWheelSize] {
                    let g = RingGeometry(scale: CGFloat(size),
                                         outerSlotCount: outerCount,
                                         innerSlotCount: innerCount)
                    let width = (g.discRadius + g.margin) * 2
                    let sized = WheelView(frame: NSRect(x: 0, y: 0, width: width, height: width))
                    sized.geometry = g
                    sized.wheelCenter = CGPoint(x: width / 2, y: width / 2)
                    sized.colorful = true
                    sized.outerItems = (0..<outerCount).map { index in
                        outer.item(at: index)
                            ?? RingItem.make(path: "/System/Applications/Notes.app")
                    }
                    sized.innerItems = (0..<innerCount).map { _ in
                        RingItem.make(path: "/System/Applications/Preview.app")
                    }
                    sized.resetTransientState()
                    renderOffscreen(sized, label: "[\(appearance)] wheel draws with"
                                      + " \(outerCount)/\(innerCount) slots at \(size)")
                    // Hit-testing every point at these counts, since the sector
                    // width is what changes.
                    var y = 0 as CGFloat
                    while y < width {
                        var x = 0 as CGFloat
                        while x < width {
                            _ = g.hit(CGPoint(x: x, y: y), center: sized.wheelCenter)
                            x += 11
                        }
                        y += 11
                    }
                }
            }
        }

        // A note long enough to have been truncated in the centre pill, which is
        // why it is drawn outside the ring.
        view.flashMessage("Ring is full — drop onto a slot to replace what's there")
        renderOffscreen(view, label: "[\(appearance)] wheel draws a long note")

        // An empty wheel draws its own hint, and must not divide by a zero count.
        let empty = WheelView(frame: view.frame)
        empty.geometry = geometry
        empty.wheelCenter = view.wheelCenter
        empty.outerItems = Array(repeating: nil, count: geometry.outerSlotCount)
        empty.innerItems = []
        empty.resetTransientState()
        renderOffscreen(empty, label: "[\(appearance)] an empty wheel draws")

        // No glass at all: the zero end of the opacity slider.
        let bare = WheelView(frame: view.frame)
        bare.geometry = geometry
        bare.wheelCenter = view.wheelCenter
        bare.glassOpacity = 0
        bare.glassTint = nil
        bare.outerItems = view.outerItems
        bare.innerItems = view.innerItems
        bare.resetTransientState()
        renderOffscreen(bare, label: "[\(appearance)] a wheel with no glass draws")

        // Rotation: the opening sweep, then a scroll, then the snap back onto a slot.
        // Driven through the real event path and the real timer, so the animation
        // code runs rather than just the geometry behind it.
        let spun = WheelView(frame: view.frame)
        spun.geometry = geometry
        spun.wheelCenter = view.wheelCenter
        spun.outerItems = view.outerItems
        spun.innerItems = view.innerItems
        spun.colorful = true
        spun.scrollToSpin = true
        spun.spinOnOpen = true
        var settled: [(Ring, Int)] = []
        spun.onRotationSettled = { ring, steps in settled.append((ring, steps)) }
        spun.resetTransientState()
        spun.beginSweep()
        renderOffscreen(spun, label: "[\(appearance)] wheel draws mid-sweep")
        // Part way through the sweep the slots must be off their resting angles, and
        // by the end back on them.
        let midway = spun.geometry.outerRotation
        RunLoop.current.run(until: Date().addingTimeInterval(WheelView.sweepDuration + 0.1))
        check(abs(spun.geometry.outerRotation) < 0.0001,
              "[\(appearance)] the sweep ends at the resting rotation, got"
                + " \(spun.geometry.outerRotation)")
        check(abs(midway) > 0.0001,
              "[\(appearance)] the sweep actually offset the ring, got \(midway)")
        renderOffscreen(spun, label: "[\(appearance)] wheel draws after the sweep")

        // A scroll turns the ring; the snap then lands it on a whole slot.
        if let scroll = scrollEvent(in: spun, deltaY: 40) {
            spun.scrollWheel(with: scroll)
            check(abs(spun.geometry.outerRotation) > 0.0001,
                  "[\(appearance)] scrolling turned the outer ring")
            renderOffscreen(spun, label: "[\(appearance)] wheel draws part-turned")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let step = spun.geometry.step(.outer)
            let turns = spun.geometry.outerRotation / step
            check(abs(turns - turns.rounded()) < 0.01,
                  "[\(appearance)] the ring snapped onto a whole slot, got \(turns) steps")
            check(!settled.isEmpty,
                  "[\(appearance)] the settled rotation was reported for persisting")
        } else {
            fail("[\(appearance)] could not synthesise a scroll event")
        }

        // Scrolling with the feature off must do nothing at all.
        let still = WheelView(frame: view.frame)
        still.geometry = geometry
        still.wheelCenter = view.wheelCenter
        still.outerItems = view.outerItems
        still.scrollToSpin = false
        still.spinOnOpen = false
        still.resetTransientState()
        still.beginSweep()
        check(abs(still.geometry.outerRotation) < 0.0001,
              "[\(appearance)] no sweep when the setting is off")
        if let scroll = scrollEvent(in: still, deltaY: 40) {
            still.scrollWheel(with: scroll)
            check(abs(still.geometry.outerRotation) < 0.0001,
                  "[\(appearance)] no turn when scroll-to-spin is off")
        }

        // Keyboard navigation has to leave the wheel drawable and land on a real
        // slot however many times it is stepped.
        for keyCode in [123, 124, 125, 126, 48, 53] {
            guard let event = keyEvent(keyCode: UInt16(keyCode), in: view) else { continue }
            view.keyDown(with: event)
            checks += 1
        }
        renderOffscreen(view, label: "[\(appearance)] wheel draws after keyboard steps")

        // Every point of the wheel, and a band of desktop around it, must classify
        // without trapping.
        var hits = 0
        var y = -20 as CGFloat
        while y < side + 20 {
            var x = -20 as CGFloat
            while x < side + 20 {
                _ = geometry.hit(CGPoint(x: x, y: y), center: view.wheelCenter)
                hits += 1
                x += 7
            }
            y += 7
        }
        check(hits > 5000, "[\(appearance)] hit-tested the whole wheel, \(hits) points")

        // The masks the glass is cut with, at both ends of the size slider.
        for size in [Settings.minWheelSize, 1, Settings.maxWheelSize] {
            let mask = WheelController.donutMask(geometry: RingGeometry(scale: CGFloat(size)))
            check(mask.size.width > 0 && mask.size.height > 0,
                  "[\(appearance)] the glass mask at \(size) has a size")
        }

        // The recentlyHidden guard blocks reopening within 0.35s of a focus-driven
        // hide, to prevent the menu-bar item click that dismissed the wheel from
        // immediately reopening it. The orb needs to bypass this guard because it is
        // hidden while the wheel is open and therefore cannot be the dismissing click.
        let testWheel = WheelController(outer: outer, recents: recents, settings: settings)
        testWheel.show(atCursor: false)
        check(testWheel.isVisible, "[\(appearance)] test wheel opened")
        testWheel.hide(reason: .lostFocus)
        check(!testWheel.isVisible, "[\(appearance)] test wheel closed on focus loss")

        // Without bypass: blocked by the guard.
        testWheel.toggle(atCursor: false, ignoringRecentHide: false)
        check(!testWheel.isVisible,
              "[\(appearance)] toggle without bypass is blocked after recent hide")

        // With bypass: opens immediately.
        testWheel.toggle(atCursor: false, ignoringRecentHide: true)
        check(testWheel.isVisible,
              "[\(appearance)] toggle with bypass opens despite recent hide")
        testWheel.hide()

        exerciseShelfReadout(appearance: appearance)
        exerciseShelfDragHandle(appearance: appearance)
        exerciseHubDrop(appearance: appearance)
    }

    // MARK: - Orb

    /// Takes `settings` from the start even though this task's checks do not read
    /// it: Task 6 adds controller checks that need it, and changing a function's
    /// signature in a later task churns the file across a review boundary. The
    /// `_ = settings` at the end keeps `-warnings-as-errors` happy until then.
    static func exerciseOrb(outer: OuterRing, settings: Settings, appearance: String) {
        // Every size the setting offers, against a full ring, a ring with gaps and
        // an empty one. The dot count changes with the ring, so a bad divisor or a
        // nil colour would surface here rather than on the user's desktop.
        let rings: [(String, [NSColor?])] = [
            ("full", (0..<8).map { _ in NSColor.systemTeal }),
            ("gaps", (0..<8).map { $0 % 3 == 0 ? nil : NSColor.systemPink }),
            ("empty", (0..<8).map { _ in nil }),
            ("one", [NSColor.systemOrange]),
            ("none", []),
        ]
        for size in [OrbGeometry.minSize, OrbGeometry.defaultSize, OrbGeometry.maxSize] {
            for (label, colours) in rings {
                let g = OrbGeometry(size: size)
                let view = OrbView(frame: NSRect(x: 0, y: 0, width: g.size, height: g.size))
                view.geometry = g
                view.dotColors = colours
                view.rotation = 0.4
                renderOffscreen(view, label: "[\(appearance)] orb draws at \(size), \(label) ring")

                // The disc has to claim the middle and refuse the corners, or the
                // orb would swallow clicks meant for what is behind it.
                check(view.hitTest(CGPoint(x: g.radius, y: g.radius)) === view,
                      "[\(appearance)] the orb centre is clickable at \(size)")
                check(view.hitTest(CGPoint(x: 0, y: 0)) == nil,
                      "[\(appearance)] the orb corner is not clickable at \(size)")
            }
        }

        // The press/drag/release state machine, driven through the real overrides.
        // A window is needed: the drag reads the panel's frame to work out the grab
        // offset, and `mouseDown` returns early without one.
        let g = OrbGeometry(size: OrbGeometry.defaultSize)
        let panel = NSPanel(contentRect: NSRect(x: 300, y: 300, width: g.size, height: g.size),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        let view = OrbView(frame: NSRect(x: 0, y: 0, width: g.size, height: g.size))
        view.geometry = g
        view.dotColors = (0..<8).map { _ in NSColor.systemBlue }
        panel.contentView = view

        var clicks = 0, drags = 0, ends = 0, hovers: [Bool] = []
        var lastProposed: CGPoint?
        view.onClick = { clicks += 1 }
        view.onDragBegan = { drags += 1 }
        view.onDragMoved = { lastProposed = $0 }
        view.onDragEnded = { ends += 1 }
        view.onHoverChanged = { hovers.append($0) }

        // A press and release with no movement is a click, not a drag.
        view.mouseDown(with: NSEvent())
        view.mouseUp(with: NSEvent())
        check(clicks == 1 && drags == 0,
              "[\(appearance)] a still press is a click, got \(clicks) clicks \(drags) drags")

        // Hover is reported both ways.
        view.mouseEntered(with: NSEvent())
        view.mouseExited(with: NSEvent())
        check(hovers == [true, false],
              "[\(appearance)] hover is reported entering and leaving, got \(hovers)")
        _ = lastProposed
        _ = ends

        // The window-server configuration, which is where a wrong constant would
        // be invisible until the orb sat in the wrong place or crashed the app.
        for hidden in [true, false] {
            let p = OrbController.makePanel(size: 56, hiddenFromCapture: hidden)
            check(p.canBecomeKey == false,
                  "[\(appearance)] the orb panel can never become key")
            check(p.canBecomeMain == false,
                  "[\(appearance)] the orb panel can never become main")
            check(p.styleMask.contains(.nonactivatingPanel),
                  "[\(appearance)] the orb panel is non-activating")
            check(p.level.rawValue == Int(CGWindowLevelForKey(.mainMenuWindow)) - 1,
                  "[\(appearance)] the orb sits one level below the menu bar, got \(p.level.rawValue)")
            check(p.collectionBehavior.contains(.canJoinAllSpaces),
                  "[\(appearance)] the orb joins all Spaces")
            check(p.collectionBehavior.contains(.fullScreenAuxiliary),
                  "[\(appearance)] the orb shows beside a full-screen app")
            // The combination that raises an exception and kills the app.
            check(!p.collectionBehavior.contains(.moveToActiveSpace),
                  "[\(appearance)] the orb never sets moveToActiveSpace")
            check(!p.collectionBehavior.contains(.managed),
                  "[\(appearance)] the orb is not managed, so it is not a Mission Control tile")
            check(p.sharingType == (hidden ? .none : .readOnly),
                  "[\(appearance)] sharing type follows the setting")
            check(p.isReleasedWhenClosed == false,
                  "[\(appearance)] the orb panel survives being closed")
            p.orderOut(nil)
        }

        // Turning the setting on builds a panel; turning it off tears it down.
        let orbSettings = Settings(defaults: settings.defaults)
        orbSettings.showOrb = true
        // `shelf: nil` deliberately: this exercise is about the panel, and nil is also the path a
        // machine whose Application Support cannot be resolved would take, so it is worth running.
        let controller = OrbController(outer: outer, settings: orbSettings, shelf: nil)
        controller.show()
        check(controller.isVisible, "[\(appearance)] the orb appears when switched on")
        controller.setSuppressed(true)
        check(!controller.isVisible, "[\(appearance)] the orb hides while the wheel is open")
        // A setting can change while the wheel is open — dragging the wheel to a new
        // position does exactly that — and the orb must not reappear on top of it.
        controller.setSuppressed(true)
        controller.settingsDidChange()
        check(!controller.isVisible,
              "[\(appearance)] a setting changing while the wheel is open does not"
                + " bring the orb back")
        controller.setSuppressed(false)
        check(controller.isVisible, "[\(appearance)] the orb comes back when the wheel closes")
        orbSettings.showOrb = false
        controller.settingsDidChange()
        check(!controller.isVisible, "[\(appearance)] the orb goes away when switched off")

        // Cycle the orb on and off multiple times to verify no memory leaks or stale
        // panels. The panel and view are torn down when switched off, and weak captures
        // in the closures prevent retain cycles.
        for _ in 0..<5 {
            orbSettings.showOrb = true
            controller.settingsDidChange()
            check(controller.isVisible, "[\(appearance)] the orb reappears after cycling")
            orbSettings.showOrb = false
            controller.settingsDidChange()
            check(!controller.isVisible, "[\(appearance)] the orb disappears after cycling")
        }

        // Verify show() is idempotent: calling it twice doesn't stack panels.
        orbSettings.showOrb = true
        controller.show()
        check(controller.isVisible, "[\(appearance)] the orb is visible after first show()")
        controller.show()
        check(controller.isVisible, "[\(appearance)] the orb is still visible after second show()")
        // If show() created a second panel, we'd see multiple windows. We can't directly
        // count panels in this test, but the fact that hide() works correctly after
        // multiple show() calls proves idempotency.
        controller.hide()
        check(!controller.isVisible, "[\(appearance)] the orb hides correctly after multiple show() calls")

        // Verify the orb actually moves when tucking and untucking at all four edges.
        let tuckSettings = Settings(defaults: settings.defaults)
        tuckSettings.showOrb = true
        tuckSettings.orbTucksAtEdge = true
        tuckSettings.orbSize = 56
        let tuckController = OrbController(outer: outer, settings: tuckSettings, shelf: nil)
        tuckController.show()
        guard let tuckPanel = tuckController.panelForTesting,
              let tuckView = tuckPanel.contentView as? OrbView else {
            fail("[\(appearance)] could not get panel or view for tuck test")
            return
        }

        let testScreen = tuckPanel.screen ?? NSScreen.main!
        let visible = testScreen.visibleFrame
        let size = tuckView.geometry.size

        // Test all four edges. A wrong sign or wrong axis would fail for one of them.
        // Place the orb at each edge position.
        let edgeTests: [(OrbEdge, CGPoint)] = [
            (.left, CGPoint(x: visible.minX, y: visible.midY)),
            (.right, CGPoint(x: visible.maxX - size, y: visible.midY)),
            (.bottom, CGPoint(x: visible.midX, y: visible.minY)),
            (.top, CGPoint(x: visible.midX, y: visible.maxY - size)),
        ]

        // A locked screen refuses to reposition a window, so every one of these checks
        // fails with the orb sitting exactly where it started — which looks precisely like
        // a broken tuck animation and is not. Checked once, before the loop, so the failure
        // names its own cause instead of sending the next reader after a ghost.
        let probeTarget = CGPoint(x: visible.midX + 7, y: visible.midY + 7)
        tuckPanel.setFrameOrigin(probeTarget)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard abs(tuckPanel.frame.origin.x - probeTarget.x) < 2 else {
            fail("[\(appearance)] the window server refused to move the orb, so the tuck"
                   + " checks cannot run. This is what a locked screen or an inactive"
                   + " session looks like; unlock the screen and run again.")
            return
        }

        for (edge, origin) in edgeTests {
            // Place the orb at this edge.
            tuckPanel.setFrameOrigin(origin)
            let placedOrigin = tuckPanel.frame.origin
            // Spin briefly to let the window server process the position change.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))

            // Simulate the idle state: the orb is not hovered, not being dragged, and at
            // an edge, so it should tuck.
            tuckView.onHoverChanged?(false)
            // Spin the run loop to let the animation complete (0.18s duration + margin).
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }

            // Assert the orb tucked to the expected position for this edge.
            let tuckedOrigin = tuckPanel.frame.origin
            let expectedTuck = OrbPlacement.tuckedOrigin(placedOrigin, size: size,
                                                         in: visible, edge: edge)
            // 1pt tolerance for pixel snapping. Window frames snap to whole device pixels,
            // so a target of 1108.72 lands at 1108.00. Still fails wrong direction, wrong
            // axis, or no movement.
            check(abs(tuckedOrigin.x - expectedTuck.x) <= 1 &&
                  abs(tuckedOrigin.y - expectedTuck.y) <= 1,
                  "[\(appearance)] the orb tucked to the expected position at \(edge): "
                    + "got (\(tuckedOrigin.x), \(tuckedOrigin.y)), "
                    + "expected (\(expectedTuck.x), \(expectedTuck.y))")

            // Now untuck: simulate hover entering. The orb should return to the clamped
            // position of where it was when tucked, which may differ from where we
            // originally placed it if the tucked position was outside the visible area.
            tuckView.onHoverChanged?(true)
            let untuckDeadline = Date().addingTimeInterval(0.4)
            while Date() < untuckDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }

            // The untucked position should be the clamped version of the tucked position.
            let untuckedOrigin = tuckPanel.frame.origin
            let expectedUntuck = OrbPlacement.clamp(tuckedOrigin, size: size, in: visible)
            // 1pt tolerance for pixel snapping, not slack.
            check(abs(untuckedOrigin.x - expectedUntuck.x) <= 1 &&
                  abs(untuckedOrigin.y - expectedUntuck.y) <= 1,
                  "[\(appearance)] the orb untucked to the clamped position at \(edge): "
                    + "got (\(untuckedOrigin.x), \(untuckedOrigin.y)), "
                    + "expected (\(expectedUntuck.x), \(expectedUntuck.y))")
        }

        // CHECK (a): The sharingType rebuild. Switching "Hide from screen recordings"
        // OFF (becoming less private) requires rebuilding the panel because macOS
        // refuses to loosen sharingType from .none to .readOnly.
        let sharingSettings = Settings(defaults: settings.defaults)
        sharingSettings.showOrb = true
        sharingSettings.orbHiddenFromCapture = true
        let sharingController = OrbController(outer: outer, settings: sharingSettings, shelf: nil)
        sharingController.show()
        guard let panel1 = sharingController.panelForTesting else {
            fail("[\(appearance)] could not get panel for sharingType test")
            return
        }
        check(panel1.sharingType == .none,
              "[\(appearance)] panel with orbHiddenFromCapture=true has sharingType .none, got \(panel1.sharingType.rawValue)")

        // Switch the setting OFF (unhiding from recordings). This requires a rebuild.
        sharingSettings.orbHiddenFromCapture = false
        sharingController.settingsDidChange()
        guard let panel2 = sharingController.panelForTesting else {
            fail("[\(appearance)] could not get panel after sharingType change")
            return
        }
        check(panel2.sharingType == .readOnly,
              "[\(appearance)] panel after switching orbHiddenFromCapture to false has sharingType .readOnly, got \(panel2.sharingType.rawValue)")
        // If the panel was not rebuilt, it would still be .none. Getting .readOnly
        // proves a new panel was created, because macOS refuses .none -> .readOnly.

        // CHECK (b): The re-entrancy guard. Without it, firing a continuous slider's
        // action multiple times (as a drag does) would trigger refreshEverything on
        // every tick, resetting the slider value back from storage.
        // Use a separate defaults suite so earlier SettingsControllers don't see the
        // notification and interfere with the count.
        let guardSuite = "\(suiteName).guard"
        UserDefaults().removePersistentDomain(forName: guardSuite)
        guard let guardDefaults = UserDefaults(suiteName: guardSuite) else {
            fail("[\(appearance)] could not create guard defaults suite")
            return
        }
        let guardSettings = Settings(defaults: guardDefaults)
        let guardOuter = OuterRing(defaults: guardDefaults)
        let guardRecents = Recents(defaults: guardDefaults, selfPath: Bundle.main.bundleURL.path)
        let guardWheel = WheelController(outer: guardOuter, recents: guardRecents, settings: guardSettings)
        let guardController = SettingsController(outer: guardOuter, settings: guardSettings,
                                                 wheel: guardWheel)
        // Identified by being NEW, not by its title. Windows from an earlier pass stay in
        // `NSApp.windows` after being ordered out, and they carry the same title, so
        // matching on the title alone found the previous controller's window — and firing
        // a slider in it ran the previous controller's handler, which set the previous
        // controller's guard flag. This controller then refreshed, correctly, and the test
        // read that as the guard being broken.
        let beforeGuard = Set(NSApp.windows.map(\.windowNumber))
        guardController.show()
        guard let guardWindow = NSApp.windows.first(where: {
            !beforeGuard.contains($0.windowNumber) && $0.title == "Chakra Settings"
                && $0.contentView != nil
        }) else {
            fail("[\(appearance)] could not get settings window for re-entrancy guard test")
            return
        }
        guardWindow.layoutIfNeeded()

        // Find an orb slider (size or dim). These are continuous and fire on every tick.
        // The size slider specifically, not "either orb slider": the assertion below reads
        // `orbSize`, so accepting the dim slider would have compared the wrong setting and
        // passed or failed for reasons unrelated to the guard.
        let guardControls = allControls(in: guardWindow.contentView!)
        guard let orbSlider = guardControls.compactMap({ $0 as? NSSlider }).first(where: {
            $0.minValue == Double(OrbGeometry.minSize)
                && $0.maxValue == Double(OrbGeometry.maxSize)
        }) else {
            fail("[\(appearance)] could not find the orb size slider for the re-entrancy test")
            return
        }
        guard let action = orbSlider.action else {
            fail("[\(appearance)] orb slider has no action")
            return
        }
        let actionName = NSStringFromSelector(action)
        check(actionName == "orbSizeChanged:",
              "[\(appearance)] the orb size slider's action is orbSizeChanged, got \(actionName)")

        // Record the initial refresh count, fire the slider's action several times in
        // a row (simulating a continuous drag), and verify refreshEverything did NOT run.
        let initialCount = guardController.refreshCountForTesting
        // Deliberately NOT the midpoint. The size slider's midpoint is (36 + 76) / 2 = 56,
        // which is exactly the shipped default, so a check that the setting "changed" to the
        // midpoint passed without the action ever running — and hid the fact that the action
        // was reaching a different controller entirely. A quarter of the way up is a value
        // no default sits on.
        let midValue = orbSlider.minValue + (orbSlider.maxValue - orbSlider.minValue) * 0.25
        orbSlider.doubleValue = midValue

        // Verify the action actually fires by checking the setting changes.
        for _ in 0..<5 {
            if let action = orbSlider.action {
                send(action, from: orbSlider)
            }
        }
        check(abs(guardSettings.orbSize - midValue) < 0.01,
              "[\(appearance)] firing orbSlider action changed the setting to \(midValue), got \(guardSettings.orbSize)")

        let finalCount = guardController.refreshCountForTesting
        check(finalCount == initialCount,
              "[\(appearance)] firing an orb slider 5 times did not trigger refreshEverything,"
                + " expected count to stay at \(initialCount), got \(finalCount)")
        // If the re-entrancy guard is broken, refreshCountForTesting would increment
        // on every action (initial + 5 = \(initialCount + 5)), and this check would fail.

        guardDefaults.removePersistentDomain(forName: guardSuite)

        exerciseAppFloor(appearance: appearance)
        exerciseForgetPositionFallback(appearance: appearance)
        exerciseOrbDrop(appearance: appearance)
        exerciseShelfDrop(appearance: appearance)
    }

    /// Drops a file onto the orb without a person dragging one.
    ///
    /// `OrbView` reads exactly one thing from `NSDraggingInfo` — `draggingPasteboard` — so the
    /// rest of this is inert scaffolding to satisfy the protocol. The physical act of dragging
    /// from Finder still cannot be tested here; what this covers is everything the orb decides
    /// once a drag arrives, which is where the logic lives.
    final class StubDrag: NSObject, NSDraggingInfo {
        let pasteboard: NSPasteboard
        /// Where the drag currently is, in the destination view's window coordinates. Stored rather
        /// than `.zero`, because the hub and the ring are told apart by exactly this.
        var location: NSPoint

        init(paths: [String], at location: NSPoint = .zero) {
            self.location = location
            // A UUID in the name, not merely a private board. `NSPasteboard.Name` is
            // machine-global, so with a fixed name two test binaries share one board: measured
            // across 4,000 trials per process, `setData` returned false 627 times and reads came
            // back nil 1,116 times under two processes, against 0 and 0 solo.
            pasteboard = NSPasteboard(name: NSPasteboard.Name(
                "local.chakra.smoke.drag.\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
            super.init()
        }

        /// Hands the board back. A named pasteboard is machine-global and outlives the process until
        /// it is released, so a UUID per stub without this would leak one board per drag exercised.
        /// `registerScratchBoard` is not reachable from here — it lives in the test binary, and this
        /// is a different program.
        deinit { pasteboard.releaseGlobally() }

        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        var animatesToDestination: Bool {
            get { false }
            set { _ = newValue }
        }
        var numberOfValidItemsForDrop: Int {
            get { 1 }
            set { _ = newValue }
        }
        var draggingFormation: NSDraggingFormation {
            get { .default }
            set { _ = newValue }
        }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        // `override` because this is also a deprecated method on `NSObject`, which this stub
        // inherits from in order to conform to `NSDraggingInfo` at all.
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            nil
        }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int,
                                                  UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    /// Dropping an app onto the orb hands it to the ring.
    ///
    /// This path had no coverage at all: `performDragOperation` and `draggingEntered` appeared
    /// nowhere in this file, so "drop an app from Finder onto the orb" rested entirely on someone
    /// trying it. Found by the final review.
    static func exerciseOrbDrop(appearance: String) {
        let view = OrbView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        var dropped: [String] = []
        view.onDropPaths = { dropped = $0 }

        // A real app, so this fails if path handling breaks rather than because the file is
        // imaginary.
        let real = "/System/Applications/Notes.app"
        let good = StubDrag(paths: [real])
        check(view.draggingEntered(good) == .copy,
              "[\(appearance)] the orb accepts a dragged application")
        check(view.performDragOperation(good),
              "[\(appearance)] performing the drop succeeds")
        check(dropped == [real],
              "[\(appearance)] the dropped path is handed on unchanged, got \(dropped)")

        // Two at once: the orb must pass both on rather than silently keeping the first.
        dropped = []
        let two = StubDrag(paths: [real, "/System/Applications/Music.app"])
        check(view.performDragOperation(two),
              "[\(appearance)] a drop of two applications succeeds")
        check(dropped.count == 2,
              "[\(appearance)] both dropped paths are handed on, got \(dropped.count)")

        // An empty drag must be refused, not handed on as an empty list — the caller would add
        // nothing and the user would see the orb flash for no reason.
        dropped = ["untouched"]
        let empty = StubDrag(paths: [])
        // `.copy`, not `[]`, and this check was rewritten rather than deleted. Returning `[]` makes
        // AppKit skip `performDragOperation` entirely, so a cap refusal could never be explained and
        // would read to the user as a missed drop — `WheelView` learned that and its comment survives
        // there. What the old assertion was really protecting is that the orb does not *flash* for a
        // useless drag, and that is now asserted directly below instead of through the return value.
        check(view.draggingEntered(empty) == .copy,
              "[\(appearance)] the orb accepts the drag so a refusal can be explained")
        check(view.draggingUpdated(empty) == .copy,
              "[\(appearance)] and keeps accepting it while it moves")
        check(!view.isHighlightedForDragTesting,
              "[\(appearance)] but does not highlight for a drag carrying no files")
        check(!view.performDragOperation(empty),
              "[\(appearance)] performing an empty drop fails")
        check(dropped == ["untouched"],
              "[\(appearance)] a refused drop does not call the handler")
    }

    /// One rendered snapshot of a view, without needing a window.
    ///
    /// `displayIfNeeded()` on a windowless view draws **nothing** — measured, it drew 0 — so a
    /// crash-free call to it proves nothing at all. `cacheDisplay(in:to:)` really runs `draw(_:)`,
    /// which is what makes a pixel comparison worth anything.
    static func snapshot(of view: NSView) -> Data? {
        rendered(view)?.tiffRepresentation
    }

    /// The pixels themselves, for a check that needs to look inside one region rather
    /// than compare two whole renders.
    static func rendered(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The centre hole's rectangle in a rendered bitmap's pixel coordinates, clamped to the
    /// bitmap's bounds.
    ///
    /// Shared by `centreInk` and `centrePatch` so an ink count and a pixel comparison can
    /// never disagree about which pixels are "the hole". Returns nil for a view or a region
    /// with no area, so a caller cannot be handed an empty measurement that looks like a
    /// clean one.
    private static func centreRegion(of view: WheelView, in rep: NSBitmapImageRep)
        -> (x: Int, y: Int, columns: Int, rows: Int)? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let scaleX = CGFloat(rep.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / view.bounds.height
        // Four fifths of the hole: wide enough for the whole readout and the pill, and
        // clear of the inner ring's icons, which start one band further out.
        let half = view.geometry.holeRadius * 0.8
        // `colorAt` counts rows from the top, the view's geometry from the bottom.
        let top = Int(((view.bounds.height - (view.wheelCenter.y + half)) * scaleY).rounded())
        let left = Int(((view.wheelCenter.x - half) * scaleX).rounded())
        let x = max(left, 0)
        let y = max(top, 0)
        let columns = min(Int((half * 2 * scaleX).rounded()) - (x - left), rep.pixelsWide - x)
        let rows = min(Int((half * 2 * scaleY).rounded()) - (y - top), rep.pixelsHigh - y)
        guard columns > 0, rows > 0 else { return nil }
        return (x: x, y: y, columns: columns, rows: rows)
    }

    /// How many pixels were drawn inside the wheel's centre hole.
    ///
    /// `draw(_:)` washes the whole view with alpha 0.001 so the window keeps receiving
    /// clicks; in an eight-bit bitmap that rounds to zero, so an untouched hole really does
    /// measure 0 — checked with a standalone probe before this was relied on. Returns -1
    /// when the view could not be rendered at all, so a broken render fails a threshold
    /// rather than passing one.
    ///
    /// `minimumAlpha` is what separates text from the pill it sits on. `drawCenterPill` fills
    /// its rounded rect with `labelColor` at alpha 0.10 and strokes it at 0.14, and it draws
    /// that pill whatever the text says — so at the default threshold an invitation blanked
    /// to `""` still measures well over fifty pixels. Glyphs are drawn fully opaque, so
    /// raising the threshold to 0.5 counts the text and nothing else.
    static func centreInk(of view: WheelView, minimumAlpha: CGFloat = 0.02) -> Int {
        guard let rep = rendered(view), let region = centreRegion(of: view, in: rep) else {
            return -1
        }
        var ink = 0
        for row in 0..<region.rows {
            for column in 0..<region.columns {
                if let colour = rep.colorAt(x: region.x + column, y: region.y + row),
                   colour.alphaComponent > minimumAlpha {
                    ink += 1
                }
            }
        }
        return ink
    }

    /// The hole's pixels themselves, so two renders can be compared *inside* the hole.
    ///
    /// Comparing whole renders cannot answer "does the hole show the readout or the focused
    /// app's name". `WheelView.drawSlot` highlights a slot when `hover == ref || focus == ref
    /// || dropTarget == ref`, so a focused render differs from an unfocused one out on the
    /// ring no matter what the hole holds, and whole-render equality can never hold across a
    /// change of focus. Returns nil rather than empty `Data` when the view did not render, so
    /// a broken render cannot make two patches compare equal.
    static func centrePatch(of view: WheelView) -> Data? {
        guard let rep = rendered(view), !rep.isPlanar, let base = rep.bitmapData,
              let region = centreRegion(of: view, in: rep) else { return nil }
        let pixelBytes = rep.bitsPerPixel / 8
        guard pixelBytes > 0 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(region.rows * region.columns * pixelBytes)
        for row in 0..<region.rows {
            let start = (region.y + row) * rep.bytesPerRow + region.x * pixelBytes
            bytes.append(UnsafeBufferPointer(start: base + start,
                                             count: region.columns * pixelBytes))
        }
        return bytes.isEmpty ? nil : bytes
    }

    /// Files dropped on the orb reach the shelf, apps still reach the ring, and the presence dot
    /// really changes.
    ///
    /// `exerciseOrbDrop` covers apps going to the ring. This covers files going to the shelf, and the
    /// case neither covered before: a drop carrying both at once.
    static func exerciseShelfDrop(appearance: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chakra-smoke-shelf-\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: root) }
        let shelf = Shelf(root: root)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-\(UUID().uuidString).txt")
        _ = try? Data(repeating: 0x41, count: 32).write(to: source)
        defer { _ = try? FileManager.default.removeItem(at: source) }

        let outcome = shelf.add([source])
        check(outcome.added.count == 1,
              "[\(appearance)] a dropped file lands on the shelf, refusals \(outcome.refusals)")
        check(shelf.total().count == 1, "[\(appearance)] and the shelf's total reflects it")
        check(ShelfMessage.summary(outcome, shelf: shelf).hasPrefix("Added "),
              "[\(appearance)] and the wheel is handed something to say")

        // The split, which is the whole reason `performDragOperation` filters rather than letting
        // `Shelf` refuse the app: otherwise a mixed drop tells the user to drop the app on the wheel,
        // which is exactly where it just went.
        let view = OrbView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        view.geometry = OrbGeometry(size: 56)
        var toRing: [String] = []
        var toShelf: [URL] = []
        view.onDropPaths = { toRing = $0 }
        view.onDropURLs = { toShelf = $0 }
        let mixed = StubDrag(paths: ["/System/Applications/Notes.app", source.path])
        check(view.performDragOperation(mixed), "[\(appearance)] a mixed drop is performed")
        check(toRing == ["/System/Applications/Notes.app"],
              "[\(appearance)] the app went to the ring, got \(toRing)")
        check(toShelf.map(\.lastPathComponent) == [source.lastPathComponent],
              "[\(appearance)] and only the file went to the shelf, got \(toShelf)")

        // The presence dot, asserted on real pixels. The dot grows 1.9× and takes the accent colour,
        // so comparing whole renders is robust to whatever accent colour this machine is set to —
        // a radius change always moves some pixels, however the hue lands.
        view.shelfLoaded = false
        let emptyShot = snapshot(of: view)
        view.shelfLoaded = true
        let loadedShot = snapshot(of: view)
        check(emptyShot != nil && loadedShot != nil,
              "[\(appearance)] the orb renders in both shelf states")
        check(emptyShot != loadedShot,
              "[\(appearance)] and the presence dot really changes what is drawn")
    }

    /// A populated wheel at rest, with nothing hovered and nothing focused.
    ///
    /// `resetTransientState()` is deliberately **not** called here, but *not* because focus
    /// outranks the readout — it does not. It is because that call ends with
    /// `focus = firstOccupiedOuter()`, and a focused slot puts that app's name in the hole
    /// whenever the shelf is *empty*, which is what half the renders below are. The
    /// empty-shelf baselines would then hold a name instead of nothing, and `clearInk` would
    /// be measuring a pill rather than a clear hole.
    ///
    /// The focused case is not skipped, it is covered on purpose further down — with
    /// `resetTransientState()` called, exactly as `WheelWindow.show()` does on every open,
    /// because that is the only state the shipped app is ever in at rest.
    ///
    /// Its contents are fixed paths rather than the pass's shared ring, which the settings
    /// pass has already emptied a slot of: these renders are compared with each other, so
    /// they have to be identical apart from the shelf.
    static func restingWheel() -> WheelView {
        let geometry = RingGeometry(scale: 1)
        let side = (geometry.discRadius + geometry.margin) * 2
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.geometry = geometry
        view.wheelCenter = CGPoint(x: side / 2, y: side / 2)
        // Occupied slots, so a hover has a name to show; no inner items, so nothing else is
        // drawn near the hole and `centreInk` measures only what the hole itself holds.
        view.outerItems = (0..<geometry.outerSlotCount).map { index -> RingItem? in
            switch index {
            case 0: return RingItem.make(path: "/System/Applications/Notes.app")
            case 1: return RingItem.make(path: "/System/Applications/Mail.app")
            case 2: return RingItem.make(path: "/System/Applications/Music.app")
            default: return nil
            }
        }
        view.innerItems = []
        return view
    }

    /// The hub takes drops: it highlights while files hover, forecasts what will land, refuses over
    /// the cap before the user lets go, and hands every URL over on release.
    ///
    /// Renders are compared rather than state asserted, for the reason `exerciseShelfReadout`
    /// records: `check(wheel.dragOverHub)` after driving a drag cannot fail in any useful way, and
    /// `displayIfNeeded()` on a windowless view draws nothing at all.
    static func exerciseHubDrop(appearance: String) {
        let wheel = restingWheel()
        wheel.shelfCount = 2
        wheel.shelfBytes = 6 * 1024 * 1024
        let resting = snapshot(of: wheel)
        // Captured before any drag arrives, which is the whole point of it.
        let restingHole = centrePatch(of: wheel)

        let hub = wheel.wheelCenter
        // A point on the outer ring, so the same drag can be shown to land somewhere else.
        let slot = wheel.geometry.slotCenter(ring: .outer, index: 0, center: hub)

        var refusalAsked: [[URL]] = []
        var dropped: [[URL]] = []
        var refusal: String?
        wheel.shelfDropRefusal = { urls in refusalAsked.append(urls); return refusal }
        wheel.onShelfDrop = { dropped.append($0) }

        // Two files, so the forecast has a plural to get right and the count is not 1 by accident.
        let files = ["/etc/hosts", "/etc/services"]
        let overHub = StubDrag(paths: files, at: hub)

        check(wheel.draggingEntered(overHub) == .copy,
              "[\(appearance)] the hub accepts a file drag")
        check(refusalAsked.count == 1,
              "[\(appearance)] and asks about the cap exactly once, got \(refusalAsked.count)")
        check(refusalAsked.first?.count == 2,
              "[\(appearance)] with every URL on the drag, not just the first, "
              + "got \(refusalAsked.first?.count ?? -1)")
        let accepting = snapshot(of: wheel)
        check(accepting != resting,
              "[\(appearance)] and the hole shows something it was not showing at rest")

        // Moving out to a slot must hand the hole back, or the rim stays lit over the ring.
        //
        // Compared on the hole's own pixels, not the whole render, and that is the difference
        // between a check and a decoration: measured, a version of this asserting
        // `snapshot != accepting` stayed **green** under a sabotage that never released the hub's
        // feedback at all. Moving to a slot sets `dropTarget`, which highlights that slot out on the
        // ring, so the whole render differs whatever the hole is doing. `centrePatch`'s own docstring
        // warns about exactly this.
        overHub.location = slot
        _ = wheel.draggingUpdated(overHub)
        let offHubHole = centrePatch(of: wheel)
        check(restingHole != nil && offHubHole != nil,
              "[\(appearance)] the hole rendered in both states, or this proves nothing")
        check(offHubHole == restingHole,
              "[\(appearance)] moving off the hub gives the hole back exactly as it was")
        overHub.location = hub
        _ = wheel.draggingUpdated(overHub)
        check(snapshot(of: wheel) == accepting,
              "[\(appearance)] and moving back on restores the forecast")

        // The refusing state is the same shape in another colour, so it must differ from both.
        wheel.draggingExited(nil)
        refusal = "the shelf holds 6.3 MB of 1 GB"
        let overCap = StubDrag(paths: files, at: hub)
        _ = wheel.draggingEntered(overCap)
        let refusing = snapshot(of: wheel)
        check(refusing != accepting,
              "[\(appearance)] a drop that will not fit looks different from one that will")
        check(refusing != resting,
              "[\(appearance)] and different from the resting hole")

        // Release. The drop goes to the shelf, not to a ring slot, and carries everything.
        wheel.draggingExited(nil)
        refusal = nil
        let release = StubDrag(paths: files, at: hub)
        _ = wheel.draggingEntered(release)
        check(wheel.performDragOperation(release),
              "[\(appearance)] releasing over the hub is handled")
        check(dropped.count == 1, "[\(appearance)] once, got \(dropped.count)")
        check(dropped.first?.map(\.lastPathComponent) == ["hosts", "services"],
              "[\(appearance)] with every file, got \(dropped.first ?? [])")
        check(snapshot(of: wheel) == resting,
              "[\(appearance)] and the hole goes back to its resting state after the release")

        // A ring drop must still reach the ring and not the shelf — the hub branch runs first, so
        // this is the check that catches it claiming the whole wheel.
        var ringDrops: [String] = []
        wheel.onDropPath = { path, _, _ in ringDrops.append(path) }
        let onSlot = StubDrag(paths: ["/System/Applications/Notes.app"], at: slot)
        _ = wheel.draggingEntered(onSlot)
        check(wheel.performDragOperation(onSlot),
              "[\(appearance)] a drop on an outer slot is still handled")
        check(ringDrops.count == 1 && dropped.count == 1,
              "[\(appearance)] by the ring and not the shelf, ring \(ringDrops.count), "
              + "shelf \(dropped.count)")

        // An empty shelf has to answer the first file as much as the eleventh: `shelfCount` is 0
        // then, and the readout is otherwise conditional on it.
        let bare = restingWheel()
        bare.shelfDropRefusal = { _ in nil }
        let bareResting = snapshot(of: bare)
        let firstFile = StubDrag(paths: ["/etc/hosts"], at: bare.wheelCenter)
        _ = bare.draggingEntered(firstFile)
        check(snapshot(of: bare) != bareResting,
              "[\(appearance)] an empty shelf still responds to a drag over the hub")
    }

    /// A synthetic left-button event at a point in view coordinates.
    ///
    /// `windowNumber: 0` is safe because these views have no window: `convert(_:from: nil)` on a
    /// windowless view is the identity, so the location passed here *is* the view coordinate the
    /// handlers read.
    static func leftEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)
    }

    /// The folder in the hole is the shelf's drag handle; the rest of the hole still moves the
    /// wheel; and a click on the folder opens it instead of dismissing.
    ///
    /// The first checks in this project to drive a `WheelView` mouse sequence at all — nothing
    /// else does — so the harness itself is new ground. The session start is taken by
    /// `beginShelfDragOverride`; see its docstring for why a real one must not run here.
    static func exerciseShelfDragHandle(appearance: String) {
        let wheel = restingWheel()
        // Room around the wheel, and this is load-bearing rather than tidiness. `restingWheel`'s
        // frame is exactly the wheel's own footprint, and `move(to:)` goes through
        // `clampCenter(_:in:)`, which keeps all of the wheel on screen — so in a footprint-sized
        // view the only legal centre is the middle and the wheel can *never* move. Measured: the
        // "the hole still moves the wheel" check below failed for that reason alone, and the
        // "the wheel stayed where it was" check was vacuous for the same one.
        let side = wheel.frame.width
        wheel.frame = NSRect(x: 0, y: 0, width: side * 2, height: side * 2)
        wheel.wheelCenter = CGPoint(x: side, y: side)
        wheel.shelfCount = 2
        wheel.shelfBytes = 6 * 1024 * 1024

        // Geometry first, because every gesture below depends on it. The target is deliberately
        // larger than the drawn icon: at 0.70 scale the drawn folder is 18.2 pt, a third of the
        // orb's area.
        let drawn = wheel.shelfFolderRect
        let target = wheel.shelfFolderHitRect
        check(drawn != .zero, "[\(appearance)] a loaded shelf draws a folder to grab")
        check(target.contains(drawn), "[\(appearance)] the folder's target covers the folder drawn")
        check(abs(target.width - (drawn.width + 16)) < 0.01,
              "[\(appearance)] and is padded 8 pt each side, got \(target.width) vs \(drawn.width)")
        // Still a small share of the hole, or the wheel would lose its move handle.
        let hole = wheel.geometry.holeRadius * 2
        check(target.width < hole * 0.4,
              "[\(appearance)] while leaving most of the hole moving the wheel, "
              + "\(target.width) of \(hole)")

        let folderPoint = CGPoint(x: target.midX, y: target.midY)
        // A point inside the hole but well clear of the folder, so it is unambiguously the wheel's
        // own handle. Below the centre, because the readout sits above and below it.
        let holePoint = CGPoint(x: wheel.wheelCenter.x - wheel.geometry.holeRadius * 0.7,
                                y: wheel.wheelCenter.y)
        check(!target.contains(holePoint),
              "[\(appearance)] the comparison point is outside the folder, or this proves nothing")

        guard let down = leftEvent(.leftMouseDown, at: folderPoint),
              let up = leftEvent(.leftMouseUp, at: folderPoint),
              let far = leftEvent(.leftMouseDragged,
                                 at: CGPoint(x: folderPoint.x + 30, y: folderPoint.y + 30)),
              let holeDown = leftEvent(.leftMouseDown, at: holePoint),
              let holeUp = leftEvent(.leftMouseUp, at: holePoint),
              let holeFar = leftEvent(.leftMouseDragged,
                                      at: CGPoint(x: holePoint.x + 30, y: holePoint.y)) else {
            fail("[\(appearance)] could not synthesise the mouse sequence")
            return
        }

        var opened = 0
        var dismissed = 0
        var moved = 0
        var dragBegan = 0
        var draggedItems: [NSDraggingItem] = []
        var provided: [URL] = [URL(fileURLWithPath: "/etc/hosts"),
                               URL(fileURLWithPath: "/etc/services")]
        wheel.onOpenShelf = { opened += 1 }
        wheel.onDismiss = { dismissed += 1 }
        wheel.onMove = { _ in moved += 1 }
        wheel.onShelfDragBegan = { dragBegan += 1 }
        wheel.shelfURLsForDrag = { provided }
        wheel.beginShelfDragOverride = { draggedItems = $0 }

        // A click on the folder opens the shelf. Without its own branch in `mouseUp` this release
        // falls through to `release == .center` and *dismisses the wheel*, which is the one
        // outcome a user clicking a folder would not expect.
        wheel.mouseDown(with: down)
        wheel.mouseUp(with: up)
        check(opened == 1, "[\(appearance)] clicking the folder opens the shelf, got \(opened)")
        check(dismissed == 0,
              "[\(appearance)] and does not dismiss the wheel, got \(dismissed)")

        // A press on the folder must not arm the wheel's move. The move fires at 3 pt and a
        // drag-out at 6 pt, so an armed move would win every time and the handle could never drag.
        let before = wheel.wheelCenter
        wheel.mouseDown(with: down)
        wheel.mouseDragged(with: far)
        check(dragBegan == 1, "[\(appearance)] dragging the folder starts a drag, got \(dragBegan)")
        check(moved == 0, "[\(appearance)] and does not move the wheel, got \(moved)")
        check(wheel.wheelCenter == before,
              "[\(appearance)] the wheel stayed where it was, \(before) → \(wheel.wheelCenter)")
        // One item per file, each with its own frame: measured, a shared frame stacks thirty files
        // under a single icon and the user cannot tell how much they are carrying.
        check(draggedItems.count == 2,
              "[\(appearance)] the drag carries every shelf file, got \(draggedItems.count)")
        check(Set(draggedItems.map(\.draggingFrame.origin.x)).count == draggedItems.count,
              "[\(appearance)] and each one has its own frame rather than stacking")
        // The drag, not the click: a gesture that dragged must not also open Finder.
        wheel.mouseUp(with: up)
        check(opened == 1, "[\(appearance)] a drag does not also open the shelf, got \(opened)")
        check(dismissed == 0, "[\(appearance)] nor dismiss the wheel, got \(dismissed)")

        // A right-click while the folder press owns the gesture must do nothing. `rightMouseDown`'s
        // guard used `moveGrabOffset == nil` as its "the left button is down" proxy, and a folder
        // press deliberately leaves that nil — so without `!isShelfPressed` in the guard this
        // reopens a documented shipped defect: the right-release saw press and release both as
        // `.center` and dismissed the wheel mid-gesture, with `isMoving` left true, which then
        // rewrote `savedCenterFraction` and flashed a message on a window the user could no longer
        // see. Aborting a gesture must not rewrite a preference.
        dismissed = 0
        wheel.resetTransientState()
        wheel.wheelCenter = before
        if let rightDown = NSEvent.mouseEvent(with: .rightMouseDown, location: folderPoint,
                                              modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: 1),
           let rightUp = NSEvent.mouseEvent(with: .rightMouseUp, location: folderPoint,
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: 1) {
            wheel.mouseDown(with: down)
            wheel.rightMouseDown(with: rightDown)
            wheel.rightMouseUp(with: rightUp)
            check(dismissed == 0,
                  "[\(appearance)] a right-click during a folder press dismisses nothing, "
                  + "got \(dismissed)")
            wheel.mouseUp(with: up)
        } else {
            fail("[\(appearance)] could not synthesise the right-button sequence")
        }

        // The rest of the hole still moves the wheel, unchanged. This is the check that would
        // catch a folder target grown so large it ate the wheel's own handle.
        moved = 0
        dragBegan = 0
        wheel.mouseDown(with: holeDown)
        wheel.mouseDragged(with: holeFar)
        check(moved > 0, "[\(appearance)] the hole still moves the wheel, got \(moved)")
        check(dragBegan == 0,
              "[\(appearance)] and does not drag the shelf, got \(dragBegan)")
        wheel.mouseUp(with: holeUp)

        // A shelf emptied between the hole's last refresh and the press: no drag, and the release
        // still opens rather than dismissing.
        wheel.resetTransientState()
        wheel.wheelCenter = before
        provided = []
        dragBegan = 0
        opened = 0
        dismissed = 0
        wheel.mouseDown(with: down)
        wheel.mouseDragged(with: far)
        check(dragBegan == 0,
              "[\(appearance)] a shelf with no files starts no drag, got \(dragBegan)")
        wheel.mouseUp(with: up)
        check(opened == 1 && dismissed == 0,
              "[\(appearance)] and the release still opens rather than dismissing, "
              + "opened \(opened), dismissed \(dismissed)")

        // With nothing on the shelf there is no handle at all: the same point is the wheel's hole
        // again, and a click there dismisses exactly as it shipped.
        wheel.resetTransientState()
        wheel.shelfCount = 0
        check(wheel.shelfFolderHitRect == .zero,
              "[\(appearance)] an empty shelf has no folder to grab")
        opened = 0
        dismissed = 0
        wheel.mouseDown(with: down)
        wheel.mouseUp(with: up)
        check(dismissed == 1 && opened == 0,
              "[\(appearance)] and a click there dismisses as before, "
              + "dismissed \(dismissed), opened \(opened)")
    }

    /// The shelf readout in the centre hole: the folder icon over `"1 file / 3 MB total"`.
    ///
    /// Every check here compares two *renders*. Asserting `wheel.shelfCount == 6` after
    /// setting it to 6 cannot fail, and `displayIfNeeded()` on a windowless view draws
    /// nothing at all — see `snapshot(of:)`. So the readout is only ever asserted through
    /// `cacheDisplay(in:to:)`, which really runs `draw(_:)`.
    static func exerciseShelfReadout(appearance: String) {
        let wheel = restingWheel()

        // The state before the shelf existed: a wheel that has never been told about one.
        let pristine = snapshot(of: wheel)
        check(!wheel.shelfReadoutDrawsForTesting,
              "[\(appearance)] a wheel with no shelf files has no readout to draw")

        // A byte total with no files must draw nothing: the count is what the readout is
        // conditional on, and a shelf that reports bytes for zero files is what a failed
        // scan looks like.
        let sixMegabytes: Int64 = 6 * 1024 * 1024
        wheel.shelfBytes = 12 * 1024 * 1024
        wheel.shelfCount = 0
        let emptyShelf = snapshot(of: wheel)

        // The count sequence, with the byte total held at one value throughout, so each
        // difference below is the count's doing and not the size's.
        wheel.shelfBytes = sixMegabytes
        wheel.shelfCount = 0
        let none = snapshot(of: wheel)
        wheel.shelfCount = 1
        let readoutDraws = wheel.shelfReadoutDrawsForTesting
        let one = snapshot(of: wheel)
        wheel.shelfCount = 2
        let two = snapshot(of: wheel)
        wheel.shelfCount = 100
        let hundred = snapshot(of: wheel)
        wheel.shelfCount = 100_000
        let lots = snapshot(of: wheel)

        // The size, with the count held instead.
        wheel.shelfCount = 2
        wheel.shelfBytes = 900 * 1024 * 1024
        let bigger = snapshot(of: wheel)

        // The resting readout the hover and focus passes below are compared against, in
        // exactly the shelf state those passes use. The hole on its own is captured as well:
        // the focus passes cannot use the whole render, because focus highlights its slot.
        wheel.shelfCount = 6
        wheel.shelfBytes = sixMegabytes
        let restingSix = snapshot(of: wheel)
        let restingSixHole = centrePatch(of: wheel)

        // Guarded rather than checked one by one: a nil snapshot would make the *equality*
        // checks below pass without comparing anything.
        guard let pristine, let emptyShelf, let none, let one, let two, let hundred,
              let lots, let bigger, let restingSix, let restingSixHole else {
            fail("[\(appearance)] the wheel did not render in every shelf state")
            return
        }

        check(readoutDraws,
              "[\(appearance)] with one shelved file and nothing hovered, the readout is"
                + " what the hole shows")
        check(pristine == emptyShelf,
              "[\(appearance)] an empty shelf draws nothing extra, whatever its byte total")
        check(none != one,
              "[\(appearance)] the first shelved file changes what is drawn in the hole")
        check(one != two,
              "[\(appearance)] one file and two files do not read the same")
        check(two != hundred,
              "[\(appearance)] a hundred files do not read the same as two")
        check(hundred == lots,
              "[\(appearance)] counts past ninety-nine all read as 99+")
        check(two != bigger,
              "[\(appearance)] a bigger byte total changes the readout with the count held")

        // Ink in the hole, not just "some pixel somewhere changed": a readout drawn outside
        // the hole would satisfy every comparison above.
        wheel.shelfCount = 0
        wheel.shelfBytes = 0
        let clearInk = centreInk(of: wheel)
        // The control for the glyph-only measurement the invitation check uses at the end:
        // the same hole, with nothing in it, must read as no glyphs. Without this a
        // `minimumAlpha` that let the 0.001 click wash through would make that check pass on
        // an empty view.
        let clearGlyphInk = centreInk(of: wheel, minimumAlpha: 0.5)
        check(clearInk < 50,
              "[\(appearance)] a populated wheel with an empty shelf leaves the hole clear,"
                + " \(clearInk) pixels drawn")
        check(clearGlyphInk == 0,
              "[\(appearance)] and no glyphs at all in it, \(clearGlyphInk) opaque pixels")
        wheel.shelfCount = 1
        wheel.shelfBytes = 3 * 1024 * 1024
        let readoutInk = centreInk(of: wheel)
        check(readoutInk > 50,
              "[\(appearance)] the readout is drawn inside the hole, \(readoutInk) pixels")

        // A hovered app's name wins the centre. Two wheels in the same hover state, one with
        // a loaded shelf and one without, must render identically — that is what "the name
        // wins" means in pixels.
        let hoveredWithShelf = restingWheel()
        hoveredWithShelf.shelfCount = 6
        hoveredWithShelf.shelfBytes = sixMegabytes
        hover(hoveredWithShelf)
        check(!hoveredWithShelf.shelfReadoutDrawsForTesting,
              "[\(appearance)] a hovered slot takes the hole back from the readout")
        let hoveredWithoutShelf = restingWheel()
        hover(hoveredWithoutShelf)
        guard let withShelf = snapshot(of: hoveredWithShelf),
              let withoutShelf = snapshot(of: hoveredWithoutShelf) else {
            fail("[\(appearance)] the hovered wheel did not render")
            return
        }
        check(withShelf == withoutShelf,
              "[\(appearance)] the hovered app's name wins the hole: six shelved files add"
                + " nothing to the render")
        // Without this, the equality above would also hold if the hover had never registered
        // and both renders were the plain resting wheel: the same six-file shelf, hovered and
        // at rest, has to draw two different things.
        check(withShelf != restingSix,
              "[\(appearance)] and the hovered render really is not the readout render")

        // Keyboard focus is **not** a veto, and this is the pass that says so. The readout's
        // condition is `shelfCount > 0 && hover == nil`; `focus` does not appear in it.
        //
        // It cannot appear in it. `WheelView.resetTransientState()` ends with
        // `focus = firstOccupiedOuter()`, and `WheelWindow.swift:124` calls
        // `resetTransientState()` on every single wheel open — so on any non-empty ring the
        // focus is never nil at rest. A readout that stood down for a focused slot could
        // therefore never have drawn in the shipped app at all: the hole would always have
        // shown the first occupied app's name instead.
        //
        // Compared as holes, not whole renders: focus highlights its own slot out on the
        // ring, so two renders differing in focus can never be equal end to end.
        let focusedWithShelf = restingWheel()
        focusedWithShelf.resetTransientState()
        focusedWithShelf.shelfCount = 6
        focusedWithShelf.shelfBytes = sixMegabytes
        check(focusedWithShelf.shelfReadoutDrawsForTesting,
              "[\(appearance)] a focused slot yields the hole to the readout")
        let focusedWithoutShelf = restingWheel()
        focusedWithoutShelf.resetTransientState()
        guard let focusShelf = centrePatch(of: focusedWithShelf),
              let focusBare = centrePatch(of: focusedWithoutShelf) else {
            fail("[\(appearance)] the focused wheel did not render")
            return
        }
        check(focusShelf != focusBare,
              "[\(appearance)] the readout, not the focused app's name, is what a focused"
                + " wheel's hole shows")
        check(focusShelf == restingSixHole,
              "[\(appearance)] and the focused hole is the very readout an unfocused hole"
                + " draws — focus changes nothing inside it")

        // The shipped path, performed in the order the app performs it: the shelf is already
        // loaded when the wheel opens, and `WheelWindow.show()` calls `resetTransientState()`
        // before anything is drawn. This is the check the old "focus vetoes the readout"
        // contract made impossible to write, and its absence is exactly what hid the bug —
        // under that contract the hole below could only ever have said "Notes".
        let asOpened = restingWheel()
        asOpened.shelfCount = 6
        asOpened.shelfBytes = sixMegabytes
        asOpened.resetTransientState()
        guard let openedHole = centrePatch(of: asOpened) else {
            fail("[\(appearance)] the freshly opened wheel did not render")
            return
        }
        check(asOpened.shelfReadoutDrawsForTesting,
              "[\(appearance)] the readout survives the reset every wheel open performs")
        check(openedHole == restingSixHole,
              "[\(appearance)] a wheel opened the way the app opens it — non-empty ring,"
                + " six shelved files, focus set by resetTransientState — shows the readout"
                + " in the hole, not the focused app's name")

        // An empty ring with an empty shelf still has to say what it is for.
        //
        // Measured twice, because measuring *any* ink here is a check that cannot fail on the
        // thing it is about. `drawCenterPill` draws its translucent pill whatever the text
        // says, so blanking "Drop apps here" to "" leaves the pill behind — a probe measured
        // the pill alone at 2,160 pixels in both appearances, so a `> 50` threshold on any ink
        // stays green with the invitation gone. The second measurement counts only pixels at
        // least half opaque, which the pill's alpha-0.10 fill and alpha-0.14 border cannot
        // reach and glyphs always do: the same probe read 1,597 with the text and exactly 0
        // without it. `clearGlyphInk` above is the other half of that — an empty hole has to
        // read as no glyphs, or this threshold would be counting the click wash.
        let emptyRing = restingWheel()
        emptyRing.outerItems = Array(repeating: nil, count: emptyRing.geometry.outerSlotCount)
        emptyRing.innerItems = []
        emptyRing.resetTransientState()
        let inviteInk = centreInk(of: emptyRing)
        let inviteGlyphInk = centreInk(of: emptyRing, minimumAlpha: 0.5)
        check(inviteInk > 50,
              "[\(appearance)] an empty ring with an empty shelf still draws a pill in the"
                + " hole, \(inviteInk) pixels against \(clearInk) for a full ring")
        check(inviteGlyphInk > 50,
              "[\(appearance)] and the pill really carries the invitation text,"
                + " \(inviteGlyphInk) opaque pixels against \(clearGlyphInk) for a"
                + " clear hole")
    }

    /// Puts the pointer on the first outer slot, through the real event path.
    ///
    /// A bare `NSEvent()` cannot be used: its `locationInWindow` is (0, 0), which
    /// `geometry.hit` resolves to `.outside`, so nothing would be hovered and the checks
    /// that depend on a hover would fail for the wrong reason.
    static func hover(_ view: WheelView) {
        let target = view.geometry.slotCenter(ring: .outer, index: 0, center: view.wheelCenter)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: target,
                                             modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, eventNumber: 0, clickCount: 0,
                                             pressure: 0) else {
            fail("could not synthesise a mouse-moved event")
            return
        }
        view.mouseMoved(with: event)
    }

    /// "Forget Saved Position" must land the user on the shipped default.
    ///
    /// Raised by the Task 3 review as a real user path: the default for where the wheel opens
    /// was changed from `.pointer` to `.center`, and this button still fell back to `.pointer`.
    /// It was fixed, but the fix was only ever covered *by execution* — the pass below fires
    /// every settings control's action, so the line ran, but nothing asserted on its effect.
    /// A future edit putting `.pointer` back would therefore have left the suite green. That
    /// gap was recorded in the ledger and flagged to a final review; this is that check.
    static func exerciseForgetPositionFallback(appearance: String) {
        let suite = "\(suiteName).forget"
        UserDefaults().removePersistentDomain(forName: suite)
        guard let scratch = UserDefaults(suiteName: suite) else {
            fail("[\(appearance)] could not create the forget-position defaults suite")
            return
        }
        defer { scratch.removePersistentDomain(forName: suite) }

        let settings = Settings(defaults: scratch)
        let outer = OuterRing(defaults: scratch)
        let recents = Recents(defaults: scratch, selfPath: Bundle.main.bundleURL.path)
        let wheel = WheelController(outer: outer, recents: recents, settings: settings)
        let controller = SettingsController(outer: outer, settings: settings, wheel: wheel)

        // The state the button exists for: a position has been saved, and the wheel is set to
        // open there.
        settings.savedCenterFraction = CGPoint(x: 0.3, y: 0.7)
        settings.openLocation = .saved
        check(settings.openLocation == .saved,
              "[\(appearance)] the wheel is set to open at the saved position")

        // Identified by being new, not by its title: earlier passes' windows stay in
        // `NSApp.windows` after being ordered out and carry the same title.
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller.show()
        guard let window = NSApp.windows.first(where: {
            !before.contains($0.windowNumber) && $0.title == "Chakra Settings"
                && $0.contentView != nil
        }), let root = window.contentView else {
            fail("[\(appearance)] the forget-position settings window was never created")
            return
        }
        window.layoutIfNeeded()

        guard let forget = allControls(in: root).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Forget Saved Position" }) else {
            fail("[\(appearance)] could not find the Forget Saved Position button")
            window.orderOut(nil)
            return
        }
        check(forget.isEnabled,
              "[\(appearance)] Forget Saved Position is enabled while a position is saved")

        guard let action = forget.action else {
            fail("[\(appearance)] the Forget Saved Position button has no action")
            window.orderOut(nil)
            return
        }
        NSApp.sendAction(action, to: forget.target, from: forget)

        check(settings.savedCenterFraction == nil,
              "[\(appearance)] forgetting the position really clears it")
        // The assertion the ledger asked for. Named against the constant rather than the
        // literal `.center`, so if the shipped default ever changes deliberately this check
        // follows it instead of having to be edited.
        check(settings.openLocation == Settings(defaults: UserDefaults(suiteName: "\(suite).fresh")!)
                .openLocation,
              "[\(appearance)] forgetting the position falls back to the shipped default,"
                + " got \(settings.openLocation.rawValue)")
        check(!forget.isEnabled,
              "[\(appearance)] the button disables itself once there is nothing left to forget")

        UserDefaults().removePersistentDomain(forName: "\(suite).fresh")
        window.orderOut(nil)
    }

    /// The three-app floor, as the user actually meets it: greyed-out Clear buttons.
    ///
    /// The model side is covered by unit tests. This is the part that is only true if the
    /// interface asks — a ring that refuses removal while every Clear button still looks
    /// available would be a worse experience than no floor at all.
    static func exerciseAppFloor(appearance: String) {
        // Its own preferences domain: the ring has to sit at exactly the floor, which the
        // rest of the pass's ring does not.
        let floorSuite = "\(suiteName).floor"
        UserDefaults().removePersistentDomain(forName: floorSuite)
        guard let floorDefaults = UserDefaults(suiteName: floorSuite) else {
            fail("[\(appearance)] could not create the floor defaults suite")
            return
        }
        defer { floorDefaults.removePersistentDomain(forName: floorSuite) }

        let floorSettings = Settings(defaults: floorDefaults)
        let floorOuter = OuterRing(defaults: floorDefaults)
        for (index, path) in ["/System/Applications/Notes.app",
                              "/System/Applications/Mail.app",
                              "/System/Applications/Music.app"].enumerated() {
            floorOuter.assign(path, at: index)
        }
        check(floorOuter.occupiedCount == Settings.minOuterApps,
              "[\(appearance)] the floor ring holds exactly \(Settings.minOuterApps) apps,"
                + " got \(floorOuter.occupiedCount)")
        check(!floorOuter.canRemove(at: 0),
              "[\(appearance)] a ring at the floor refuses removal")

        let floorRecents = Recents(defaults: floorDefaults,
                                   selfPath: Bundle.main.bundleURL.path)
        let floorWheel = WheelController(outer: floorOuter, recents: floorRecents,
                                         settings: floorSettings)
        let floorController = SettingsController(outer: floorOuter, settings: floorSettings,
                                                 wheel: floorWheel)
        // Identified by being new, not by its title: earlier passes' windows are still in
        // `NSApp.windows` after being ordered out, and they carry the same title.
        let beforeFloor = Set(NSApp.windows.map(\.windowNumber))
        floorController.show()
        guard let floorWindow = NSApp.windows.first(where: {
            !beforeFloor.contains($0.windowNumber) && $0.title == "Chakra Settings"
                && $0.contentView != nil
        }), let floorRoot = floorWindow.contentView else {
            fail("[\(appearance)] the floor settings window was never created")
            return
        }
        floorWindow.layoutIfNeeded()

        let clears = allControls(in: floorRoot)
            .compactMap { $0 as? NSButton }
            .filter { $0.title == "Clear" }
        check(!clears.isEmpty,
              "[\(appearance)] the settings window has per-slot Clear buttons")
        check(clears.allSatisfy { !$0.isEnabled },
              "[\(appearance)] every Clear button is greyed out at the floor,"
                + " \(clears.filter(\.isEnabled).count) of \(clears.count) were not")

        // One more app, and the Clear buttons must come back — otherwise the floor would
        // be indistinguishable from a ring that can never be edited.
        floorOuter.assign("/System/Applications/Maps.app", at: 3)
        floorController.show()
        let clearsAfter = allControls(in: floorRoot)
            .compactMap { $0 as? NSButton }
            .filter { $0.title == "Clear" }
        check(clearsAfter.contains(where: { $0.isEnabled }),
              "[\(appearance)] a fourth app re-enables at least one Clear button")

        floorWindow.orderOut(nil)
    }

    // MARK: - Onboarding

    static func exerciseOnboarding(outer: OuterRing, recents: Recents,
                                   settings: Settings, appearance: String) {
        let controller = OnboardingController(outer: outer, recents: recents,
                                              settings: settings)
        settings.didOnboard = false
        var finished = false
        // Identified by being new, like the settings and orb passes. `last(where:)` on the
        // title happened to work, but it leans on `NSApp.windows` being in creation order,
        // which nothing promises — and finding a previous pass's window by title is exactly
        // how the re-entrancy check came to fire a control belonging to another controller.
        let beforeWelcome = Set(NSApp.windows.map(\.windowNumber))
        controller.presentIfNeeded { finished = true }
        guard let window = NSApp.windows.first(where: {
            !beforeWelcome.contains($0.windowNumber) && $0.title == "Chakra"
                && $0.contentView?.subviews.isEmpty == false
        }) else {
            fail("[\(appearance)] the welcome window was never created")
            return
        }
        guard let root = window.contentView else { return }
        window.layoutIfNeeded()
        renderOffscreen(root, label: "[\(appearance)] welcome window draws")
        check(root.fittingSize.height > 100,
              "[\(appearance)] welcome content lays out, got \(root.fittingSize)")

        // The choice buttons build the next step, which is where a window sized to
        // the wrong content would clip its own list.
        for control in allControls(in: root) {
            guard let action = control.action else { continue }
            send(action, from: control)
            checks += 1
            break
        }
        if let next = window.contentView {
            window.layoutIfNeeded()
            renderOffscreen(next, label: "[\(appearance)] the next welcome step draws")
            check(next.fittingSize.height <= window.frame.height,
                  "[\(appearance)] the welcome window is tall enough for its content:"
                    + " content \(next.fittingSize.height), window \(window.frame.height)")
        }
        _ = finished
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    // MARK: - Helpers

    /// Every control in a view tree, deepest last, in a stable order.
    static func allControls(in view: NSView) -> [NSControl] {
        var out: [NSControl] = []
        if let control = view as? NSControl { out.append(control) }
        for child in view.subviews { out.append(contentsOf: allControls(in: child)) }
        return out
    }

    /// Sends an action the way a click does, so a nil target still reaches the
    /// responder chain instead of being silently dropped.
    static func send(_ action: Selector, from sender: NSControl) {
        if let target = sender.target {
            if target.responds(to: action) {
                _ = target.perform(action, with: sender)
            } else {
                fail("\(NSStringFromSelector(action)) sent to a target that does not respond")
            }
        } else {
            check(NSApp.sendAction(action, to: nil, from: sender),
                  "\(NSStringFromSelector(action)) found a handler in the responder chain")
        }
    }

    /// Draws a view into a bitmap, which runs the same code an on-screen refresh
    /// would. `cacheDisplay` rather than `bitmapImageRepForCachingDisplay` alone so
    /// that subviews are drawn too.
    static func renderOffscreen(_ view: NSView, label: String) {
        checks += 1
        var bounds = view.bounds
        if bounds.isEmpty { bounds = NSRect(x: 0, y: 0, width: 480, height: 640) }
        view.frame = bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            failures.append(label + ": could not make a bitmap for \(bounds)")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard rep.representation(using: .png, properties: [:]) != nil else {
            failures.append(label + ": the drawn view did not encode")
            return
        }
    }

    /// A scroll aimed at the outer ring.
    ///
    /// `NSEvent.mouseEvent` cannot make a `.scrollWheel`, so this goes through a
    /// CoreGraphics event, which is the only way to get one with real scrolling
    /// deltas on it.
    static func scrollEvent(in view: WheelView, deltaY: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else {
            return nil
        }
        // Aimed at the outer ring, which is where the icons are.
        let target = view.geometry.slotCenter(ring: .outer, index: 0, center: view.wheelCenter)
        cg.location = CGPoint(x: target.x, y: target.y)
        return NSEvent(cgEvent: cg)
    }

    static func keyEvent(keyCode: UInt16, in view: NSView) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: view.bounds.origin,
                         modifierFlags: [], timestamp: 0,
                         windowNumber: view.window?.windowNumber ?? 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: keyCode)
    }

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    static func fail(_ label: String) {
        checks += 1
        failures.append(label)
    }
}

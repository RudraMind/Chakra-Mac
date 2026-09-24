import Carbon.HIToolbox
import Foundation

private var suiteCounter = 0

/// Each case gets its own defaults domain, so nothing leaks between cases or into
/// the user's real preferences.
private func scratchDefaults() -> UserDefaults {
    suiteCounter += 1
    let name = "local.chakra.tests.settings.\(suiteCounter)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    registerScratchDomain(name)
    return UserDefaults(suiteName: name)!
}

func runSettingsTests() {
    suite("settings/defaults") {
        let settings = Settings(defaults: scratchDefaults())
        expectEqual(settings.didOnboard, false, "a fresh install has not onboarded")
        expectEqual(settings.colorfulHighlights, true, "highlights start on each app's own colour")
        expectEqual(settings.outerSlotCount, 8, "the outer ring starts with eight slots")
        expectEqual(settings.innerSlotCount, 5, "the inner ring starts with five slots")
        expectEqual(settings.hotkeyEnabled, true, "the shortcut is on by default")
        expectEqual(settings.showInDock, false, "Chakra starts as a menu-bar app")
        expectClose(CGFloat(settings.glassOpacity), 0.85, "glass starts nearly solid")
        expectClose(CGFloat(settings.wheelSize), 1, "the wheel starts at its reference size")
        expectEqual(settings.glassTint, .none, "no tint by default")
        expectEqual(settings.openLocation, .center, "the wheel opens at the centre")
        expectEqual(settings.hotkeyKeyCode, Int(kVK_Space), "the default key is Space")
        expectEqual(settings.hotkeyModifiers, Int(optionKey), "the default modifier is Option")
        expectEqual(settings.hotkeyLabel, "Space", "the default label spells Space")
        expectEqual(settings.hotkeyDisplay, "⌥Space", "the default shortcut reads ⌥Space")
        expect(settings.savedCenterFraction == nil, "nothing has been dragged yet")
    }

    suite("settings/round-trip") {
        let defaults = scratchDefaults()
        let settings = Settings(defaults: defaults)
        settings.didOnboard = true
        settings.colorfulHighlights = true
        settings.hotkeyEnabled = false
        settings.showInDock = true
        settings.glassOpacity = 0.5
        settings.wheelSize = 1.2
        settings.glassTint = .purple
        settings.openLocation = .saved
        settings.hotkeyKeyCode = 9
        settings.hotkeyModifiers = Int(cmdKey | shiftKey)
        settings.hotkeyLabel = "V"

        // A second view of the same domain is what the app really does: the status
        // item, the wheel and the settings window each hold their own copy.
        let reloaded = Settings(defaults: defaults)
        expectEqual(reloaded.didOnboard, true, "onboarding is remembered")
        expectEqual(reloaded.colorfulHighlights, true, "the highlight mode is remembered")
        expectEqual(reloaded.hotkeyEnabled, false, "a disabled shortcut stays disabled")
        expectEqual(reloaded.showInDock, true, "the Dock choice is remembered")
        expectClose(CGFloat(reloaded.glassOpacity), 0.5, "opacity is remembered")
        expectClose(CGFloat(reloaded.wheelSize), 1.2, "size is remembered")
        expectEqual(reloaded.glassTint, .purple, "the tint is remembered")
        expectEqual(reloaded.openLocation, .saved, "the opening place is remembered")
        expectEqual(reloaded.hotkeyKeyCode, 9, "the key code is remembered")
        expectEqual(reloaded.hotkeyModifiers, Int(cmdKey | shiftKey),
                    "the modifiers are remembered")
        expectEqual(reloaded.hotkeyDisplay, "⇧⌘V", "the shortcut reads in Apple's order")
    }

    suite("settings/enum-cases") {
        let settings = Settings(defaults: scratchDefaults())
        for tint in GlassTint.allCases {
            settings.glassTint = tint
            expectEqual(settings.glassTint, tint, "tint \(tint.rawValue) survives a round trip")
            expectEqual(tint.label.isEmpty, false, "tint \(tint.rawValue) has a label")
            expect(tint == .none ? tint.color == nil : tint.color != nil,
                   "only 'none' has no colour")
        }
        for place in OpenLocation.allCases {
            settings.openLocation = place
            expectEqual(settings.openLocation, place,
                        "location \(place.rawValue) survives a round trip")
            expectEqual(place.label.isEmpty, false, "location \(place.rawValue) has a label")
        }
    }

    suite("settings/clamping") {
        let settings = Settings(defaults: scratchDefaults())
        settings.wheelSize = 99
        expectClose(CGFloat(settings.wheelSize), CGFloat(Settings.maxWheelSize),
                    "an absurd size is clamped down")
        settings.wheelSize = 0.01
        expectClose(CGFloat(settings.wheelSize), CGFloat(Settings.minWheelSize),
                    "a tiny size is clamped up")
        settings.glassOpacity = 4
        expectClose(CGFloat(settings.glassOpacity), 1, "opacity cannot exceed 1")
        settings.glassOpacity = -2
        expectClose(CGFloat(settings.glassOpacity), 0, "opacity cannot go below 0")
        settings.hotkeyKeyCode = 5000
        expectEqual(settings.hotkeyKeyCode, 127, "a key code beyond the keyboard is clamped")
        settings.hotkeyKeyCode = -9
        expectEqual(settings.hotkeyKeyCode, 0, "a negative key code is clamped")
        settings.hotkeyModifiers = -1
        expectEqual(settings.hotkeyModifiers, 0, "negative modifiers are clamped")
        settings.hotkeyModifiers = 0x1FFFF
        expectEqual(settings.hotkeyModifiers, 0xFFFF, "oversized modifiers are clamped")
    }

    suite("settings/not-a-number") {
        // NaN compares false with everything, so a naive min/max clamp lets it
        // through and the stored plist ends up holding a value nothing can use.
        let settings = Settings(defaults: scratchDefaults())
        settings.wheelSize = Double.nan
        expectClose(CGFloat(settings.wheelSize), 1, "a NaN size falls back to the default")
        settings.glassOpacity = Double.infinity
        expectClose(CGFloat(settings.glassOpacity), 0.85,
                    "an infinite opacity falls back to the default")
        settings.savedCenterFraction = CGPoint(x: .nan, y: 0.5)
        expect(settings.savedCenterFraction == nil, "a NaN position is not remembered")
    }

    suite("settings/wrong-types") {
        // Anything can end up in a defaults domain: an old version of the app, a
        // `defaults write` by hand, a sync from another Mac. None of it may leave
        // Chakra in a state it has no code for.
        let defaults = scratchDefaults()
        let settings = Settings(defaults: defaults)

        defaults.set("yes", forKey: DefaultsKey.hotkeyEnabled)
        expectEqual(settings.hotkeyEnabled, true,
                    "a string under hotkeyEnabled must not read as false")
        defaults.set(0, forKey: DefaultsKey.hotkeyEnabled)
        expectEqual(settings.hotkeyEnabled, false, "a number 0 does mean off")
        defaults.set(1, forKey: DefaultsKey.showInDock)
        expectEqual(settings.showInDock, true, "a number 1 does mean on")

        defaults.set("large", forKey: DefaultsKey.wheelSize)
        expectClose(CGFloat(settings.wheelSize), 1, "a string size falls back to the default")
        defaults.set(["x"], forKey: DefaultsKey.glassOpacity)
        expectClose(CGFloat(settings.glassOpacity), 0.85,
                    "an array opacity falls back to the default")
        // Values of the right type but outside the range are clamped on read too,
        // not just on write.
        defaults.set(7.5, forKey: DefaultsKey.wheelSize)
        expectClose(CGFloat(settings.wheelSize), CGFloat(Settings.maxWheelSize),
                    "an out-of-range stored size is clamped on the way out")

        defaults.set("chartreuse", forKey: DefaultsKey.glassTint)
        expectEqual(settings.glassTint, .none, "an unknown tint name falls back to none")
        defaults.set(42, forKey: DefaultsKey.glassTint)
        expectEqual(settings.glassTint, .none, "a numeric tint falls back to none")
        defaults.set("elsewhere", forKey: DefaultsKey.openLocation)
        expectEqual(settings.openLocation, .center,
                    "an unknown location falls back to the centre")

        defaults.set(17, forKey: DefaultsKey.hotkeyLabel)
        expectEqual(settings.hotkeyLabel, "Space", "a numeric label falls back to Space")
        defaults.set("   ", forKey: DefaultsKey.hotkeyLabel)
        expectEqual(settings.hotkeyLabel, "Space", "a blank label falls back to Space")
        defaults.set("  F5  ", forKey: DefaultsKey.hotkeyLabel)
        expectEqual(settings.hotkeyLabel, "F5", "a padded label is trimmed")
        defaults.set(String(repeating: "x", count: 40), forKey: DefaultsKey.hotkeyLabel)
        expectEqual(settings.hotkeyLabel, "Space",
                    "a label too long to be a key falls back to Space")
    }

    suite("settings/saved-position") {
        let defaults = scratchDefaults()
        let settings = Settings(defaults: defaults)
        settings.savedCenterFraction = CGPoint(x: 0.25, y: 0.75)
        let read = settings.savedCenterFraction
        expect(read != nil, "a dragged position is remembered")
        expectClose(read?.x ?? -1, 0.25, "the horizontal fraction survives")
        expectClose(read?.y ?? -1, 0.75, "the vertical fraction survives")

        settings.savedCenterFraction = CGPoint(x: 2, y: -1)
        expectClose(settings.savedCenterFraction?.x ?? -1, 1, "a fraction above 1 is clamped")
        expectClose(settings.savedCenterFraction?.y ?? -1, 0, "a fraction below 0 is clamped")

        settings.savedCenterFraction = nil
        expect(settings.savedCenterFraction == nil, "forgetting the position clears it")
        expect(defaults.object(forKey: DefaultsKey.savedCenterX) == nil,
               "forgetting removes the key rather than storing a zero")
        expect(defaults.object(forKey: DefaultsKey.savedCenterY) == nil,
               "forgetting removes both keys")

        // Half a position is no position: falling back to the centre beats
        // opening the wheel against an edge.
        defaults.set(0.4, forKey: DefaultsKey.savedCenterX)
        expect(settings.savedCenterFraction == nil, "one axis alone is not a position")
    }

    suite("settings/geometry-agreement") {
        // The size slider's range has to be one the geometry will actually honour,
        // or the wheel would silently stop growing part way along the slider.
        expect(CGFloat(Settings.minWheelSize) >= RingGeometry.minScale,
               "the smallest offered size is drawable")
        expect(CGFloat(Settings.maxWheelSize) <= RingGeometry.maxScale,
               "the largest offered size is drawable")
        let big = CGSize(width: 3000, height: 3000)
        expectClose(RingGeometry.scale(forScreen: big, userSize: CGFloat(Settings.maxWheelSize)),
                    CGFloat(Settings.maxWheelSize),
                    "a large screen honours the largest size the slider offers")
        // A screen too small for the chosen size shrinks the wheel rather than
        // letting it hang off the edge.
        let small = CGSize(width: 400, height: 300)
        let fitted = RingGeometry.scale(forScreen: small, userSize: CGFloat(Settings.maxWheelSize))
        expect(fitted < CGFloat(Settings.maxWheelSize),
               "a small screen overrides the chosen size")
        expectClose(fitted, RingGeometry.fittingScale(forScreen: small),
                    "the override is exactly what the screen can hold")
    }

    suite("settings/rotation") {
        let settings = Settings(defaults: scratchDefaults())
        expectEqual(settings.outerRotationSteps, 0, "a fresh ring is not turned")
        expectEqual(settings.innerRotationSteps, 0, "a fresh inner ring is not turned")
        expectEqual(settings.spinOnOpen, true, "the opening sweep is on by default")
        expectEqual(settings.scrollToSpin, true, "scroll to turn is on by default")

        // One step of eight is an eighth of a turn.
        settings.outerRotationSteps = 1
        expectClose(settings.rotation(for: .outer, slotCount: 8), .pi / 4,
                    "one step of eight is a quarter pi")
        settings.outerRotationSteps = 8
        expectClose(settings.rotation(for: .outer, slotCount: 8), 0,
                    "a whole turn is the same as no turn")

        // The stored value is a slot offset, so it stays meaningful when the ring is
        // resized. Five steps on a four-slot ring is one step.
        settings.outerRotationSteps = 5
        expectClose(settings.rotation(for: .outer, slotCount: 4), .pi / 2,
                    "an offset larger than the ring wraps rather than overshooting")

        // Negative offsets — turning the other way — wrap into range too.
        settings.outerRotationSteps = -1
        expectClose(settings.rotation(for: .outer, slotCount: 8), 2 * .pi * 7 / 8,
                    "turning back one step is the same as forward seven of eight")

        // A ring with nothing in it must not divide by zero.
        expectClose(settings.rotation(for: .inner, slotCount: 0), 0,
                    "an empty ring has no rotation")

        // Absurd or wrong-typed stored values must not reach the geometry.
        let hostile = scratchDefaults()
        hostile.set("sideways", forKey: DefaultsKey.outerRotationSteps)
        expectEqual(Settings(defaults: hostile).outerRotationSteps, 0,
                    "a string rotation falls back to none")
        hostile.set(10_000_000, forKey: DefaultsKey.outerRotationSteps)
        expect(abs(Settings(defaults: hostile).outerRotationSteps) <= 1000,
               "an absurd rotation is clamped")
        expect(Settings(defaults: hostile).rotation(for: .outer, slotCount: 8).isFinite,
               "a clamped rotation is still a real angle")
    }

    suite("settings/orb") {
        let settings = Settings(defaults: scratchDefaults())
        expectEqual(settings.showOrb, false, "the orb is off on a fresh install")
        expectClose(CGFloat(settings.orbSize), OrbGeometry.defaultSize,
                    "the orb starts at its default size")
        expectClose(CGFloat(settings.orbIdleOpacity), 0.35, "the orb dims to 35% by default")
        expectEqual(settings.orbTucksAtEdge, true, "tucking is on by default")
        expectEqual(settings.orbHiddenFromCapture, true,
                    "the orb is hidden from screen recordings by default")
        expect(settings.orbFraction == nil, "a fresh install has no saved orb position")

        // The size range the settings offer has to be one the geometry honours,
        // or the slider would silently stop having an effect part way along.
        settings.orbSize = 9000
        expectClose(CGFloat(settings.orbSize), OrbGeometry.maxSize, "an absurd size clamps down")
        settings.orbSize = 0
        expectClose(CGFloat(settings.orbSize), OrbGeometry.minSize, "zero clamps up")
        settings.orbSize = 64
        expectClose(CGFloat(OrbGeometry(size: CGFloat(settings.orbSize)).size), 64,
                    "a size in range reaches the geometry unchanged")

        settings.orbIdleOpacity = 5
        expectClose(CGFloat(settings.orbIdleOpacity), 1, "opacity clamps to 1")
        settings.orbIdleOpacity = -1
        expectClose(CGFloat(settings.orbIdleOpacity), 0.15,
                    "opacity clamps to the floor, so the orb never becomes invisible")

        // The saved position round-trips, and clearing it really clears it.
        settings.orbDisplayID = 7
        settings.orbDisplayName = "Studio Display"
        settings.orbFraction = CGPoint(x: 0.25, y: 0.75)
        let reread = Settings(defaults: settings.defaults)
        expectEqual(reread.orbDisplayID, 7, "the display id survives a re-read")
        expectEqual(reread.orbDisplayName, "Studio Display", "the display name survives")
        expectClose(reread.orbFraction?.x ?? -1, 0.25, "the saved x fraction survives")
        expectClose(reread.orbFraction?.y ?? -1, 0.75, "the saved y fraction survives")
        reread.clearOrbPosition()
        expect(Settings(defaults: settings.defaults).orbFraction == nil,
               "clearing the position removes it")

        // The display id clamps on the way to disk as well as on the way back, like every
        // other bounded setting. The getter alone guarded it before, which meant a nonsense
        // value really was written to the plist and only tidied up on read — so anything
        // reading that file without going through `Settings` saw the nonsense.
        settings.orbDisplayID = -5
        expectEqual(settings.orbDisplayID, 0, "a negative display id clamps to zero")
        expectEqual(settings.defaults.integer(forKey: DefaultsKey.orbDisplayID), 0,
                    "and zero is what actually reached the stored plist")
        settings.orbDisplayID = Int(Int32.max) + 1000
        expectEqual(settings.orbDisplayID, Int(Int32.max), "an absurd display id clamps down")
        expectEqual(settings.defaults.integer(forKey: DefaultsKey.orbDisplayID),
                    Int(Int32.max), "and the clamped value is what was stored")
        settings.orbDisplayID = 7
        expectEqual(settings.orbDisplayID, 7, "an id in range is stored unchanged")

        // Wrong-typed and out-of-range stored values must not reach a window frame.
        let hostile = scratchDefaults()
        hostile.set("big", forKey: DefaultsKey.orbSize)
        expectClose(CGFloat(Settings(defaults: hostile).orbSize), OrbGeometry.defaultSize,
                    "a string size falls back to the default")
        hostile.set(["not", "a", "number"], forKey: DefaultsKey.orbFractionX)
        expect(Settings(defaults: hostile).orbFraction == nil,
               "a wrong-typed fraction reads as no saved position")
    }

    // The three settings that broke the rule `orbDisplayID`'s test states.
    //
    // Every clamp assertion elsewhere in this file reads back through the getter, which
    // clamps independently — so those checks pass whether or not the setter clamps, and the
    // omission was invisible. These read the stored plist directly, which is the only way to
    // see what a support dump, `defaults read` or a future migration would find.
    suite("settings/setters-clamp-on-the-way-to-disk") {
        let settings = Settings(defaults: scratchDefaults())

        settings.outerRotationSteps = 999_999_999
        expectEqual(settings.defaults.integer(forKey: DefaultsKey.outerRotationSteps),
                    Settings.maxRotationSteps,
                    "an absurd outer rotation is clamped before it reaches the plist")
        settings.innerRotationSteps = -123_456_789
        expectEqual(settings.defaults.integer(forKey: DefaultsKey.innerRotationSteps),
                    -Settings.maxRotationSteps,
                    "and so is an absurd negative inner rotation")
        settings.outerRotationSteps = 3
        expectEqual(settings.defaults.integer(forKey: DefaultsKey.outerRotationSteps), 3,
                    "a rotation in range is stored unchanged")

        // The label's getter trimmed, rejected empty and capped the length; the setter
        // stored any string at all, so the plist could hold a paragraph.
        settings.hotkeyLabel = String(repeating: "x", count: 500)
        expectEqual(settings.defaults.object(forKey: DefaultsKey.hotkeyLabel) as? String,
                    "Space", "an over-long key label never reaches the plist")
        settings.hotkeyLabel = "   "
        expectEqual(settings.defaults.object(forKey: DefaultsKey.hotkeyLabel) as? String,
                    "Space", "a whitespace-only label never reaches the plist")
        settings.hotkeyLabel = "  Page Down  "
        expectEqual(settings.defaults.object(forKey: DefaultsKey.hotkeyLabel) as? String,
                    "Page Down", "a real label is trimmed and stored")
        expectEqual(settings.hotkeyLabel, "Page Down", "and reads back the same way")
    }

    suite("settings/opens-at-centre-by-default") {
        // Changed when the orb arrived: with a button parked at a screen edge, the
        // pointer is a poor place to centre a wheel.
        let settings = Settings(defaults: scratchDefaults())
        expectEqual(settings.openLocation, OpenLocation.center,
                    "the wheel opens at the centre of the screen by default")
    }

    suite("settings/forget-position-fallback") {
        // When the user forgets a saved position, the UI changes openLocation from
        // .saved to the shipped default. This test pins what that default is, so
        // the UI's hardcoded fallback cannot drift from the actual default.
        let settings = Settings(defaults: scratchDefaults())
        settings.openLocation = .saved
        settings.savedCenterFraction = CGPoint(x: 0.3, y: 0.7)
        expectEqual(settings.openLocation, .saved, "saved position is selected")

        settings.savedCenterFraction = nil
        // The Settings struct does not automatically change openLocation when the
        // position is cleared — that is the UI's job. But the UI's fallback must
        // match the shipped default.
        expectEqual(settings.openLocation, .saved,
                    "Settings does not change openLocation on its own")

        // The fallback the UI uses (in SettingsWindow.forgetPosition) must be the
        // actual default, so assert that here.
        let fresh = Settings(defaults: scratchDefaults())
        expectEqual(fresh.openLocation, OpenLocation.center,
                    "the UI must fall back to .center, which is the shipped default")
    }
}

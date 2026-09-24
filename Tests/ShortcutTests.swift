import AppKit
import Carbon.HIToolbox

/// Builds the kind of event the recorder sees, so the label logic can be tested
/// without a window and without a keyboard.
private func keyEvent(keyCode: Int, characters: String, ignoringModifiers: String,
                      flags: NSEvent.ModifierFlags = []) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: 0, context: nil, characters: characters,
                     charactersIgnoringModifiers: ignoringModifiers, isARepeat: false,
                     keyCode: UInt16(keyCode))
}

func runShortcutTests() {
    suite("shortcut/carbon-modifiers") {
        expectEqual(Shortcut.carbonModifiers(from: []), 0, "no flags means no modifiers")
        expectEqual(Shortcut.carbonModifiers(from: [.command]), cmdKey, "Command maps to cmdKey")
        expectEqual(Shortcut.carbonModifiers(from: [.option]), optionKey, "Option maps to optionKey")
        expectEqual(Shortcut.carbonModifiers(from: [.control]), controlKey,
                    "Control maps to controlKey")
        expectEqual(Shortcut.carbonModifiers(from: [.shift]), shiftKey, "Shift maps to shiftKey")
        expectEqual(Shortcut.carbonModifiers(from: [.command, .option, .control, .shift]),
                    cmdKey | optionKey | controlKey | shiftKey, "all four combine")
        // Flags Carbon has no bit for must not leak into the mask: capsLock and the
        // numeric-pad flag arrive on ordinary key presses.
        expectEqual(Shortcut.carbonModifiers(from: [.capsLock, .numericPad, .function]), 0,
                    "flags Carbon cannot register are dropped")
        expectEqual(Shortcut.carbonModifiers(from: [.command, .capsLock]), cmdKey,
                    "an ignored flag does not disturb the ones that count")
    }

    suite("shortcut/glyphs") {
        // Apple's order is ⌃⌥⇧⌘ regardless of the order the keys were pressed in.
        expectEqual(Shortcut.glyphs(carbonModifiers: cmdKey | optionKey | controlKey | shiftKey),
                    "⌃⌥⇧⌘", "the glyphs come out in Apple's order")
        expectEqual(Shortcut.glyphs(carbonModifiers: 0), "", "no modifiers means no glyphs")
        expectEqual(Shortcut.glyphs(carbonModifiers: optionKey), "⌥", "Option alone")
        expectEqual(Shortcut.display(carbonModifiers: optionKey, keyLabel: "Space"), "⌥Space",
                    "the default shortcut reads as ⌥Space")
        expectEqual(Shortcut.display(carbonModifiers: cmdKey | shiftKey, keyLabel: "K"), "⇧⌘K",
                    "a modifier pair reads in order")
        expectEqual(Shortcut.display(carbonModifiers: 0, keyLabel: "F5"), "F5",
                    "a function key needs no glyphs")
    }

    suite("shortcut/acceptable") {
        // Without ⌘, ⌥ or ⌃ the shortcut would fire while the user was typing.
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_Space), carbonModifiers: optionKey),
                    true, "⌥Space is acceptable")
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_ANSI_K), carbonModifiers: controlKey),
                    true, "⌃K is acceptable")
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_ANSI_K),
                                          carbonModifiers: cmdKey | optionKey),
                    true, "⌥⌘K is acceptable")
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_ANSI_K), carbonModifiers: 0),
                    false, "a bare key is not a shortcut")
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_ANSI_K), carbonModifiers: shiftKey),
                    false, "Shift alone is not enough")
        expectEqual(Shortcut.isAcceptable(keyCode: -1, carbonModifiers: cmdKey), false,
                    "a negative key code is refused")
        expectEqual(Shortcut.isAcceptable(keyCode: 128, carbonModifiers: cmdKey), false,
                    "a key code beyond the keyboard is refused")
        expectEqual(Shortcut.isAcceptable(keyCode: 127, carbonModifiers: optionKey), true,
                    "the last usable key code is accepted")
    }

    suite("shortcut/reserved") {
        // The combinations that would be actively harmful to take over. ⌘Q was the
        // worst: it registers successfully, so nothing but this list stops Chakra
        // from breaking Quit in every app on the Mac.
        for (modifiers, name) in [(cmdKey, "⌘Q"), (cmdKey | shiftKey, "⇧⌘Q"),
                                  (cmdKey | controlKey, "⌃⌘Q")] {
            expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_ANSI_Q),
                                              carbonModifiers: modifiers),
                        false, "\(name) is refused")
        }
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_Tab), carbonModifiers: cmdKey),
                    false, "⌘Tab is refused")
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_Space), carbonModifiers: cmdKey),
                    false, "⌘Space is refused")
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_Escape),
                                          carbonModifiers: cmdKey | optionKey),
                    false, "⌥⌘Esc is refused")
        // Adding a modifier the reserved entry does not list makes it usable again.
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_ANSI_Q),
                                          carbonModifiers: cmdKey | optionKey),
                    true, "⌥⌘Q is not reserved and stays available")

        // ⌘ with a plain character is where app menus live, so it is refused as a
        // class rather than one combination at a time.
        for key in [kVK_ANSI_K, kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_1] {
            expectEqual(Shortcut.isAcceptable(keyCode: Int(key), carbonModifiers: cmdKey),
                        false, "⌘ with a single character key is refused")
        }
        // A named key is not menu territory, so plain ⌘ is fine there.
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_F9), carbonModifiers: cmdKey),
                    true, "⌘F9 is acceptable")
        expectEqual(Shortcut.isAcceptable(keyCode: Int(kVK_Home), carbonModifiers: cmdKey),
                    true, "⌘Home is acceptable")

        // Every refusal has to say something, and every reserved entry has to be
        // reachable — an entry whose modifiers no key press can produce is dead.
        expect(Shortcut.unavailableReason(keyCode: Int(kVK_ANSI_Q),
                                          carbonModifiers: cmdKey)?.contains("Quit") == true,
               "the refusal names what it collided with")
        expect(Shortcut.unavailableReason(keyCode: Int(kVK_Space),
                                          carbonModifiers: optionKey) == nil,
               "the shipped default has no reason to be refused")
        for (keyCode, clashes) in Shortcut.reserved {
            expect(!clashes.isEmpty, "reserved key \(keyCode) lists at least one clash")
            for clash in clashes {
                expect(clash.modifiers & (cmdKey | optionKey | controlKey) != 0,
                       "reserved entry \(clash.name) carries a real modifier")
                expect(!clash.name.isEmpty, "reserved entry for \(keyCode) is named")
            }
        }
    }

    suite("shortcut/labels") {
        // Every named key must have a name, and no two keys may share one, or the
        // menu would show the same shortcut for two different combinations.
        expectEqual(Shortcut.specialNames[Int(kVK_Space)], "Space", "Space is named")
        expectEqual(Shortcut.specialNames[Int(kVK_Escape)], "Esc",
                    "Esc is named, even though the recorder spends it on cancelling")
        expectEqual(Set(Shortcut.specialNames.values).count, Shortcut.specialNames.count,
                    "no two keys share a name")
        expectEqual(Shortcut.specialNames.values.contains(where: \.isEmpty), false,
                    "no key is named with an empty string")
    }

    suite("shortcut/key-label") {
        guard let space = keyEvent(keyCode: Int(kVK_Space), characters: " ",
                                   ignoringModifiers: " ") else {
            expect(false, "a synthetic Space event could be built")
            return
        }
        expectEqual(Shortcut.keyLabel(for: space), "Space",
                    "a key with no printable character gets its name")

        // ⌥C produces "ç"; the label has to come from the unmodified character or
        // the settings window would show a shortcut nobody typed.
        guard let optionC = keyEvent(keyCode: Int(kVK_ANSI_C), characters: "ç",
                                     ignoringModifiers: "c", flags: [.option]) else {
            expect(false, "a synthetic ⌥C event could be built")
            return
        }
        expectEqual(Shortcut.keyLabel(for: optionC), "C",
                    "the label ignores what the modifier did to the character")

        guard let lower = keyEvent(keyCode: Int(kVK_ANSI_K), characters: "k",
                                   ignoringModifiers: "k") else { return }
        expectEqual(Shortcut.keyLabel(for: lower), "K", "letters are shown in upper case")

        guard let comma = keyEvent(keyCode: Int(kVK_ANSI_Comma), characters: ",",
                                   ignoringModifiers: ",") else { return }
        expectEqual(Shortcut.keyLabel(for: comma), ",", "punctuation is shown as itself")

        // A key that reports nothing usable still has to produce something the
        // user can tell apart from another key.
        guard let mystery = keyEvent(keyCode: 120, characters: "", ignoringModifiers: "") else {
            return
        }
        expectEqual(Shortcut.keyLabel(for: mystery), "F2",
                    "a named function key wins over the fallback")
        guard let unnamed = keyEvent(keyCode: 110, characters: "", ignoringModifiers: "") else {
            return
        }
        expectEqual(Shortcut.keyLabel(for: unnamed), "Key 110",
                    "an unknown key falls back to its code")
    }
}

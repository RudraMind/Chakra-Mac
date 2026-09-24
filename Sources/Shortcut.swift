import AppKit
import Carbon.HIToolbox

/// Turns a key press into something both `RegisterEventHotKey` and the user can
/// read.
///
/// Pure functions with no state, so the fiddly parts — which modifier bits Carbon
/// wants, what counts as a usable shortcut, how a key is spelled — are testable
/// without a window.
enum Shortcut {
    /// Keys that have no printable character and so need a name. Everything else
    /// is spelled using the character the user's own keyboard layout produces, so
    /// the label is right on a non-US layout without consulting the layout data.
    static let specialNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter",
        kVK_Tab: "Tab", kVK_Escape: "Esc", kVK_Delete: "Delete",
        kVK_ForwardDelete: "Fwd Delete", kVK_Help: "Help",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// How a pressed key should be spelled in the menu and the settings window.
    static func keyLabel(for event: NSEvent) -> String {
        if let name = specialNames[Int(event.keyCode)] { return name }
        // Ignoring modifiers so ⌥C reads as "C" rather than as "ç".
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.uppercased() }
        }
        return "Key \(event.keyCode)"
    }

    /// Carbon wants its own modifier bits, not `NSEvent`'s.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var out = 0
        if flags.contains(.command) { out |= cmdKey }
        if flags.contains(.option) { out |= optionKey }
        if flags.contains(.control) { out |= controlKey }
        if flags.contains(.shift) { out |= shiftKey }
        return out
    }

    /// Apple's canonical modifier order: ⌃ ⌥ ⇧ ⌘.
    static func glyphs(carbonModifiers: Int) -> String {
        var out = ""
        if carbonModifiers & controlKey != 0 { out += "⌃" }
        if carbonModifiers & optionKey != 0 { out += "⌥" }
        if carbonModifiers & shiftKey != 0 { out += "⇧" }
        if carbonModifiers & cmdKey != 0 { out += "⌘" }
        return out
    }

    static func display(carbonModifiers: Int, keyLabel: String) -> String {
        glyphs(carbonModifiers: carbonModifiers) + keyLabel
    }

    /// Combinations macOS itself, or every app's own menu, already owns.
    ///
    /// These are the ones that would be actively harmful to shadow: the user would
    /// press the shortcut expecting to quit, log out or switch apps and get a wheel
    /// of app icons instead, with no way back except finding Chakra's settings
    /// again. `RegisterEventHotKey` refuses only a handful of these, so refusing
    /// them here is the only thing standing between the user and a Mac whose ⌘Q
    /// stops working.
    ///
    /// Keyed by key code; the value lists the exact modifier sets that are
    /// reserved, so ⌥⌘Q stays available while ⌘Q, ⇧⌘Q and ⌃⌘Q do not.
    static let reserved: [Int: [(modifiers: Int, name: String)]] = [
        kVK_ANSI_Q: [(cmdKey, "Quit"), (cmdKey | shiftKey, "Log Out"),
                     (cmdKey | controlKey, "Lock Screen")],
        kVK_ANSI_W: [(cmdKey, "Close Window"), (cmdKey | optionKey, "Close All Windows")],
        kVK_Tab: [(cmdKey, "Switch Apps"), (cmdKey | shiftKey, "Switch Apps")],
        kVK_Space: [(cmdKey, "Spotlight"), (cmdKey | controlKey, "Emoji Picker"),
                    (cmdKey | optionKey, "Finder Search")],
        kVK_Escape: [(cmdKey | optionKey, "Force Quit")],
        kVK_ANSI_H: [(cmdKey, "Hide"), (cmdKey | optionKey, "Hide Others")],
        kVK_ANSI_M: [(cmdKey, "Minimise"), (cmdKey | optionKey, "Minimise All")],
        kVK_ANSI_D: [(cmdKey | optionKey, "Hide the Dock")],
        kVK_ANSI_F: [(cmdKey | controlKey, "Full Screen")],
        kVK_ANSI_Grave: [(cmdKey, "Cycle Windows"), (cmdKey | shiftKey, "Cycle Windows")],
        kVK_ANSI_3: [(cmdKey | shiftKey, "Screenshot")],
        kVK_ANSI_4: [(cmdKey | shiftKey, "Screenshot Selection")],
        kVK_ANSI_5: [(cmdKey | shiftKey, "Screenshot Options")],
    ]

    /// Why a combination cannot be used, or nil when it can.
    ///
    /// A reason rather than a bare Bool so the settings window can tell the user
    /// what they collided with instead of just refusing. Each reason is a complete
    /// sentence and says nothing about how to get out of recording — the caller
    /// owns that, and it is the caller that knows Esc is the way.
    static func unavailableReason(keyCode: Int, carbonModifiers: Int) -> String? {
        guard keyCode >= 0, keyCode <= 127 else { return "That key cannot be used." }
        guard carbonModifiers & (cmdKey | optionKey | controlKey) != 0 else {
            return "A shortcut needs ⌘, ⌥ or ⌃."
        }

        if let clash = reserved[keyCode]?.first(where: { $0.modifiers == carbonModifiers }) {
            return "\(display(carbonModifiers: carbonModifiers, keyLabel: keyLabel(forKeyCode: keyCode)))"
                + " is \(clash.name) on macOS. Pick something else."
        }

        // ⌘ on its own with a character key is where every application keeps its
        // own menu shortcuts, so taking one system-wide would break that command in
        // every app at once. Function keys and the named keys are left alone: they
        // are not menu territory.
        let onlyCommand = carbonModifiers & (optionKey | controlKey) == 0
            && carbonModifiers & cmdKey != 0
        if onlyCommand, specialNames[keyCode] == nil {
            return "⌘ with a single key belongs to app menus. Add ⌥ or ⌃ as well."
        }
        return nil
    }

    /// A shortcut has to carry ⌘, ⌥ or ⌃, or it would fire while the user was
    /// typing. Shift alone is not enough, and neither is a bare key.
    static func isAcceptable(keyCode: Int, carbonModifiers: Int) -> Bool {
        unavailableReason(keyCode: keyCode, carbonModifiers: carbonModifiers) == nil
    }

    /// The spelling of a key when there is no event to hand, used by the reserved
    /// list's messages. Only the named keys can be resolved this way; anything else
    /// depends on the keyboard layout, so it is described rather than spelled.
    static func keyLabel(forKeyCode keyCode: Int) -> String {
        specialNames[keyCode] ?? asciiNames[keyCode] ?? "that key"
    }

    /// The unshifted character on a US layout for the keys named in `reserved`.
    /// Deliberately not a full table: it exists only so a refusal message can name
    /// the combination it is refusing.
    private static let asciiNames: [Int: String] = [
        kVK_ANSI_Q: "Q", kVK_ANSI_W: "W", kVK_ANSI_H: "H", kVK_ANSI_M: "M",
        kVK_ANSI_D: "D", kVK_ANSI_F: "F", kVK_ANSI_Grave: "`",
        kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
    ]
}

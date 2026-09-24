import AppKit
import Carbon.HIToolbox

/// Every persisted key in one place, so a typo cannot silently split a setting
/// into two.
enum DefaultsKey {
    static let outerSlots = "outerSlots"
    static let recents = "recents"
    static let didOnboard = "didOnboard"
    static let hotkeyEnabled = "hotkeyEnabled"
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let hotkeyModifiers = "hotkeyModifiers"
    static let hotkeyLabel = "hotkeyLabel"
    static let colorfulHighlights = "colorfulHighlights"
    static let openLocation = "openLocation"
    static let savedCenterX = "savedCenterX"
    static let savedCenterY = "savedCenterY"
    static let wheelSize = "wheelSize"
    static let glassOpacity = "glassOpacity"
    static let glassTint = "glassTint"
    static let showInDock = "showInDock"
    static let outerSlotCount = "outerSlotCount"
    static let innerSlotCount = "innerSlotCount"
    static let outerRotationSteps = "outerRotationSteps"
    static let innerRotationSteps = "innerRotationSteps"
    static let spinOnOpen = "spinOnOpen"
    static let scrollToSpin = "scrollToSpin"
    static let showOrb = "showOrb"
    static let orbSize = "orbSize"
    static let orbIdleOpacity = "orbIdleOpacity"
    static let orbTucksAtEdge = "orbTucksAtEdge"
    static let orbHiddenFromCapture = "orbHiddenFromCapture"
    static let orbDisplayID = "orbDisplayID"
    static let orbDisplayName = "orbDisplayName"
    static let orbFractionX = "orbFractionX"
    static let orbFractionY = "orbFractionY"
}

/// Where the wheel appears when it opens.
enum OpenLocation: String, CaseIterable {
    /// Wherever the pointer is. Only used for the keyboard shortcut: the pointer
    /// sits in the menu bar when the ring is opened by clicking the icon, and
    /// centring there would push the wheel off the top of the screen.
    case pointer
    /// The spot the user last dragged the wheel to, remembered as a fraction of
    /// the screen so it survives a resolution change or a different display.
    case saved
    /// The middle of whichever screen the pointer is on.
    case center

    var label: String {
        switch self {
        case .pointer: return "Where the pointer is"
        case .saved: return "The position I dragged it to"
        case .center: return "The centre of the screen"
        }
    }
}

/// An optional colour wash over the frosted bands.
enum GlassTint: String, CaseIterable {
    case none, blue, purple, green, graphite

    var label: String {
        switch self {
        case .none: return "None"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .green: return "Green"
        case .graphite: return "Graphite"
        }
    }

    /// nil means "leave the system material alone".
    var color: NSColor? {
        switch self {
        case .none: return nil
        case .blue: return NSColor(srgbRed: 0.16, green: 0.44, blue: 0.92, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.52, green: 0.28, blue: 0.86, alpha: 1)
        case .green: return NSColor(srgbRed: 0.16, green: 0.62, blue: 0.40, alpha: 1)
        case .graphite: return NSColor(srgbRed: 0.30, green: 0.32, blue: 0.36, alpha: 1)
        }
    }
}

/// Whether Chakra keeps an icon in the Dock, and the only place that changes it.
///
/// Two controls set this — the menu-bar menu and the settings window — and they
/// must not drift apart, so the stored value, the activation policy and the
/// notification that tells other windows to catch up all move together here.
enum DockPresence {
    /// Applies a choice to the running app without changing what is stored. Used
    /// at launch, where the value has just been read.
    ///
    /// Returns whether macOS accepted it. `setActivationPolicy` genuinely refuses
    /// some transitions, and a refusal that went unnoticed would leave the stored
    /// value, the menu checkmark and the checkbox all claiming a Dock icon that is
    /// not there — across launches, since nothing would ever re-check.
    @discardableResult
    static func apply(_ show: Bool) -> Bool {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    /// Stores the choice, applies it, and announces it. The single place that
    /// changes any of the three, so the menu and the settings window cannot drift.
    ///
    /// Returns what is now true, which may not be what was asked for.
    @discardableResult
    static func set(_ show: Bool, in settings: Settings) -> Bool {
        let accepted = apply(show)
        // Only stored once macOS has agreed, so a refused change does not persist a
        // Dock icon that does not exist.
        settings.showInDock = accepted ? show : (NSApp.activationPolicy() == .regular)

        // Changing the activation policy drops the app's activation, which would
        // otherwise leave an open window sitting behind its neighbours. Keyed on
        // there already being a key window rather than on any visible one: a status
        // item owns a window of its own, so "is anything visible" is always true.
        // Toggled from the menu-bar menu with nothing on screen, an unconditional
        // activate would make Chakra frontmost with no windows and replace the
        // user's menu bar with Chakra's.
        if let key = NSApp.keyWindow, key.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            key.makeKeyAndOrderFront(nil)
        }
        settings.postDidChange()
        return settings.showInDock
    }
}

/// Typed, clamped access to everything the user can change.
///
/// A struct over `UserDefaults` rather than scattered `bool(forKey:)` calls: the
/// clamping and the wrong-type fallbacks live in one place, and the whole thing
/// is testable against a scratch defaults suite.
struct Settings {
    /// Posted whenever a setting is changed from somewhere other than the control
    /// showing it.
    ///
    /// Needed because a setting has more than one way in: the Dock icon is in both
    /// the menu-bar menu and the settings window, and dragging the wheel sets where
    /// it opens. Without this the settings window kept showing whatever it was
    /// built with, so the user saw a popup reading "where the pointer is" for a
    /// wheel that in fact opened where they had dropped it, and a disabled "Forget
    /// Saved Position" button for a position that existed.
    static let didChangeNotification = Notification.Name("local.chakra.settingsDidChange")

    /// Announces a change made outside the control that displays it.
    func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Below 0.7 the icons stop being recognisable; above 1.4 the wheel exceeds a
    /// laptop screen's short side. The screen-fit clamp still applies on top.
    static let minWheelSize = 0.7
    static let maxWheelSize = 1.4

    /// How many apps each ring can hold.
    ///
    /// The upper bounds are the most that fit without the hovered icon — grown by
    /// half — touching its neighbour: ten slots on the outer ring leave 110 points
    /// between centres for a 106-point plate, and seven on the inner leave 90 for
    /// 82. A geometry test pins both, so raising either bound fails the build
    /// rather than shipping icons that overlap.
    static let minOuterSlots = 4
    static let maxOuterSlots = 10
    static let defaultOuterSlots = 8
    /// The fewest apps the outer ring may be reduced to.
    ///
    /// Three rather than one because a ring with one app in it is not a ring — the
    /// gesture the whole app is built on, "flick in a direction", stops meaning
    /// anything. Enforced on removal only: a fresh ring starts empty and is filled
    /// by onboarding, so this cannot be an invariant of the stored data.
    static let minOuterApps = 3
    /// Zero is allowed: it turns the recents ring off and leaves a plain circle.
    static let minInnerSlots = 0
    static let maxInnerSlots = 7
    static let defaultInnerSlots = 5
    /// Carbon's `kVK_Space` with the Option modifier: the shipped default.
    static let defaultHotkeyKeyCode = Int(kVK_Space)
    static let defaultHotkeyModifiers = Int(optionKey)

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var didOnboard: Bool {
        get { defaults.bool(forKey: DefaultsKey.didOnboard, default: false) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.didOnboard) }
    }

    /// How many slots the outer ring shows.
    ///
    /// Reducing it hides the tail of the ring rather than erasing it, so raising the
    /// number again brings the same apps back. `OuterRing` keeps `maxOuterSlots`
    /// entries whatever this says.
    var outerSlotCount: Int {
        get {
            Int(defaults.double(forKey: DefaultsKey.outerSlotCount,
                                default: Double(Self.defaultOuterSlots),
                                min: Double(Self.minOuterSlots),
                                max: Double(Self.maxOuterSlots)))
        }
        nonmutating set {
            defaults.set(min(max(newValue, Self.minOuterSlots), Self.maxOuterSlots),
                         forKey: DefaultsKey.outerSlotCount)
        }
    }

    var innerSlotCount: Int {
        get {
            Int(defaults.double(forKey: DefaultsKey.innerSlotCount,
                                default: Double(Self.defaultInnerSlots),
                                min: Double(Self.minInnerSlots),
                                max: Double(Self.maxInnerSlots)))
        }
        nonmutating set {
            defaults.set(min(max(newValue, Self.minInnerSlots), Self.maxInnerSlots),
                         forKey: DefaultsKey.innerSlotCount)
        }
    }

    /// The floor is not zero: an orb at zero opacity is a button the user cannot
    /// find, and they would have to guess that pointing at nothing brings it back.
    static let minOrbOpacity = 0.15

    /// Whether the floating orb is on screen at all. Off by default, because an
    /// always-visible overlay is not something to give someone unasked.
    var showOrb: Bool {
        get { defaults.bool(forKey: DefaultsKey.showOrb, default: false) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.showOrb) }
    }

    var orbSize: Double {
        get {
            defaults.double(forKey: DefaultsKey.orbSize,
                            default: Double(OrbGeometry.defaultSize),
                            min: Double(OrbGeometry.minSize),
                            max: Double(OrbGeometry.maxSize))
        }
        nonmutating set {
            defaults.set(Self.sane(newValue, min: Double(OrbGeometry.minSize),
                                   max: Double(OrbGeometry.maxSize),
                                   fallback: Double(OrbGeometry.defaultSize)),
                         forKey: DefaultsKey.orbSize)
        }
    }

    var orbIdleOpacity: Double {
        get {
            defaults.double(forKey: DefaultsKey.orbIdleOpacity, default: 0.35,
                            min: Self.minOrbOpacity, max: 1)
        }
        nonmutating set {
            defaults.set(Self.sane(newValue, min: Self.minOrbOpacity, max: 1, fallback: 0.35),
                         forKey: DefaultsKey.orbIdleOpacity)
        }
    }

    var orbTucksAtEdge: Bool {
        get { defaults.bool(forKey: DefaultsKey.orbTucksAtEdge, default: true) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.orbTucksAtEdge) }
    }

    /// Hides the orb's pixels from screen recordings. On by default, at the cost
    /// that the user's own screenshots will not contain it either — which is why
    /// it is a setting rather than a constant.
    var orbHiddenFromCapture: Bool {
        get { defaults.bool(forKey: DefaultsKey.orbHiddenFromCapture, default: true) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.orbHiddenFromCapture) }
    }

    /// The display the orb was last on. Display ids are not stable across reboots
    /// or GPU switches, which is why the name below is stored as well.
    var orbDisplayID: Int {
        get { Int(defaults.double(forKey: DefaultsKey.orbDisplayID, default: 0,
                                  min: 0, max: Double(Int32.max))) }
        nonmutating set {
            // Clamped on the way out as well as on the way in, like every other bounded
            // setting. Guarding only the getter still let a nonsense id reach the plist, and
            // anything reading that file without going through `Settings` — a support dump,
            // `defaults read`, a future migration — would have seen the nonsense.
            //
            // `Self.sane` is not used: it exists to replace NaN, which an `Int` cannot hold,
            // so a plain clamp is the whole job here.
            defaults.set(Swift.min(Swift.max(newValue, 0), Int(Int32.max)),
                         forKey: DefaultsKey.orbDisplayID)
        }
    }

    var orbDisplayName: String {
        get { (defaults.object(forKey: DefaultsKey.orbDisplayName) as? String) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.orbDisplayName) }
    }

    /// The orb's position as a fraction of its display's travel, or nil if it has
    /// never been placed. Nil rather than a default corner, so a first run can put
    /// the orb somewhere sensible instead of somewhere arbitrary.
    var orbFraction: CGPoint? {
        get {
            guard let x = (defaults.object(forKey: DefaultsKey.orbFractionX) as? NSNumber)?.doubleValue,
                  let y = (defaults.object(forKey: DefaultsKey.orbFractionY) as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }
        nonmutating set {
            guard let newValue, newValue.x.isFinite, newValue.y.isFinite else {
                clearOrbPosition()
                return
            }
            defaults.set(min(max(Double(newValue.x), 0), 1), forKey: DefaultsKey.orbFractionX)
            defaults.set(min(max(Double(newValue.y), 0), 1), forKey: DefaultsKey.orbFractionY)
        }
    }

    func clearOrbPosition() {
        defaults.removeObject(forKey: DefaultsKey.orbFractionX)
        defaults.removeObject(forKey: DefaultsKey.orbFractionY)
        defaults.removeObject(forKey: DefaultsKey.orbDisplayID)
        defaults.removeObject(forKey: DefaultsKey.orbDisplayName)
    }

    /// How many slots each ring is turned from its resting position.
    ///
    /// Stored as whole slots rather than as an angle, for two reasons: a ring only
    /// ever comes to rest on a slot, and a slot offset stays meaningful when the
    /// user changes how many slots the ring has, where a saved angle would land
    /// between two apps.
    /// The furthest a ring may be recorded as turned. Named rather than written twice,
    /// because the getter and the setter both clamp to it and a literal in each is how
    /// they drift apart.
    static let maxRotationSteps = 1000

    var outerRotationSteps: Int {
        get { Int(defaults.double(forKey: DefaultsKey.outerRotationSteps, default: 0,
                                  min: Double(-Self.maxRotationSteps),
                                  max: Double(Self.maxRotationSteps))) }
        // Clamped on the way out as well as in, which is the rule `orbDisplayID` states
        // and which these two used to break: the getter alone kept the app sane, but a
        // nonsense value still reached the plist, where `defaults read`, a support dump
        // or a future migration would find it.
        nonmutating set {
            defaults.set(Swift.min(Swift.max(newValue, -Self.maxRotationSteps),
                                   Self.maxRotationSteps),
                         forKey: DefaultsKey.outerRotationSteps)
        }
    }

    var innerRotationSteps: Int {
        get { Int(defaults.double(forKey: DefaultsKey.innerRotationSteps, default: 0,
                                  min: Double(-Self.maxRotationSteps),
                                  max: Double(Self.maxRotationSteps))) }
        nonmutating set {
            defaults.set(Swift.min(Swift.max(newValue, -Self.maxRotationSteps),
                                   Self.maxRotationSteps),
                         forKey: DefaultsKey.innerRotationSteps)
        }
    }

    /// The rotation to draw a ring at, in radians, for a given slot count.
    ///
    /// Taken modulo the count so a ring that was turned five notches and then cut
    /// down to four slots comes back to a sensible place rather than spinning on
    /// past its own start.
    func rotation(for ring: Ring, slotCount: Int) -> CGFloat {
        guard slotCount > 0 else { return 0 }
        let steps = ring == .outer ? outerRotationSteps : innerRotationSteps
        let wrapped = ((steps % slotCount) + slotCount) % slotCount
        return 2 * CGFloat.pi * CGFloat(wrapped) / CGFloat(slotCount)
    }

    /// Whether the wheel sweeps into place when it opens.
    var spinOnOpen: Bool {
        get { defaults.bool(forKey: DefaultsKey.spinOnOpen, default: true) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.spinOnOpen) }
    }

    /// Whether scrolling over a ring turns it.
    var scrollToSpin: Bool {
        get { defaults.bool(forKey: DefaultsKey.scrollToSpin, default: true) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.scrollToSpin) }
    }

    var colorfulHighlights: Bool {
        // On by default: pointing at Slack should look like Slack. The plain accent
        // colour is still available for anyone who wants one colour throughout.
        get { defaults.bool(forKey: DefaultsKey.colorfulHighlights, default: true) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.colorfulHighlights) }
    }

    var hotkeyEnabled: Bool {
        get { defaults.bool(forKey: DefaultsKey.hotkeyEnabled, default: true) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.hotkeyEnabled) }
    }

    var showInDock: Bool {
        get { defaults.bool(forKey: DefaultsKey.showInDock, default: false) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.showInDock) }
    }

    /// 0 leaves the glass out altogether, so the icons float on the desktop.
    var glassOpacity: Double {
        get { defaults.double(forKey: DefaultsKey.glassOpacity, default: 0.85, min: 0, max: 1) }
        nonmutating set {
            defaults.set(Self.sane(newValue, min: 0, max: 1, fallback: 0.85),
                         forKey: DefaultsKey.glassOpacity)
        }
    }

    var wheelSize: Double {
        get {
            defaults.double(forKey: DefaultsKey.wheelSize, default: 1,
                            min: Self.minWheelSize, max: Self.maxWheelSize)
        }
        nonmutating set {
            defaults.set(Self.sane(newValue, min: Self.minWheelSize, max: Self.maxWheelSize,
                                   fallback: 1),
                         forKey: DefaultsKey.wheelSize)
        }
    }

    /// Clamps a value on its way to disk. Non-finite values are replaced rather
    /// than clamped: NaN compares false with everything, so `min` and `max` would
    /// hand it straight through and a NaN would end up in the stored plist.
    private static func sane(_ value: Double, min lower: Double, max upper: Double,
                             fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }

    var glassTint: GlassTint {
        get {
            GlassTint(rawValue: defaults.choice(forKey: DefaultsKey.glassTint,
                                                default: GlassTint.none.rawValue,
                                                allowed: GlassTint.allCases.map(\.rawValue)))
                ?? .none
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: DefaultsKey.glassTint) }
    }

    /// Defaults to the centre of the screen. The pointer made sense when the only
    /// ways in were a keyboard shortcut and the menu-bar icon; with an orb parked
    /// at a screen edge, the pointer is a poor place to centre a wheel.
    var openLocation: OpenLocation {
        get {
            OpenLocation(rawValue: defaults.choice(forKey: DefaultsKey.openLocation,
                                                   default: OpenLocation.center.rawValue,
                                                   allowed: OpenLocation.allCases.map(\.rawValue)))
                ?? .center
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: DefaultsKey.openLocation) }
    }

    var hotkeyKeyCode: Int {
        get {
            Int(defaults.double(forKey: DefaultsKey.hotkeyKeyCode,
                                default: Double(Self.defaultHotkeyKeyCode),
                                min: 0, max: 127))
        }
        nonmutating set {
            defaults.set(min(max(newValue, 0), 127), forKey: DefaultsKey.hotkeyKeyCode)
        }
    }

    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var hotkeyModifiers: Int {
        get {
            Int(defaults.double(forKey: DefaultsKey.hotkeyModifiers,
                                default: Double(Self.defaultHotkeyModifiers),
                                min: 0, max: 0xFFFF))
        }
        nonmutating set {
            defaults.set(min(max(newValue, 0), 0xFFFF), forKey: DefaultsKey.hotkeyModifiers)
        }
    }

    /// The longest a key's spelling may be. "Page Down" is the longest real one at
    /// nine characters; the cap exists to stop a pasted paragraph reaching the plist.
    static let maxHotkeyLabelLength = 12

    /// How the shortcut's key is spelled. Captured when the shortcut is recorded,
    /// because the character a key produces depends on the keyboard layout and
    /// only the key press itself knows it.
    var hotkeyLabel: String {
        get { Self.saneHotkeyLabel(defaults.object(forKey: DefaultsKey.hotkeyLabel) as? String) }
        // Validated on the way out through the same function the getter uses, so the two
        // cannot disagree about what a usable label is. Previously the setter stored any
        // string at all and only the getter rejected it.
        nonmutating set {
            defaults.set(Self.saneHotkeyLabel(newValue), forKey: DefaultsKey.hotkeyLabel)
        }
    }

    /// The one definition of an acceptable key spelling, shared by the getter and the
    /// setter. Falls back to the shipped default rather than to an empty string, which
    /// would leave the shortcut displayed as its modifiers alone.
    private static func saneHotkeyLabel(_ value: String?) -> String {
        guard let value else { return "Space" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxHotkeyLabelLength else { return "Space" }
        return trimmed
    }

    /// The shortcut as the user reads it, e.g. "⌥Space".
    var hotkeyDisplay: String {
        Shortcut.display(carbonModifiers: hotkeyModifiers, keyLabel: hotkeyLabel)
    }

    /// The dragged-to position, as a fraction of the screen in each axis. nil
    /// until the user has actually moved the wheel, so "saved position" can fall
    /// back to the centre instead of to a corner.
    var savedCenterFraction: CGPoint? {
        get {
            guard defaults.object(forKey: DefaultsKey.savedCenterX) != nil,
                  defaults.object(forKey: DefaultsKey.savedCenterY) != nil else { return nil }
            let x = defaults.double(forKey: DefaultsKey.savedCenterX, default: 0.5, min: 0, max: 1)
            let y = defaults.double(forKey: DefaultsKey.savedCenterY, default: 0.5, min: 0, max: 1)
            return CGPoint(x: x, y: y)
        }
        nonmutating set {
            guard let newValue, newValue.x.isFinite, newValue.y.isFinite else {
                defaults.removeObject(forKey: DefaultsKey.savedCenterX)
                defaults.removeObject(forKey: DefaultsKey.savedCenterY)
                return
            }
            defaults.set(min(max(Double(newValue.x), 0), 1), forKey: DefaultsKey.savedCenterX)
            defaults.set(min(max(Double(newValue.y), 0), 1), forKey: DefaultsKey.savedCenterY)
        }
    }
}

extension UserDefaults {
    /// `bool(forKey:)` cannot distinguish "false" from "never set", which matters
    /// for a setting whose default is on. A value of the wrong type also has to
    /// fall back to the default rather than read as `false`, or a stray string
    /// under `hotkeyEnabled` would silently disable the shortcut.
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        switch object(forKey: key) {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        default: return fallback
        }
    }

    /// A number clamped into a range, with the same wrong-type discipline.
    func double(forKey key: String, default fallback: Double,
                min lower: Double, max upper: Double) -> Double {
        guard let value = (object(forKey: key) as? NSNumber)?.doubleValue,
              value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }

    /// One of a fixed set of names, so an unknown or wrong-typed value cannot put
    /// the app into a state it has no code for.
    func choice(forKey key: String, default fallback: String, allowed: [String]) -> String {
        guard let value = object(forKey: key) as? String, allowed.contains(value) else {
            return fallback
        }
        return value
    }
}

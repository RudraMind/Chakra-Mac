import Foundation

/// Which of the two concentric rings a slot belongs to.
enum Ring: Equatable {
    /// The automatically maintained recents ring.
    case inner
    /// The eight fixed, user-chosen slots.
    case outer
}

/// What sits under a point in the wheel.
enum HitTarget: Equatable {
    /// The see-through hole. Clicking here dismisses.
    case center
    /// Beyond the glass. Clicking here dismisses.
    case outside
    case slot(Ring, Int)
}

/// Every measurement the wheel needs, and nothing else — no view state, no
/// AppKit. Drawing and hit-testing both read from one instance, which is what
/// keeps them from ever disagreeing about where a slot is.
struct RingGeometry: Equatable {
    /// How many slots each ring is divided into.
    ///
    /// Per-instance rather than fixed, because the user chooses these in Settings.
    /// Both drawing and hit-testing read them from the same instance, so they cannot
    /// disagree about how wide a slot's sector is.
    let outerSlotCount: Int
    let innerSlotCount: Int

    /// How far each ring is turned, clockwise, in radians. Zero puts slot 0 at
    /// twelve o'clock.
    let outerRotation: CGFloat
    let innerRotation: CGFloat

    /// The shipped counts, used where no instance is to hand.
    static let defaultOuterSlotCount = 8
    static let defaultInnerSlotCount = 5

    /// Unscaled reference measurements, in points, from the design spec.
    static let baseHoleRadius: CGFloat = 72
    static let baseInnerRadius: CGFloat = 100
    static let baseOuterRadius: CGFloat = 175
    static let baseInnerIconSize: CGFloat = 40
    static let baseOuterIconSize: CGFloat = 56
    static let baseDiscRadius: CGFloat = 227
    /// How far past the glass edge a click still counts as the outer ring.
    static let baseGrace: CGFloat = 10
    /// Clearance kept between the glass and the screen edge.
    static let baseMargin: CGFloat = 8
    /// Glass kept around an icon, which is what gives each ring its own band.
    static let basePadding: CGFloat = 8
    /// The centre pill, whose corners have to stay inside the hole. These live
    /// here rather than in the drawing code so the test that proves the pill
    /// cannot overlap an icon reads the same numbers the drawing uses.
    static let basePillHeight: CGFloat = 26
    static let basePillTextWidth: CGFloat = 104
    static let basePillTextInset: CGFloat = 12

    /// How much the icon under the pointer grows, and how much plate is drawn round
    /// it. Both live here rather than in the drawing code so the test that proves a
    /// hovered icon cannot touch its neighbour reads the same numbers the drawing
    /// uses — otherwise raising a slot count would quietly break the layout.
    ///
    /// Half again is the largest growth that fits. At ten outer slots the plate is 106
    /// points across and adjacent centres are 108.2 points apart — a margin of 2.2
    /// points, which is the tightest case in the whole wheel. (The inner ring at seven
    /// slots has 4.8 points to spare.)
    ///
    /// 108.2 is the straight-line distance between the two centres, which is what
    /// `geometry/slot-crowding` measures with `hypot`. The arc between them is 110.0,
    /// and quoting that instead would overstate the headroom by nearly two points —
    /// enough to matter, since 2.2 is all there is.
    static let hoverGrowth: CGFloat = 1.5
    static let baseHighlightInset: CGFloat = 11

    /// The smallest and largest the wheel may ever be drawn. The lower bound
    /// keeps icons recognisable; the upper bound is the largest the size slider
    /// offers, and a screen too small for it shrinks the wheel further.
    static let minScale: CGFloat = 0.2
    static let maxScale: CGFloat = 1.4

    let scale: CGFloat
    let holeRadius: CGFloat
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let innerIconSize: CGFloat
    let outerIconSize: CGFloat
    let discRadius: CGFloat
    /// The two glass bands, as radii. Each ring gets its own band with a
    /// see-through gap between them, so the inner ring reads as its own circle
    /// rather than as icons floating on one big disc.
    let innerBandInner: CGFloat
    let innerBandOuter: CGFloat
    let outerBandInner: CGFloat
    let outerBandOuter: CGFloat
    /// Distance that separates the two rings: the midpoint of the empty band
    /// between the inner icons' outer edge and the outer icons' inner edge.
    let ringBoundary: CGFloat
    let grace: CGFloat
    let margin: CGFloat
    /// The centre pill at its widest, which is the case the hole has to clear.
    let pillMaxWidth: CGFloat
    let pillHeight: CGFloat
    let pillMaxTextWidth: CGFloat
    let pillTextInset: CGFloat

    init(scale: CGFloat = 1,
         outerSlotCount: Int = RingGeometry.defaultOuterSlotCount,
         innerSlotCount: Int = RingGeometry.defaultInnerSlotCount,
         outerRotation: CGFloat = 0,
         innerRotation: CGFloat = 0) {
        // A non-finite rotation would put every slot at a NaN coordinate, and a
        // CGRect built from one is undefined rather than merely wrong.
        self.outerRotation = outerRotation.isFinite ? outerRotation : 0
        self.innerRotation = innerRotation.isFinite ? innerRotation : 0
        // A scale outside this range would produce a ring that is inverted or
        // bigger than any screen, so clamp rather than trust the caller.
        let s = scale.isFinite ? min(max(scale, Self.minScale), Self.maxScale) : 1
        self.scale = s
        // Clamped rather than trusted for the same reason as the scale: a count of
        // zero on the outer ring would divide by zero in `angle`, and a negative one
        // would put slots in a mirror image of the wheel.
        self.outerSlotCount = min(max(outerSlotCount, Settings.minOuterSlots),
                                  Settings.maxOuterSlots)
        self.innerSlotCount = min(max(innerSlotCount, Settings.minInnerSlots),
                                  Settings.maxInnerSlots)
        holeRadius = Self.baseHoleRadius * s
        innerRadius = Self.baseInnerRadius * s
        outerRadius = Self.baseOuterRadius * s
        innerIconSize = Self.baseInnerIconSize * s
        outerIconSize = Self.baseOuterIconSize * s
        discRadius = Self.baseDiscRadius * s
        grace = Self.baseGrace * s
        margin = Self.baseMargin * s
        ringBoundary = ((Self.baseInnerRadius + Self.baseInnerIconSize / 2)
                        + (Self.baseOuterRadius - Self.baseOuterIconSize / 2)) / 2 * s
        innerBandInner = (Self.baseInnerRadius - Self.baseInnerIconSize / 2
                          - Self.basePadding) * s
        innerBandOuter = (Self.baseInnerRadius + Self.baseInnerIconSize / 2
                          + Self.basePadding) * s
        outerBandInner = (Self.baseOuterRadius - Self.baseOuterIconSize / 2
                          - Self.basePadding) * s
        outerBandOuter = (Self.baseOuterRadius + Self.baseOuterIconSize / 2
                          + Self.basePadding) * s
        pillHeight = Self.basePillHeight * s
        pillMaxTextWidth = Self.basePillTextWidth * s
        pillTextInset = Self.basePillTextInset * s
        pillMaxWidth = (Self.basePillTextWidth + 2 * Self.basePillTextInset) * s
    }

    /// How far the pill's bounding box reaches from the centre at its widest.
    /// Must stay under `holeRadius`, or the name would cover an inner icon.
    var pillCornerDistance: CGFloat {
        hypot(pillMaxWidth / 2, pillHeight / 2)
    }

    /// The largest scale a screen can hold, ignoring what the user asked for.
    static func fittingScale(forScreen size: CGSize) -> CGFloat {
        // Both dimensions are checked, not just the shorter one: `min` hands NaN
        // through in one argument order and swallows it in the other, so testing
        // only the result would depend on which side the NaN arrived on.
        guard size.width.isFinite, size.height.isFinite else { return 1 }
        let shorter = min(size.width, size.height)
        guard shorter > 0 else { return 1 }
        return min(max((shorter - 2 * baseMargin) / (2 * baseDiscRadius), minScale), maxScale)
    }

    /// The scale to draw at: the size the user chose, shrunk if the screen cannot
    /// hold it. Both are resolved here so drawing and hit-testing can never work
    /// from different numbers.
    static func scale(forScreen size: CGSize, userSize: CGFloat = 1) -> CGFloat {
        let desired = userSize.isFinite ? min(max(userSize, minScale), maxScale) : 1
        return min(desired, fittingScale(forScreen: size))
    }

    func slotCount(_ ring: Ring) -> Int {
        ring == .outer ? outerSlotCount : innerSlotCount
    }

    func radius(_ ring: Ring) -> CGFloat {
        ring == .outer ? outerRadius : innerRadius
    }

    func iconSize(_ ring: Ring) -> CGFloat {
        ring == .outer ? outerIconSize : innerIconSize
    }

    /// How far each ring is turned from its resting position, clockwise, in
    /// radians.
    ///
    /// Part of the geometry rather than the view, because both drawing and
    /// hit-testing have to apply it. Keeping it anywhere else is how a turned ring
    /// ends up launching the app that used to be under the pointer.
    func rotation(_ ring: Ring) -> CGFloat {
        ring == .outer ? outerRotation : innerRotation
    }

    /// Slot 0 sits at twelve o'clock when the ring is at rest; indices advance
    /// clockwise, and the whole ring is offset by its rotation.
    func angle(ring: Ring, index: Int) -> CGFloat {
        let n = slotCount(ring)
        guard n > 0 else { return CGFloat.pi / 2 }
        return CGFloat.pi / 2 - 2 * CGFloat.pi * CGFloat(index) / CGFloat(n) - rotation(ring)
    }

    func slotCenter(ring: Ring, index: Int, center: CGPoint) -> CGPoint {
        let a = angle(ring: ring, index: index)
        let r = radius(ring)
        return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    /// Maps an absolute angle to the nearest slot, measuring clockwise from
    /// twelve o'clock, with the ring's own rotation taken out first.
    static func slotIndex(angle: CGFloat, count: Int, rotation: CGFloat = 0) -> Int {
        guard count > 0, angle.isFinite, rotation.isFinite else { return 0 }
        var turns = (CGFloat.pi / 2 - angle - rotation) / (2 * CGFloat.pi)
        turns -= floor(turns)                       // normalise into [0, 1)
        // A point a hair counter-clockwise of twelve o'clock rounds up to
        // `count`, so the modulo is what wraps it back to slot 0.
        return Int((turns * CGFloat(count)).rounded()) % count
    }

    /// The angle between two adjacent slots: how far one notch of rotation turns
    /// the ring.
    func step(_ ring: Ring) -> CGFloat {
        let n = slotCount(ring)
        guard n > 0 else { return 0 }
        return 2 * CGFloat.pi / CGFloat(n)
    }

    /// Rounds a rotation to the nearest slot, so a ring never rests between two
    /// apps.
    func snapped(_ rotation: CGFloat, ring: Ring) -> CGFloat {
        let stepSize = step(ring)
        guard stepSize > 0, rotation.isFinite else { return 0 }
        return (rotation / stepSize).rounded() * stepSize
    }

    /// Distance from the centre chooses the ring; angle chooses the slot.
    func hit(_ point: CGPoint, center: CGPoint) -> HitTarget {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance.isFinite else { return .outside }
        if distance < holeRadius { return .center }
        // Measured from the outer band's edge, not from `discRadius`: the glass
        // stops at the band, and desktop that is visibly not the wheel must not
        // launch anything.
        if distance > outerBandOuter + grace { return .outside }
        let ring: Ring = distance < ringBoundary ? .inner : .outer
        return .slot(ring, Self.slotIndex(angle: atan2(dy, dx), count: slotCount(ring),
                                          rotation: rotation(ring)))
    }

    /// The same geometry, turned. Cheap: a value type with no stored images.
    func rotated(outer: CGFloat, inner: CGFloat) -> RingGeometry {
        RingGeometry(scale: scale, outerSlotCount: outerSlotCount,
                     innerSlotCount: innerSlotCount,
                     outerRotation: outer, innerRotation: inner)
    }

    /// Keeps the whole wheel on screen. If the screen is too small to hold it
    /// even after scaling, the wheel is centred instead of clamped, because the
    /// lower bound would otherwise exceed the upper one.
    func clampCenter(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let inset = discRadius + margin
        // A non-finite coordinate would otherwise pass straight through into a
        // window frame. Fall back to the middle of the screen.
        let px = point.x.isFinite ? point.x : (size.width.isFinite ? size.width / 2 : 0)
        let py = point.y.isFinite ? point.y : (size.height.isFinite ? size.height / 2 : 0)
        let x = size.width >= 2 * inset
            ? min(max(px, inset), size.width - inset)
            : size.width / 2
        let y = size.height >= 2 * inset
            ? min(max(py, inset), size.height - inset)
            : size.height / 2
        // A screen size that is not a number cannot constrain anything. Keeping the
        // requested point beats handing back NaN, which would make the window frame
        // invalid and leave the wheel invisible with nothing to explain it.
        return CGPoint(x: x.isFinite ? x : px, y: y.isFinite ? y : py)
    }

    /// Turns a remembered position — a fraction of the screen in each axis — into
    /// a centre point that is guaranteed to be on screen. Fractions rather than
    /// points so a saved position survives a resolution change or a move to a
    /// different display.
    func center(fromFraction fraction: CGPoint, in size: CGSize) -> CGPoint {
        let fx = fraction.x.isFinite ? min(max(fraction.x, 0), 1) : 0.5
        let fy = fraction.y.isFinite ? min(max(fraction.y, 0), 1) : 0.5
        return clampCenter(CGPoint(x: size.width * fx, y: size.height * fy), in: size)
    }

    /// The inverse of `center(fromFraction:in:)`.
    static func fraction(ofCenter center: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0,
              center.x.isFinite, center.y.isFinite else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max(center.x / size.width, 0), 1),
                       y: min(max(center.y / size.height, 0), 1))
    }
}

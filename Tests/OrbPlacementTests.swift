import Foundation

/// A 1440x900 screen with a 25pt menu bar and a 70pt Dock taken out, which is
/// the shape `NSScreen.visibleFrame` actually has. Deliberately not at the
/// origin: a bug that assumes `visible.origin == .zero` passes against a
/// zero-origin rect and fails on a second display.
private let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
private let size: CGFloat = 56

func runOrbPlacementTests() {
    suite("orb-placement/clamp") {
        // A point already inside is left exactly where it is.
        expectPoint(OrbPlacement.clamp(CGPoint(x: 600, y: 400), size: size, in: visible),
                    CGPoint(x: 600, y: 400), "an interior origin is untouched")

        // Each edge pushes the whole orb back inside, not just its origin.
        expectPoint(OrbPlacement.clamp(CGPoint(x: -50, y: 400), size: size, in: visible),
                    CGPoint(x: 0, y: 400), "the left edge clamps to minX")
        expectPoint(OrbPlacement.clamp(CGPoint(x: 5000, y: 400), size: size, in: visible),
                    CGPoint(x: 1440 - size, y: 400), "the right edge leaves room for the orb")
        expectPoint(OrbPlacement.clamp(CGPoint(x: 600, y: -900), size: size, in: visible),
                    CGPoint(x: 600, y: 70), "the bottom clamps to the visible minY")
        expectPoint(OrbPlacement.clamp(CGPoint(x: 600, y: 5000), size: size, in: visible),
                    CGPoint(x: 600, y: 70 + 805 - size), "the top leaves room for the orb")

        // A screen smaller than the orb must not produce an inverted range.
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
        let clamped = OrbPlacement.clamp(CGPoint(x: 100, y: 100), size: size, in: tiny)
        expect(clamped.x.isFinite && clamped.y.isFinite,
               "a screen smaller than the orb still yields a real point")

        // Non-finite input must never reach a window frame.
        let broken = OrbPlacement.clamp(CGPoint(x: CGFloat.nan, y: CGFloat.infinity), size: size, in: visible)
        expect(broken.x.isFinite && broken.y.isFinite, "NaN and infinity are repaired")
    }

    suite("orb-placement/nearest-edge") {
        // Inside the threshold of exactly one edge.
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: 4, y: 400),
                                             size: size, in: visible),
                    OrbEdge.left, "an orb against the left reports left")
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: 1440 - size - 4, y: 400),
                                             size: size, in: visible),
                    OrbEdge.right, "an orb against the right reports right")
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: 600, y: 74),
                                             size: size, in: visible),
                    OrbEdge.bottom, "an orb against the bottom reports bottom")
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: 600, y: 70 + 805 - size - 4),
                                             size: size, in: visible),
                    OrbEdge.top, "an orb against the top reports top")

        // Well away from every edge.
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: 600, y: 400),
                                             size: size, in: visible),
                    OrbEdge.none, "an orb in open space reports no edge")

        // Exactly on the threshold counts as parked; one point beyond it does not.
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: OrbPlacement.edgeThreshold, y: 400),
                                             size: size, in: visible),
                    OrbEdge.left, "the threshold itself counts as parked")
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: OrbPlacement.edgeThreshold + 1,
                                                             y: 400),
                                             size: size, in: visible),
                    OrbEdge.none, "one point past the threshold is not parked")

        // A corner is within the threshold of two edges at once. The spec settles
        // the tie in favour of the horizontal edge, because tucking sideways loses
        // less of the orb's silhouette.
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: 2, y: 72),
                                             size: size, in: visible),
                    OrbEdge.left, "a bottom-left corner tucks left, not down")
        expectEqual(OrbPlacement.nearestEdge(origin: CGPoint(x: 1440 - size - 2, y: 72),
                                             size: size, in: visible),
                    OrbEdge.right, "a bottom-right corner tucks right, not down")
    }

    suite("orb-placement/tuck") {
        let offset = size * OrbPlacement.tuckFraction

        expectPoint(OrbPlacement.tuckedOrigin(CGPoint(x: 0, y: 400), size: size,
                                              in: visible, edge: .left),
                    CGPoint(x: -offset, y: 400), "tucking left slides off the left")
        expectPoint(OrbPlacement.tuckedOrigin(CGPoint(x: 1440 - size, y: 400), size: size,
                                              in: visible, edge: .right),
                    CGPoint(x: 1440 - size + offset, y: 400), "tucking right slides off the right")
        expectPoint(OrbPlacement.tuckedOrigin(CGPoint(x: 600, y: 70), size: size,
                                              in: visible, edge: .bottom),
                    CGPoint(x: 600, y: 70 - offset), "tucking down slides off the bottom")
        expectPoint(OrbPlacement.tuckedOrigin(CGPoint(x: 600, y: 400), size: size,
                                              in: visible, edge: .none),
                    CGPoint(x: 600, y: 400), "no edge means no movement")

        // Whatever is left on screen has to be big enough to point at.
        let remaining = size - offset
        expect(remaining >= 18, "the tucked sliver is at least 18pt wide, got \(remaining)")
    }

    suite("orb-placement/fraction-round-trip") {
        // The stored form has to survive a round trip, or the orb drifts a little
        // every time it is saved and restored.
        for origin in [CGPoint(x: 0, y: 70), CGPoint(x: 600, y: 400),
                       CGPoint(x: 1440 - size, y: 70 + 805 - size),
                       CGPoint(x: 17, y: 233)] {
            let f = OrbPlacement.fraction(ofOrigin: origin, size: size, in: visible)
            expect(f.x >= 0 && f.x <= 1 && f.y >= 0 && f.y <= 1,
                   "the fraction for \(origin) is inside the unit square, got \(f)")
            expectPoint(OrbPlacement.origin(fromFraction: f, size: size, in: visible), origin,
                        "origin \(origin) survives a round trip", tolerance: 0.01)
        }

        // The same fraction on a different screen lands proportionally, which is
        // the whole reason for storing a fraction rather than a point.
        let other = CGRect(x: 1440, y: 0, width: 2560, height: 1400)
        let middle = OrbPlacement.origin(fromFraction: CGPoint(x: 0.5, y: 0.5),
                                         size: size, in: other)
        expectClose(middle.x, 1440 + (2560 - size) / 2, "half way across the second screen")
        expectClose(middle.y, (1400 - size) / 2, "half way up the second screen")

        // Out-of-range and non-finite fractions must be repaired, not trusted.
        for f in [CGPoint(x: -1, y: 2), CGPoint(x: CGFloat.nan, y: 0.5),
                  CGPoint(x: 0.5, y: CGFloat.infinity)] {
            let origin = OrbPlacement.origin(fromFraction: f, size: size, in: visible)
            expect(visible.insetBy(dx: -1, dy: -1).contains(origin),
                   "a broken fraction \(f) still lands on screen, got \(origin)")
        }

        // A screen narrower than the orb cannot express a fraction; it must not
        // divide by zero.
        let narrow = CGRect(x: 0, y: 0, width: size, height: size)
        let f = OrbPlacement.fraction(ofOrigin: .zero, size: size, in: narrow)
        expect(f.x.isFinite && f.y.isFinite, "a screen exactly orb-sized yields a real fraction")
    }
}

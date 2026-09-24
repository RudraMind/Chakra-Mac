import Foundation

func runOrbGeometryTests() {
    suite("orb-geometry/sizes") {
        let g = OrbGeometry(size: 56)
        expectClose(g.size, 56, "the default size is kept")
        expectClose(g.radius, 28, "radius is half the size")
        expectClose(g.dotRingRadius, 16.8, "the dot ring sits at 0.30 of the size")
        expectClose(g.leadDotRadius, 4.2, "the lead dot is 0.075 of the size")
        expectClose(g.dotRadius, 3.08, "the other dots are 0.055 of the size")
        expectClose(g.centreDotRadius, 1.96, "the centre dot is 0.035 of the size")

        // Every dot has to fit inside the disc, or the orb would draw outside its
        // own window and be clipped to a square.
        expect(g.dotRingRadius + g.leadDotRadius < g.radius,
               "the lead dot fits inside the disc")

        // The lead dot is larger, so the orb has a visible "up".
        expect(g.leadDotRadius > g.dotRadius, "the lead dot is the larger one")

        // Everything scales, so a bigger orb is the same drawing.
        let big = OrbGeometry(size: 76)
        expectClose(big.dotRingRadius / big.size, g.dotRingRadius / g.size,
                    "the dot ring scales with the orb")

        // Out-of-range sizes are clamped rather than trusted.
        expectClose(OrbGeometry(size: 0).size, OrbGeometry.minSize, "zero clamps up")
        expectClose(OrbGeometry(size: -20).size, OrbGeometry.minSize, "negative clamps up")
        expectClose(OrbGeometry(size: 9000).size, OrbGeometry.maxSize, "absurd clamps down")
        expectClose(OrbGeometry(size: .nan).size, OrbGeometry.defaultSize,
                    "NaN falls back to the default")
    }

    suite("orb-geometry/dots") {
        let g = OrbGeometry(size: 56)
        let c = CGPoint(x: 28, y: 28)

        // Slot 0 at the top, matching the wheel and the menu-bar glyph.
        expectPoint(g.dotCenter(index: 0, count: 8, rotation: 0),
                    CGPoint(x: c.x, y: c.y + g.dotRingRadius), "dot 0 is at the top")

        // Clockwise, like the wheel: dot 2 of 8 is at three o'clock.
        expectPoint(g.dotCenter(index: 2, count: 8, rotation: 0),
                    CGPoint(x: c.x + g.dotRingRadius, y: c.y), "dot 2 of 8 is at three o'clock")

        // Every dot is on the ring, at every count the outer ring supports.
        for count in Settings.minOuterSlots...Settings.maxOuterSlots {
            for i in 0..<count {
                let p = g.dotCenter(index: i, count: count, rotation: 0)
                expectClose(hypot(p.x - c.x, p.y - c.y), g.dotRingRadius,
                            "dot \(i) of \(count) is on the ring")
            }
        }

        // Rotation moves the dots exactly as it moves the wheel's slots: one step
        // carries dot i to where dot i+1 was.
        let step = 2 * CGFloat.pi / 8
        for i in 0..<8 {
            expectPoint(g.dotCenter(index: i, count: 8, rotation: step),
                        g.dotCenter(index: (i + 1) % 8, count: 8, rotation: 0),
                        "one step moves dot \(i) to dot \((i + 1) % 8)'s place")
        }

        // Degenerate counts must not divide by zero or trap.
        let zero = g.dotCenter(index: 0, count: 0, rotation: 0)
        expect(zero.x.isFinite && zero.y.isFinite, "a count of zero yields a real point")
        let negative = g.dotCenter(index: -3, count: 8, rotation: 0)
        expect(negative.x.isFinite && negative.y.isFinite, "a negative index yields a real point")
        let broken = g.dotCenter(index: 0, count: 8, rotation: .nan)
        expect(broken.x.isFinite && broken.y.isFinite, "a NaN rotation yields a real point")
    }

    suite("orb-geometry/hit-test") {
        let g = OrbGeometry(size: 56)
        expect(g.contains(CGPoint(x: 28, y: 28)), "the centre is inside")
        expect(g.contains(CGPoint(x: 28, y: 55)), "just inside the top edge is inside")
        // The square corners of the window must not swallow clicks meant for
        // whatever is behind the orb.
        expect(!g.contains(CGPoint(x: 0, y: 0)), "the bottom-left corner is outside")
        expect(!g.contains(CGPoint(x: 56, y: 56)), "the top-right corner is outside")
        expect(!g.contains(CGPoint(x: 28, y: 60)), "beyond the disc is outside")
        expect(!g.contains(CGPoint(x: CGFloat.nan, y: 28)), "a NaN point is outside")
    }
}

import Foundation

func runGeometryTests() {
    let g = RingGeometry()
    let c = CGPoint(x: 500, y: 400)

    suite("geometry/constants") {
        expectClose(g.holeRadius, 72, "hole radius")
        expectClose(g.innerRadius, 100, "inner radius")
        expectClose(g.outerRadius, 175, "outer radius")
        expectClose(g.innerIconSize, 40, "inner icon size")
        expectClose(g.outerIconSize, 56, "outer icon size")
        expectClose(g.discRadius, 227, "disc radius")
        // Midpoint of the clear band between the two icon rings: (120 + 147) / 2.
        expectClose(g.ringBoundary, 133.5, "ring boundary")
        expectEqual(g.outerSlotCount, 8, "the default outer slot count")
        expectEqual(g.innerSlotCount, 5, "the default inner slot count")
        expectEqual(RingGeometry.defaultOuterSlotCount, 8, "the shipped outer default")
        expectEqual(RingGeometry.defaultInnerSlotCount, 5, "the shipped inner default")

        // A count outside the settings range would divide by zero in `angle` or put
        // the slots in a mirror image of the wheel.
        expectEqual(RingGeometry(outerSlotCount: 0, innerSlotCount: 0).outerSlotCount,
                    Settings.minOuterSlots, "an outer count of zero is clamped")
        expectEqual(RingGeometry(outerSlotCount: 0, innerSlotCount: 0).innerSlotCount, 0,
                    "an inner count of zero is allowed: it switches the ring off")
        expectEqual(RingGeometry(outerSlotCount: -3, innerSlotCount: -3).outerSlotCount,
                    Settings.minOuterSlots, "a negative outer count is clamped")
        expectEqual(RingGeometry(outerSlotCount: 99, innerSlotCount: 99).outerSlotCount,
                    Settings.maxOuterSlots, "an absurd outer count is clamped")
        expectEqual(RingGeometry(outerSlotCount: 99, innerSlotCount: 99).innerSlotCount,
                    Settings.maxInnerSlots, "an absurd inner count is clamped")
    }

    // The reason the slot-count sliders stop where they do. If either bound is
    // raised, or the hover growth increased, this fails rather than shipping a wheel
    // whose icons touch when one is pointed at.
    suite("geometry/slot-crowding") {
        let plate = RingGeometry.baseHighlightInset   // per side, unscaled
        for (ring, count, iconBase) in [
            (Ring.outer, Settings.maxOuterSlots, RingGeometry.baseOuterIconSize),
            (Ring.inner, Settings.maxInnerSlots, RingGeometry.baseInnerIconSize),
        ] {
            let g = RingGeometry(outerSlotCount: Settings.maxOuterSlots,
                                 innerSlotCount: Settings.maxInnerSlots)
            let c = CGPoint(x: 600, y: 600)
            // The straight-line distance between two adjacent slot centres.
            let first = g.slotCenter(ring: ring, index: 0, center: c)
            let second = g.slotCenter(ring: ring, index: 1, center: c)
            let spacing = hypot(second.x - first.x, second.y - first.y)
            // The widest a hovered slot gets: the grown icon plus its plate.
            let widest = iconBase * RingGeometry.hoverGrowth + plate * 2
            expect(spacing >= widest,
                   "\(ring == .outer ? "outer" : "inner") ring at \(count) slots leaves "
                     + "\(String(format: "%.1f", spacing))pt between centres for a "
                     + "\(String(format: "%.1f", widest))pt hovered plate")

            // Slot centres must be distinct at every count above one; a one-slot
            // ring is the degenerate case where index 1 wraps onto index 0.
            for n in 2...count {
                let sparse = RingGeometry(outerSlotCount: max(n, Settings.minOuterSlots),
                                          innerSlotCount: n)
                let a = sparse.slotCenter(ring: ring, index: 0, center: c)
                let b = sparse.slotCenter(ring: ring, index: 1, center: c)
                expect(hypot(b.x - a.x, b.y - a.y) > 1,
                       "\(n) slots leave adjacent centres apart")
            }
        }
    }

    suite("geometry/rotation") {
        let c = CGPoint(x: 500, y: 400)
        let rest = RingGeometry()

        // Zero rotation is the resting wheel: slot 0 at twelve o'clock.
        expectPoint(rest.slotCenter(ring: .outer, index: 0, center: c),
                    CGPoint(x: c.x, y: c.y + 175), "unturned slot 0 is at the top")

        // Turning by exactly one step must put slot 1 where slot 0 was. This is the
        // property that makes the wheel feel mechanical rather than arbitrary.
        for count in [Settings.minOuterSlots, 5, 8, Settings.maxOuterSlots] {
            let base = RingGeometry(outerSlotCount: count)
            let step = base.step(.outer)
            let turned = base.rotated(outer: step, inner: 0)
            // A positive rotation carries every slot one place clockwise, so slot i
            // ends up where slot i+1 used to be, and slot n-1 arrives at the top.
            for i in 0..<count {
                expectPoint(turned.slotCenter(ring: .outer, index: i, center: c),
                            base.slotCenter(ring: .outer, index: (i + 1) % count, center: c),
                            "at \(count) slots, one step moves slot \(i) to slot"
                              + " \((i + 1) % count)'s place")
            }
            expectPoint(turned.slotCenter(ring: .outer, index: count - 1, center: c),
                        CGPoint(x: c.x, y: c.y + 175),
                        "at \(count) slots, one step brings the last slot to the top")
            // And a full turn is the identity.
            let full = base.rotated(outer: step * CGFloat(count), inner: 0)
            expectPoint(full.slotCenter(ring: .outer, index: 0, center: c),
                        base.slotCenter(ring: .outer, index: 0, center: c),
                        "a whole turn at \(count) slots comes back to the start")
        }

        // The rings turn independently.
        let split = rest.rotated(outer: rest.step(.outer), inner: 0)
        expectPoint(split.slotCenter(ring: .inner, index: 0, center: c),
                    rest.slotCenter(ring: .inner, index: 0, center: c),
                    "turning the outer ring leaves the inner one alone")

        // Hit-testing has to follow the rotation, or a turned wheel would launch
        // whatever used to be under the pointer. Checked at rotations that are not
        // multiples of a step, since that is the state during a scroll.
        for rotation in [0, 0.1, 0.4, 0.9, 1.7, -0.3, -2.2] as [CGFloat] {
            let g = rest.rotated(outer: rotation, inner: rotation)
            for i in 0..<g.outerSlotCount {
                let p = g.slotCenter(ring: .outer, index: i, center: c)
                expectEqual(g.hit(p, center: c), HitTarget.slot(.outer, i),
                            "outer slot \(i) hits itself at rotation \(rotation)")
            }
            for i in 0..<g.innerSlotCount {
                let p = g.slotCenter(ring: .inner, index: i, center: c)
                expectEqual(g.hit(p, center: c), HitTarget.slot(.inner, i),
                            "inner slot \(i) hits itself at rotation \(rotation)")
            }
        }

        // Snapping always lands on a slot, and on the *nearest* one.
        let step = rest.step(.outer)
        expectClose(rest.snapped(0, ring: .outer), 0, "zero is already snapped")
        expectClose(rest.snapped(step * 0.4, ring: .outer), 0, "just under half a step rounds back")
        expectClose(rest.snapped(step * 0.6, ring: .outer), step, "just over half a step rounds on")
        expectClose(rest.snapped(step * 3, ring: .outer), step * 3, "an exact step is unchanged")
        expectClose(rest.snapped(-step * 0.6, ring: .outer), -step, "negative rotations snap too")
        // A snapped rotation must be a whole number of steps, which is what the
        // persisted value assumes.
        for raw in [0.05, 0.31, 1.02, 2.99, -0.77] as [CGFloat] {
            let snapped = rest.snapped(raw, ring: .outer)
            expectClose((snapped / step).rounded() * step, snapped,
                        "snapping \(raw) yields a whole number of steps")
        }

        // Non-finite input must not reach a CGRect.
        let broken = RingGeometry(outerRotation: .nan, innerRotation: .infinity)
        expectClose(broken.outerRotation, 0, "a NaN rotation falls back to zero")
        expectClose(broken.innerRotation, 0, "an infinite rotation falls back to zero")
        expectClose(rest.snapped(.nan, ring: .outer), 0, "snapping NaN yields zero")
        expect(broken.slotCenter(ring: .outer, index: 0, center: c).x.isFinite,
               "a repaired rotation still produces a real point")
    }

    suite("geometry/slot-counts-drive-hit-testing") {
        // Drawing and hit-testing have to agree for every count the user can pick,
        // not just the default. This is the whole reason the counts live on the
        // geometry rather than being read separately by each of them.
        let c = CGPoint(x: 500, y: 400)
        for outer in Settings.minOuterSlots...Settings.maxOuterSlots {
            for inner in Settings.minInnerSlots...Settings.maxInnerSlots {
                let g = RingGeometry(outerSlotCount: outer, innerSlotCount: inner)
                for i in 0..<outer {
                    let p = g.slotCenter(ring: .outer, index: i, center: c)
                    expectEqual(g.hit(p, center: c), HitTarget.slot(.outer, i),
                                "outer slot \(i) of \(outer) round-trips")
                }
                for i in 0..<inner {
                    let p = g.slotCenter(ring: .inner, index: i, center: c)
                    expectEqual(g.hit(p, center: c), HitTarget.slot(.inner, i),
                                "inner slot \(i) of \(inner) round-trips")
                }
            }
        }
        // The name pill's corner must stay inside the hole or it would cover an
        // inner icon. Pill is 128 x 26, so its corner is at hypot(64, 13).
        expect(hypot(64.0, 13.0) < g.holeRadius, "centre pill fits inside the hole")
        // The two icon bands must not overlap.
        expect(g.innerRadius + g.innerIconSize / 2 < g.outerRadius - g.outerIconSize / 2,
               "icon bands do not overlap")

        // The glass bands: 72-128 and 139-211, with an 11-point see-through gap.
        expectClose(g.innerBandInner, 72, "inner band starts at the hole")
        expectClose(g.innerBandOuter, 128, "inner band outer edge")
        expectClose(g.outerBandInner, 139, "outer band inner edge")
        expectClose(g.outerBandOuter, 211, "outer band outer edge")
        // The hole and the inner band's edge are the same circle: if they ever
        // drift apart, the glass would either cover the pill or leave a rim.
        expectClose(g.holeRadius, g.innerBandInner, "the hole is the inner band's edge")
        expect(g.outerBandInner > g.innerBandOuter, "the bands are separated by a gap")
        // The gap has to contain the ring boundary, so the ring a click lands in
        // is the ring whose band it is nearer to.
        expect(g.ringBoundary > g.innerBandOuter && g.ringBoundary < g.outerBandInner,
               "the ring boundary falls inside the gap")
        // Each band has to be wide enough to hold its own icons.
        expect(g.innerBandInner < g.innerRadius - g.innerIconSize / 2
               && g.innerBandOuter > g.innerRadius + g.innerIconSize / 2,
               "inner icons fit inside the inner band")
        expect(g.outerBandInner < g.outerRadius - g.outerIconSize / 2
               && g.outerBandOuter > g.outerRadius + g.outerIconSize / 2,
               "outer icons fit inside the outer band")
        // The glass must stay inside the area the window reserves for it.
        expect(g.outerBandOuter < g.discRadius, "the glass fits inside the disc")

        // Every band radius has to scale with the wheel, or a shrunken wheel
        // would draw its glass in the wrong place.
        let half = RingGeometry(scale: 0.5)
        expectClose(half.innerBandInner, 36, "inner band scales")
        expectClose(half.outerBandOuter, 105.5, "outer band scales")
    }

    suite("geometry/placement") {
        // Slot 0 sits at twelve o'clock on both rings.
        let outer0 = g.slotCenter(ring: .outer, index: 0, center: c)
        expectClose(outer0.x, c.x, "outer slot 0 is vertically centred")
        expectClose(outer0.y, c.y + 175, "outer slot 0 is at the top")

        let inner0 = g.slotCenter(ring: .inner, index: 0, center: c)
        expectClose(inner0.x, c.x, "inner slot 0 is vertically centred")
        expectClose(inner0.y, c.y + 100, "inner slot 0 is at the top")

        // Indices advance clockwise, so a quarter of the way round 8 slots is
        // three o'clock, and halfway is six o'clock.
        let outer2 = g.slotCenter(ring: .outer, index: 2, center: c)
        expectClose(outer2.x, c.x + 175, "outer slot 2 is at three o'clock", tolerance: 0.0001)
        expectClose(outer2.y, c.y, "outer slot 2 is level with the centre", tolerance: 0.0001)

        let outer4 = g.slotCenter(ring: .outer, index: 4, center: c)
        expectClose(outer4.x, c.x, "outer slot 4 is vertically centred", tolerance: 0.0001)
        expectClose(outer4.y, c.y - 175, "outer slot 4 is at the bottom")

        let outer6 = g.slotCenter(ring: .outer, index: 6, center: c)
        expectClose(outer6.x, c.x - 175, "outer slot 6 is at nine o'clock", tolerance: 0.0001)

        // Every slot centre must be exactly its ring's radius from the centre.
        for i in 0..<g.outerSlotCount {
            let p = g.slotCenter(ring: .outer, index: i, center: c)
            expectClose(hypot(p.x - c.x, p.y - c.y), 175, "outer slot \(i) radius")
        }
        for i in 0..<g.innerSlotCount {
            let p = g.slotCenter(ring: .inner, index: i, center: c)
            expectClose(hypot(p.x - c.x, p.y - c.y), 100, "inner slot \(i) radius")
        }
    }

    suite("geometry/sector-index") {
        // Directly above the centre is slot 0.
        expectEqual(RingGeometry.slotIndex(angle: .pi / 2, count: 8), 0, "top maps to slot 0")
        // A hair counter-clockwise of twelve o'clock rounds up to 8, which must
        // wrap back to 0 rather than crash or index out of bounds.
        expectEqual(RingGeometry.slotIndex(angle: .pi / 2 + 0.01, count: 8), 0,
                    "just past the top wraps to 0")
        expectEqual(RingGeometry.slotIndex(angle: .pi / 2 - 0.01, count: 8), 0,
                    "just before the top is still 0")
        // Angles far outside [-pi, pi] must still normalise.
        expectEqual(RingGeometry.slotIndex(angle: .pi / 2 + 2 * .pi, count: 8), 0,
                    "a full turn past the top is still slot 0")
        expectEqual(RingGeometry.slotIndex(angle: .pi / 2 - 6 * .pi, count: 5), 0,
                    "three full turns back is still slot 0")
        expectEqual(RingGeometry.slotIndex(angle: 0, count: 8), 2, "three o'clock is outer slot 2")
        expectEqual(RingGeometry.slotIndex(angle: -.pi / 2, count: 8), 4, "six o'clock is outer slot 4")
        expectEqual(RingGeometry.slotIndex(angle: .pi, count: 8), 6, "nine o'clock is outer slot 6")
        // A zero count would divide by zero; it must be handled, not trusted.
        expectEqual(RingGeometry.slotIndex(angle: 1.0, count: 0), 0, "zero count is safe")
    }

    suite("geometry/hit-bands") {
        expectEqual(g.hit(c, center: c), HitTarget.center, "dead centre dismisses")
        expectEqual(g.hit(CGPoint(x: c.x + 71.9, y: c.y), center: c), HitTarget.center,
                    "just inside the hole dismisses")
        // The hole boundary itself belongs to the inner ring. Three o'clock is
        // 90 degrees clockwise from the top, and on a five-slot ring the nearest
        // slot is 1 (at 72 degrees), not 2 (at 144).
        expectEqual(g.hit(CGPoint(x: c.x + 72, y: c.y), center: c), HitTarget.slot(.inner, 1),
                    "the hole edge is the inner ring")
        expectEqual(g.hit(CGPoint(x: c.x + 133.4, y: c.y), center: c), HitTarget.slot(.inner, 1),
                    "just inside the boundary is the inner ring")
        // The boundary itself belongs to the outer ring.
        expectEqual(g.hit(CGPoint(x: c.x + 133.5, y: c.y), center: c), HitTarget.slot(.outer, 2),
                    "the boundary is the outer ring")
        // The reachable edge is the outer band plus the grace margin: 211 + 10.
        expectEqual(g.hit(CGPoint(x: c.x + 221, y: c.y), center: c), HitTarget.slot(.outer, 2),
                    "the outer limit is still the outer ring")
        expectEqual(g.hit(CGPoint(x: c.x + 221.1, y: c.y), center: c), HitTarget.outside,
                    "past the outer limit dismisses")
        // The gap between the bands is still clickable, and belongs to whichever
        // ring is nearer: a 10-point-wide dead zone would only frustrate.
        expectEqual(g.hit(CGPoint(x: c.x + 130, y: c.y), center: c), HitTarget.slot(.inner, 1),
                    "the near side of the gap is the inner ring")
        expectEqual(g.hit(CGPoint(x: c.x + 137, y: c.y), center: c), HitTarget.slot(.outer, 2),
                    "the far side of the gap is the outer ring")
        expectEqual(g.hit(CGPoint(x: c.x + 4000, y: c.y - 4000), center: c), HitTarget.outside,
                    "far away dismisses")
    }

    suite("geometry/hit-round-trip") {
        // Clicking the visual centre of a slot must select that same slot. This
        // is the single most important invariant: drawing and hit-testing agree.
        for scale in [CGFloat(1), 0.75, 0.6256, 0.4, RingGeometry.minScale, 0.9,
                      RingGeometry.maxScale] {
            let gs = RingGeometry(scale: scale)
            for i in 0..<gs.outerSlotCount {
                let p = gs.slotCenter(ring: .outer, index: i, center: c)
                expectEqual(gs.hit(p, center: c), HitTarget.slot(.outer, i),
                            "outer slot \(i) round-trips at scale \(scale)")
            }
            for i in 0..<gs.innerSlotCount {
                let p = gs.slotCenter(ring: .inner, index: i, center: c)
                expectEqual(gs.hit(p, center: c), HitTarget.slot(.inner, i),
                            "inner slot \(i) round-trips at scale \(scale)")
            }
        }
    }

    suite("geometry/scale") {
        // A ring needs 2 * (227 + 8) = 470 points. Anything roomier is unscaled.
        expectClose(RingGeometry.scale(forScreen: CGSize(width: 1440, height: 900)), 1,
                    "a laptop display needs no scaling")
        expectClose(RingGeometry.scale(forScreen: CGSize(width: 3840, height: 2160)), 1,
                    "a large display needs no scaling")
        expectClose(RingGeometry.scale(forScreen: CGSize(width: 640, height: 480)), 1,
                    "480 points is just enough, so no scaling")
        let tiny = RingGeometry.scale(forScreen: CGSize(width: 400, height: 300))
        expectClose(tiny, (300 - 16) / 454, "a 300-point-tall display scales down")
        expect(tiny < 1, "the tiny-screen scale is a reduction")
        // Scaling must move every dimension together or drawing and hit-testing
        // would disagree.
        let gs = RingGeometry(scale: 0.5)
        expectClose(gs.holeRadius, 36, "scaled hole radius")
        expectClose(gs.discRadius, 113.5, "scaled disc radius")
        expectClose(gs.ringBoundary, 133.5 * 0.5, "scaled ring boundary")
        expectClose(gs.outerIconSize, 28, "scaled outer icon size")
        // A degenerate screen must not produce a zero or negative scale.
        expect(RingGeometry.scale(forScreen: CGSize(width: 1, height: 1)) > 0,
               "a one-point screen still yields a positive scale")
        expect(RingGeometry(scale: -5).discRadius > 0, "a negative scale is clamped")
        // The upper bound is the largest size the settings slider offers, not 1:
        // the user can ask for a bigger wheel, and only the screen may override it.
        expectClose(RingGeometry(scale: 99).scale, RingGeometry.maxScale,
                    "an absurd scale is clamped to the maximum")
        expectClose(RingGeometry(scale: 99).discRadius,
                    RingGeometry.baseDiscRadius * RingGeometry.maxScale,
                    "the clamped scale is what the radii are built from")
        expectClose(RingGeometry(scale: -5).scale, RingGeometry.minScale,
                    "a negative scale is clamped to the minimum")
        expectClose(RingGeometry(scale: .nan).scale, 1,
                    "a scale that is not a number falls back to the reference size")
    }

    suite("geometry/everything-scales") {
        // A measurement that forgot to scale is the worst kind of bug here: the
        // wheel still draws, and only the clicks land in the wrong place.
        let half = RingGeometry(scale: 0.5)
        expectClose(half.scale, 0.5, "the scale is kept")
        expectClose(half.innerRadius, 50, "the inner radius scales")
        expectClose(half.outerRadius, 87.5, "the outer radius scales")
        expectClose(half.innerIconSize, 20, "the inner icon size scales")
        expectClose(half.innerBandOuter, 64, "the inner band's outer edge scales")
        expectClose(half.outerBandInner, 69.5, "the outer band's inner edge scales")
        expectClose(half.grace, 5, "the grace margin scales")
        expectClose(half.margin, 4, "the screen margin scales")
        expectClose(half.pillHeight, 13, "the pill height scales")
        expectClose(half.pillMaxTextWidth, 52, "the pill's text width scales")
        expectClose(half.pillTextInset, 6, "the pill's text inset scales")
        expectClose(half.pillMaxWidth, 64, "the pill's full width scales")
        // Nothing may scale by a different factor from anything else.
        let full = RingGeometry()
        for (scaled, unscaled) in [(half.holeRadius, full.holeRadius),
                                   (half.innerRadius, full.innerRadius),
                                   (half.outerRadius, full.outerRadius),
                                   (half.innerIconSize, full.innerIconSize),
                                   (half.outerIconSize, full.outerIconSize),
                                   (half.discRadius, full.discRadius),
                                   (half.innerBandInner, full.innerBandInner),
                                   (half.innerBandOuter, full.innerBandOuter),
                                   (half.outerBandInner, full.outerBandInner),
                                   (half.outerBandOuter, full.outerBandOuter),
                                   (half.ringBoundary, full.ringBoundary),
                                   (half.grace, full.grace),
                                   (half.margin, full.margin),
                                   (half.pillHeight, full.pillHeight),
                                   (half.pillMaxWidth, full.pillMaxWidth),
                                   (half.pillMaxTextWidth, full.pillMaxTextWidth),
                                   (half.pillTextInset, full.pillTextInset)] {
            expectClose(scaled, unscaled / 2, "every measurement scales by the same factor")
        }
    }

    suite("geometry/invariants-at-every-scale") {
        // The relationships the drawing and hit-testing both depend on have to hold
        // at every size the app can be drawn at, not only at the reference size.
        for scale in [RingGeometry.minScale, 0.35, 0.5, 0.7, 1, 1.2, RingGeometry.maxScale] {
            let gs = RingGeometry(scale: scale)
            let at = "at scale \(scale)"
            expect(gs.holeRadius > 0, "the hole has a positive radius \(at)")
            expectClose(gs.holeRadius, gs.innerBandInner, "the hole is the inner band's edge \(at)")
            expect(gs.innerBandOuter > gs.innerBandInner, "the inner band has width \(at)")
            expect(gs.outerBandInner > gs.innerBandOuter, "the bands are separated \(at)")
            expect(gs.outerBandOuter > gs.outerBandInner, "the outer band has width \(at)")
            expect(gs.ringBoundary > gs.innerBandOuter && gs.ringBoundary < gs.outerBandInner,
                   "the ring boundary falls in the gap \(at)")
            expect(gs.innerBandInner < gs.innerRadius - gs.innerIconSize / 2
                   && gs.innerBandOuter > gs.innerRadius + gs.innerIconSize / 2,
                   "inner icons fit their band \(at)")
            expect(gs.outerBandInner < gs.outerRadius - gs.outerIconSize / 2
                   && gs.outerBandOuter > gs.outerRadius + gs.outerIconSize / 2,
                   "outer icons fit their band \(at)")
            expect(gs.innerRadius + gs.innerIconSize / 2 < gs.outerRadius - gs.outerIconSize / 2,
                   "the icon bands do not overlap \(at)")
            expect(gs.outerBandOuter < gs.discRadius, "the glass fits inside the disc \(at)")
            // The pill's corner, not its half-width: a rectangle in a circle is
            // limited by its diagonal.
            expect(gs.pillCornerDistance < gs.holeRadius,
                   "the name pill fits inside the hole \(at)")
            expect(gs.pillMaxWidth > gs.pillMaxTextWidth,
                   "the pill is wider than the text it holds \(at)")
        }
    }

    suite("geometry/hit-edges") {
        // Nothing that comes out of a mouse event or a saved position may reach the
        // hit test without being handled: NaN compares false with every bound, so
        // an unguarded clamp would fall through to a slot and launch something.
        expectEqual(g.hit(CGPoint(x: .nan, y: c.y), center: c), HitTarget.outside,
                    "a point that is not a number hits nothing")
        expectEqual(g.hit(CGPoint(x: c.x, y: .nan), center: c), HitTarget.outside,
                    "a NaN in either axis hits nothing")
        expectEqual(g.hit(CGPoint(x: CGFloat.infinity, y: .infinity), center: c),
                    HitTarget.outside,
                    "an infinite point hits nothing")
        expectEqual(g.hit(c, center: CGPoint(x: CGFloat.nan, y: .nan)), HitTarget.outside,
                    "a centre that is not a number hits nothing")
        // Exactly on the centre there is no angle to measure; it must read as the
        // hole and dismiss, not as slot 0.
        expectEqual(g.hit(c, center: c), HitTarget.center, "the exact centre is the hole")
        // Both diagonals of the smallest wheel still behave.
        let tiny = RingGeometry(scale: RingGeometry.minScale)
        expectEqual(tiny.hit(c, center: c), HitTarget.center, "the smallest wheel still has a hole")
        expectEqual(tiny.hit(CGPoint(x: c.x + tiny.outerBandOuter + tiny.grace + 0.1, y: c.y),
                             center: c), HitTarget.outside,
                    "the smallest wheel's edge is its own, not the reference one")
    }

    suite("geometry/user-size") {
        let roomy = CGSize(width: 2560, height: 1440)
        expectClose(RingGeometry.scale(forScreen: roomy, userSize: 1), 1,
                    "the reference size is honoured")
        expectClose(RingGeometry.scale(forScreen: roomy, userSize: 0.7), 0.7,
                    "a smaller chosen size is honoured exactly")
        expectClose(RingGeometry.scale(forScreen: roomy, userSize: 1.4), 1.4,
                    "a larger chosen size is honoured exactly")
        expectClose(RingGeometry.scale(forScreen: roomy, userSize: 99), RingGeometry.maxScale,
                    "an absurd chosen size is clamped to the maximum")
        expectClose(RingGeometry.scale(forScreen: roomy, userSize: 0), RingGeometry.minScale,
                    "a zero chosen size is clamped to the minimum")
        expectClose(RingGeometry.scale(forScreen: roomy, userSize: -3), RingGeometry.minScale,
                    "a negative chosen size is clamped to the minimum")
        expectClose(RingGeometry.scale(forScreen: roomy, userSize: .nan), 1,
                    "a chosen size that is not a number falls back to the reference")
        // The screen only ever shrinks the wheel, never grows it.
        let short = CGSize(width: 2000, height: 500)
        let fitted = RingGeometry.fittingScale(forScreen: short)
        expectClose(RingGeometry.scale(forScreen: short, userSize: 1.4), fitted,
                    "a screen too short for the chosen size overrides it")
        expectClose(RingGeometry.scale(forScreen: short, userSize: 0.7), 0.7,
                    "a size the screen can hold is left alone")
        expect(fitted < 1.4, "the fitted scale is a reduction")
        expectClose(fitted, (500 - 16) / 454, "the fit is the shorter side less the margins")
        // Degenerate screens must not produce a nonsensical scale.
        for size in [CGSize(width: 0, height: 0), CGSize(width: -100, height: -100),
                     CGSize(width: CGFloat.nan, height: 900),
                     CGSize(width: 1440, height: CGFloat.nan),
                     CGSize(width: CGFloat.infinity, height: .infinity)] {
            let value = RingGeometry.scale(forScreen: size, userSize: 1)
            expect(value.isFinite && value >= RingGeometry.minScale
                   && value <= RingGeometry.maxScale,
                   "a screen of \(size) still yields a usable scale, got \(value)")
        }
    }

    suite("geometry/fraction-round-trip") {
        // A remembered position is stored as a fraction so it survives a change of
        // resolution or of display. Both directions have to agree, or the wheel
        // would drift every time it opened.
        let size = CGSize(width: 1440, height: 900)
        for fraction in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.7),
                         CGPoint(x: 0.25, y: 0.4)] {
            let point = g.center(fromFraction: fraction, in: size)
            let back = RingGeometry.fraction(ofCenter: point, in: size)
            expectPoint(back, fraction, "fraction \(fraction) round-trips", tolerance: 0.0001)
        }
        // A corner fraction is pulled in far enough to keep the wheel on screen,
        // which is exactly why the round trip is not asserted for it.
        let corner = g.center(fromFraction: CGPoint(x: 0, y: 0), in: size)
        expectPoint(corner, CGPoint(x: 235, y: 235), "a corner fraction is clamped inward")
        let far = g.center(fromFraction: CGPoint(x: 1, y: 1), in: size)
        expectPoint(far, CGPoint(x: 1205, y: 665), "the opposite corner is clamped inward")
        // Rubbish in either direction falls back to the middle rather than off-screen.
        expectPoint(g.center(fromFraction: CGPoint(x: CGFloat.nan, y: .nan), in: size),
                    CGPoint(x: 720, y: 450), "a position that is not a number centres the wheel")
        expectPoint(g.center(fromFraction: CGPoint(x: 4, y: -4), in: size),
                    CGPoint(x: 1205, y: 235), "a fraction outside 0...1 is clamped")
        expectPoint(RingGeometry.fraction(ofCenter: CGPoint(x: CGFloat.nan, y: 5), in: size),
                    CGPoint(x: 0.5, y: 0.5), "a centre that is not a number reads as the middle")
        expectPoint(RingGeometry.fraction(ofCenter: CGPoint(x: 100, y: 100), in: .zero),
                    CGPoint(x: 0.5, y: 0.5), "a screen with no size reads as the middle")
        expectPoint(RingGeometry.fraction(ofCenter: CGPoint(x: 9000, y: -9000), in: size),
                    CGPoint(x: 1, y: 0), "a centre off the screen reads as an edge")
    }

    suite("geometry/clamp-centre") {
        let screen = CGSize(width: 1440, height: 900)
        // 227 + 8 = 235 points of margin on every side.
        expectPoint(g.clampCenter(CGPoint(x: 0, y: 0), in: screen), CGPoint(x: 235, y: 235),
                    "the bottom-left corner is pushed inward")
        expectPoint(g.clampCenter(CGPoint(x: 1440, y: 900), in: screen),
                    CGPoint(x: 1205, y: 665), "the top-right corner is pushed inward")
        expectPoint(g.clampCenter(CGPoint(x: 700, y: 450), in: screen),
                    CGPoint(x: 700, y: 450), "a central point is left alone")
        // If the ring cannot fit even after scaling, centre it rather than
        // producing a nonsensical clamp where the low bound exceeds the high one.
        expectPoint(g.clampCenter(CGPoint(x: 10, y: 10), in: CGSize(width: 200, height: 200)),
                    CGPoint(x: 100, y: 100), "an impossibly small screen centres the ring")
    }
}

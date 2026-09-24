# Chakra Orb Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small always-on-top circular button that floats over other apps, is dragged wherever the user wants, dims and tucks into a screen edge when idle, and opens the existing Chakra wheel when clicked.

**Architecture:** A second window — an `NSPanel` with `[.borderless, .nonactivatingPanel]` — owned by a new `OrbController`, entirely separate from the wheel's window. All arithmetic that can be tested without a screen (dot placement, clamping, edge detection, the tuck offset, position persistence) is extracted into two pure value types, `OrbGeometry` and `OrbPlacement`, which the view and controller read from. This mirrors how `RingGeometry` already serves `WheelView` and `WheelController`.

**Tech Stack:** Swift 5 language mode, AppKit, Carbon.HIToolbox (existing hot-key code only), ServiceManagement (existing login item only). No SwiftPM, no Xcode project, no third-party dependencies. Built by `swiftc` through `./build.sh`.

**Spec:** `docs/superpowers/specs/2026-09-11-chakra-orb-design.md`

---

## Completion status — 56 of 68 steps ticked

All eleven tasks were built, reviewed by an independent reviewer, and closed. The end state is
verified as of the last run: **1,712 unit checks, 396 smoke checks, clean build, zero warnings**,
and the app runs from `~/Applications/Chakra.app`.

A box is ticked only where completion is provable from the repository as it stands, so **twelve
are deliberately left unticked** rather than ticked for tidiness:

- **Nine "Commit" steps.** Never done, by a standing ruling: this repository has zero commits and
  no configured `user.name`/`user.email`, so no commit was made and no identity was invented.
- **Three "verify by hand" steps** (Task 7 Step 5, Task 8 Step 4, Task 11 Step 7). Each is
  annotated in place with exactly which sub-checks passed, which were covered by an assertion
  instead of an eye, which were not done, and — in one case — which sub-check turned out to be
  void because this plan described a context menu that does not exist.

Every failure found along the way, including the ones caused by this plan's own errors, is
written up in `BUILD-CHAKRA.md` §6. The per-task ledger is
`.superpowers/sdd/2026-09-11-chakra-orb/progress.md`.

## Global Constraints

- **Every task's requirements implicitly include this section.**
- Deployment target `macOS 14.0`; built universal (`arm64` and `x86_64`, joined with `lipo`). Using an API newer than macOS 14 must be a compile error, not a crash on someone's Mac.
- `-warnings-as-errors` is on. A warning fails the build.
- No new TCC permission may be required. Nothing may prompt for Accessibility, Screen Recording, Automation, or Input Monitoring. This rules out `NSEvent.addGlobalMonitorForEvents`, `CGEvent` taps, and `AXUIElement`.
- **Never set `NSWindow.CollectionBehavior.moveToActiveSpace` together with `.canJoinAllSpaces`.** It raises `NSInternalInconsistencyException` from `-[NSWindow _validateCollectionBehavior:]` and terminates the app. Verified on macOS 26.5.
- Tests use the project's own harness, not XCTest: `suite(_:_:)`, `expect(_:_:)`, `expectEqual(_:_:_:)`, `expectClose(_:_:_:)`, `expectPoint(_:_:_:)` from `Tests/TestMain.swift`. A new test file exposes one `func runXTests()` and is called from `TestMain.swift`.
- Every new `Sources/*.swift` file must be added to the `SOURCES` array in `build.sh` **and** to the `swiftc` invocations in `run-tests.sh`, `run-smoke.sh` and `render-preview.sh`. `Sources/main.swift` is excluded from the last three because top-level code cannot coexist with their `@main`.
- Every new `Tests/*.swift` file must be added to `run-tests.sh` as well. That script lists its test files explicitly rather than globbing `Tests/*.swift`, so a file that is not listed leaves its `runXTests()` undefined and the link fails.
- `.nan` and `.infinity` written bare in a test are ambiguous between `Double` and `CGFloat` and will not compile. Write `CGFloat.nan` and `CGFloat.infinity`.
- Pure-logic files (`OrbGeometry`, `OrbPlacement`) must not import AppKit beyond what `CoreGraphics` types need, so they link into the test binary.
- Comments explain **why**, in complete sentences, matching the surrounding style. No comment restates what the line does.
- User-facing copy is sentence case, plain English, no exclamation marks.
- **Git:** this repository has no commits and no `user.name` / `user.email` configured, locally or globally. Every "Commit" step below is written out, but **skip it and report that you skipped it** unless an identity is already configured — do not invent one. Run the verification in that step regardless.

## Verification commands

Used throughout; all run from the project root.

| Command | What it proves |
|---|---|
| `./run-tests.sh` | Pure-logic tests. Must end `✓ N checks passed`. |
| `./build.sh` | The app compiles universal with zero warnings. |
| `./run-smoke.sh` | Real AppKit windows are built and every control's action fires. Must end `✓ N smoke checks passed`. |
| `./render-preview.sh` | Offscreen PNGs of the wheel, for eyeballing. |

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `Sources/OrbGeometry.swift` | Pure. The orb's measurements at a given size: dot ring radius, dot radii, each dot's centre, and whether a point is inside the disc. |
| `Sources/OrbPlacement.swift` | Pure. Where the orb may sit: clamping into a screen, which edge it is parked at, the tucked origin, and converting between an absolute origin and a `{display, fraction}` pair. |
| `Sources/OrbView.swift` | The `NSView`: draws the orb, tracks hover, handles the drag, reports clicks and drops. Owns no state that outlives the wheel being closed. |
| `Sources/OrbController.swift` | Owns the `NSPanel`, its window-server configuration, the show/hide lifecycle, the idle fade and edge tuck, and position persistence. |
| `Tests/OrbGeometryTests.swift` | `runOrbGeometryTests()` |
| `Tests/OrbPlacementTests.swift` | `runOrbPlacementTests()` |
| `Tools/DumpIcons.swift` | Dumps app icons to PNG for the HTML mockups, so the mockups are reproducible from the repository. |
| `dump-icons.sh` | Runner for the above. |

**Modified:**

| File | Change |
|---|---|
| `Sources/Defaults.swift` | Six new keys and their `Settings` properties; `openLocation` default changes from `.pointer` to `.center`. |
| `Sources/SettingsWindow.swift` | A new "Orb" section. |
| `Sources/WheelWindow.swift` | Report visibility to the orb so it can hide while the wheel is open. |
| `Sources/main.swift` | Create and destroy the `OrbController` in step with the setting. |
| `Tests/TestMain.swift` | Call the two new test entry points. |
| `Tests/SettingsTests.swift` | Cover the new keys. |
| `Tools/Smoke.swift` | Exercise the orb panel, its drawing, and its drag. |
| `build.sh`, `run-tests.sh`, `run-smoke.sh`, `render-preview.sh` | Add the new sources. |
| `mockup_common.py` | Regenerate the icon dump when it is missing, instead of failing. |

---

### Task 1: OrbPlacement — where the orb may sit

The highest-risk arithmetic in the feature and entirely testable without a screen. Done first so everything after it can rely on it.

**Files:**
- Create: `Sources/OrbPlacement.swift`
- Create: `Tests/OrbPlacementTests.swift`
- Modify: `Tests/TestMain.swift`
- Modify: `run-tests.sh`, `run-smoke.sh`, `render-preview.sh`, `build.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum OrbEdge: String, CaseIterable { case none, left, right, top, bottom }`
  - `struct OrbPlacement` with statics:
    - `static let edgeThreshold: CGFloat` (14)
    - `static let tuckFraction: CGFloat` (0.62)
    - `static func clamp(_ origin: CGPoint, size: CGFloat, in visible: CGRect) -> CGPoint`
    - `static func nearestEdge(origin: CGPoint, size: CGFloat, in visible: CGRect) -> OrbEdge`
    - `static func tuckedOrigin(_ origin: CGPoint, size: CGFloat, in visible: CGRect, edge: OrbEdge) -> CGPoint`
    - `static func fraction(ofOrigin origin: CGPoint, size: CGFloat, in visible: CGRect) -> CGPoint`
    - `static func origin(fromFraction fraction: CGPoint, size: CGFloat, in visible: CGRect) -> CGPoint`

- [x] **Step 1: Add the new sources to every build script**

In `build.sh`, add to the `SOURCES` array immediately after `Sources/Geometry.swift`:

```bash
  Sources/OrbPlacement.swift
```

In `run-tests.sh`, `run-smoke.sh` and `render-preview.sh`, add the same line, ending with a trailing ` \`, immediately after the `Sources/Geometry.swift \` line. Getting the backslash wrong silently drops later files from the compile, so check each file afterwards with `bash -n <file>`.

**Only `OrbPlacement.swift`.** `OrbGeometry.swift` is added by Task 2, which is where it is created. Listing a file before it exists makes `swiftc` fail, and this task's own build check would not pass.

- [x] **Step 2: Write the failing test**

Create `Tests/OrbPlacementTests.swift`:

```swift
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
        let broken = OrbPlacement.clamp(CGPoint(x: .nan, y: .infinity), size: size, in: visible)
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
        for f in [CGPoint(x: -1, y: 2), CGPoint(x: .nan, y: 0.5),
                  CGPoint(x: 0.5, y: .infinity)] {
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
```

Add to `Tests/TestMain.swift`, immediately after `runGeometryTests()`:

```swift
        runOrbPlacementTests()
```

- [x] **Step 3: Run the tests to verify they fail**

Run: `./run-tests.sh`
Expected: compile failure, `cannot find 'OrbPlacement' in scope`.

- [x] **Step 4: Write the implementation**

Create `Sources/OrbPlacement.swift`:

```swift
import CoreGraphics

/// Which screen edge the orb is parked against.
enum OrbEdge: String, CaseIterable {
    case none, left, right, top, bottom
}

/// Where the orb is allowed to sit, and how its position is stored.
///
/// Pure and free of AppKit so it links into the test binary: the interesting
/// cases are screens that are not attached to this machine, and positions saved
/// by a display that has since been unplugged.
struct OrbPlacement {
    /// How close to an edge counts as parked there.
    static let edgeThreshold: CGFloat = 14
    /// How much of the orb slides off the edge when tucked.
    static let tuckFraction: CGFloat = 0.62

    /// Keeps the whole orb inside `visible`.
    ///
    /// The upper bound subtracts the orb's own size, so it is the orb that stays
    /// on screen rather than merely its origin. A screen smaller than the orb
    /// would invert the range, so that case falls back to the near edge.
    static func clamp(_ origin: CGPoint, size: CGFloat, in visible: CGRect) -> CGPoint {
        let x = origin.x.isFinite ? origin.x : visible.midX
        let y = origin.y.isFinite ? origin.y : visible.midY
        let maxX = visible.maxX - size
        let maxY = visible.maxY - size
        return CGPoint(x: maxX >= visible.minX ? min(max(x, visible.minX), maxX) : visible.minX,
                       y: maxY >= visible.minY ? min(max(y, visible.minY), maxY) : visible.minY)
    }

    /// The edge the orb is parked against, or `.none`.
    ///
    /// A corner is within the threshold of two edges at once. The horizontal edge
    /// wins, because sliding sideways hides less of a circle's silhouette than
    /// sliding up or down does.
    static func nearestEdge(origin: CGPoint, size: CGFloat,
                            in visible: CGRect) -> OrbEdge {
        guard origin.x.isFinite, origin.y.isFinite else { return .none }
        if origin.x - visible.minX <= edgeThreshold { return .left }
        if visible.maxX - (origin.x + size) <= edgeThreshold { return .right }
        if origin.y - visible.minY <= edgeThreshold { return .bottom }
        if visible.maxY - (origin.y + size) <= edgeThreshold { return .top }
        return .none
    }

    /// Where the orb sits while tucked away at `edge`.
    static func tuckedOrigin(_ origin: CGPoint, size: CGFloat, in visible: CGRect,
                             edge: OrbEdge) -> CGPoint {
        let offset = size * tuckFraction
        switch edge {
        case .none: return origin
        case .left: return CGPoint(x: origin.x - offset, y: origin.y)
        case .right: return CGPoint(x: origin.x + offset, y: origin.y)
        case .bottom: return CGPoint(x: origin.x, y: origin.y - offset)
        case .top: return CGPoint(x: origin.x, y: origin.y + offset)
        }
    }

    /// The orb's position as a fraction of the room it has on this screen.
    ///
    /// Stored rather than an absolute point so the orb comes back in the same
    /// relative place after a resolution change or a move to another display.
    /// The denominator is the *travel* available to the origin, not the screen
    /// width, which is what makes the round trip exact at both extremes.
    static func fraction(ofOrigin origin: CGPoint, size: CGFloat,
                         in visible: CGRect) -> CGPoint {
        let travelX = visible.width - size
        let travelY = visible.height - size
        let fx = travelX > 0 ? (origin.x - visible.minX) / travelX : 0
        let fy = travelY > 0 ? (origin.y - visible.minY) / travelY : 0
        return CGPoint(x: unit(fx), y: unit(fy))
    }

    /// The inverse, clamped, so a saved position that no longer fits still lands
    /// somewhere the user can reach.
    static func origin(fromFraction fraction: CGPoint, size: CGFloat,
                       in visible: CGRect) -> CGPoint {
        let fx = unit(fraction.x)
        let fy = unit(fraction.y)
        let proposed = CGPoint(x: visible.minX + (visible.width - size) * fx,
                               y: visible.minY + (visible.height - size) * fy)
        return clamp(proposed, size: size, in: visible)
    }

    private static func unit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
```

- [x] **Step 5: Run the tests to verify they pass**

Run: `./run-tests.sh`
Expected: `✓ N checks passed`, N larger than before by roughly 40.

- [x] **Step 6: Confirm the app still builds**

Run: `./build.sh`
Expected: `built build/Chakra.app`, no warnings.

- [ ] Step 7: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/OrbPlacement.swift Tests/OrbPlacementTests.swift Tests/TestMain.swift \
        build.sh run-tests.sh run-smoke.sh render-preview.sh
git commit -m "feat: add OrbPlacement, the orb's screen arithmetic"
```

Skip per Global Constraints if no git identity is configured; say so in your report.

---

### Task 2: OrbGeometry — the orb's measurements

**Files:**
- Create: `Sources/OrbGeometry.swift`
- Create: `Tests/OrbGeometryTests.swift`
- Modify: `Tests/TestMain.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct OrbGeometry` with `static let minSize/maxSize/defaultSize: CGFloat` (36/76/56)
  - `init(size: CGFloat)` — clamps into range, repairs non-finite
  - `let size: CGFloat`
  - `var radius, dotRingRadius, leadDotRadius, dotRadius, centreDotRadius: CGFloat`
  - `func dotCenter(index: Int, count: Int, rotation: CGFloat) -> CGPoint`
  - `func contains(_ point: CGPoint) -> Bool`

- [x] **Step 0: Add the two new files to the build scripts**

Add `Sources/OrbGeometry.swift` (with a trailing ` \` in the three `swiftc`
scripts) immediately after `Sources/OrbPlacement.swift`, which Task 1 added.

**Also add `Tests/OrbGeometryTests.swift` to `run-tests.sh`.** That script lists
every test file explicitly rather than globbing `Tests/*.swift`, so a new test
file that is not listed leaves its `runXTests()` undefined and the link fails.
Put it after `Tests/OrbPlacementTests.swift`.

Verify each script still parses with `bash -n`.

- [x] **Step 1: Write the failing test**

Create `Tests/OrbGeometryTests.swift`:

```swift
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
        expect(!g.contains(CGPoint(x: .nan, y: 28)), "a NaN point is outside")
    }
}
```

Add to `Tests/TestMain.swift`, after `runOrbPlacementTests()`:

```swift
        runOrbGeometryTests()
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `./run-tests.sh`
Expected: `cannot find 'OrbGeometry' in scope`.

- [x] **Step 3: Write the implementation**

Create `Sources/OrbGeometry.swift`:

```swift
import CoreGraphics

/// The orb's measurements at a given size.
///
/// A value type with no AppKit in it, for the same reason `RingGeometry` is one:
/// the drawing and the hit test both read from a single instance, so they cannot
/// end up disagreeing about where a dot is, and the arithmetic can be tested
/// without a screen.
struct OrbGeometry: Equatable {
    /// Below 36pt the dots stop being distinguishable; above 76pt the orb stops
    /// reading as a button and starts reading as a window.
    static let minSize: CGFloat = 36
    static let maxSize: CGFloat = 76
    static let defaultSize: CGFloat = 56

    let size: CGFloat

    init(size: CGFloat) {
        guard size.isFinite else {
            self.size = Self.defaultSize
            return
        }
        self.size = min(max(size, Self.minSize), Self.maxSize)
    }

    var radius: CGFloat { size / 2 }
    var dotRingRadius: CGFloat { 0.30 * size }
    /// Slot 0's dot, drawn larger so the orb has a visible orientation rather
    /// than reading as a symmetrical smear of colour.
    var leadDotRadius: CGFloat { 0.075 * size }
    var dotRadius: CGFloat { 0.055 * size }
    var centreDotRadius: CGFloat { 0.035 * size }

    /// The centre of one dot, in the orb's own coordinates, with the outer ring's
    /// rotation applied so a turned wheel and the orb agree about which app is at
    /// the top.
    func dotCenter(index: Int, count: Int, rotation: CGFloat) -> CGPoint {
        let centre = CGPoint(x: radius, y: radius)
        guard count > 0 else { return centre }
        let turn = rotation.isFinite ? rotation : 0
        let angle = CGFloat.pi / 2 - 2 * CGFloat.pi * CGFloat(index) / CGFloat(count) - turn
        return CGPoint(x: centre.x + cos(angle) * dotRingRadius,
                       y: centre.y + sin(angle) * dotRingRadius)
    }

    /// Whether a point in the orb's own coordinates is on the disc.
    ///
    /// The panel is square, so without this the corners would swallow clicks
    /// aimed at whatever is behind the orb.
    func contains(_ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return hypot(point.x - radius, point.y - radius) <= radius
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh`
Expected: `✓ N checks passed`.

- [ ] Step 5: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/OrbGeometry.swift Tests/OrbGeometryTests.swift Tests/TestMain.swift
git commit -m "feat: add OrbGeometry, the orb's measurements"
```

---

### Task 3: Settings for the orb

**Files:**
- Modify: `Sources/Defaults.swift`
- Modify: `Tests/SettingsTests.swift`

**Interfaces:**
- Consumes: `OrbGeometry.minSize/maxSize/defaultSize`, `OrbEdge`.
- Produces, on `Settings`:
  - `var showOrb: Bool` (default `false`)
  - `var orbSize: Double` (default 56, clamped to `OrbGeometry.minSize...maxSize`)
  - `var orbIdleOpacity: Double` (default 0.35, clamped 0.15...1)
  - `var orbTucksAtEdge: Bool` (default `true`)
  - `var orbHiddenFromCapture: Bool` (default `true`)
  - `var orbDisplayID: Int` / `var orbDisplayName: String` / `var orbFraction: CGPoint?`
  - `func clearOrbPosition()`
  - `DefaultsKey.showOrb / orbSize / orbIdleOpacity / orbTucksAtEdge / orbHiddenFromCapture / orbDisplayID / orbDisplayName / orbFractionX / orbFractionY`
- Also changes: `openLocation`'s default from `.pointer` to `.center`.

- [x] **Step 1: Write the failing test**

Append to `Tests/SettingsTests.swift`, inside the existing `runSettingsTests()`:

```swift
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

        // Wrong-typed and out-of-range stored values must not reach a window frame.
        let hostile = scratchDefaults()
        hostile.set("big", forKey: DefaultsKey.orbSize)
        expectClose(CGFloat(Settings(defaults: hostile).orbSize), OrbGeometry.defaultSize,
                    "a string size falls back to the default")
        hostile.set(["not", "a", "number"], forKey: DefaultsKey.orbFractionX)
        expect(Settings(defaults: hostile).orbFraction == nil,
               "a wrong-typed fraction reads as no saved position")
    }

    suite("settings/opens-at-centre-by-default") {
        // Changed when the orb arrived: with a button parked at a screen edge, the
        // pointer is a poor place to centre a wheel.
        let settings = Settings(defaults: scratchDefaults())
        expectEqual(settings.openLocation, OpenLocation.center,
                    "the wheel opens at the centre of the screen by default")
    }
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `./run-tests.sh`
Expected: `value of type 'Settings' has no member 'showOrb'`.

- [x] **Step 3: Add the keys**

In `Sources/Defaults.swift`, add to `enum DefaultsKey` after `innerRotationSteps`:

```swift
    static let showOrb = "showOrb"
    static let orbSize = "orbSize"
    static let orbIdleOpacity = "orbIdleOpacity"
    static let orbTucksAtEdge = "orbTucksAtEdge"
    static let orbHiddenFromCapture = "orbHiddenFromCapture"
    static let orbDisplayID = "orbDisplayID"
    static let orbDisplayName = "orbDisplayName"
    static let orbFractionX = "orbFractionX"
    static let orbFractionY = "orbFractionY"
```

- [x] **Step 4: Add the properties**

In `Sources/Defaults.swift`, inside `struct Settings`, after `innerSlotCount`:

```swift
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
        nonmutating set { defaults.set(newValue, forKey: DefaultsKey.orbDisplayID) }
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
```

If `Settings.sane(_:min:max:fallback:)` does not already exist with that
signature, read the existing clamping helper in `Defaults.swift` and use it as it
is actually written rather than inventing a call.

- [x] **Step 5: Change the openLocation default**

In `Sources/Defaults.swift`, in the `openLocation` getter, change the `default:`
argument from `OpenLocation.pointer.rawValue` to `OpenLocation.center.rawValue`,
and replace the comment above it with:

```swift
    /// Defaults to the centre of the screen. The pointer made sense when the only
    /// ways in were a keyboard shortcut and the menu-bar icon; with an orb parked
    /// at a screen edge, the pointer is a poor place to centre a wheel.
```

- [x] **Step 6: Run the tests to verify they pass**

Run: `./run-tests.sh`
Expected: `✓ N checks passed`. If `settings/opening` or a smoke check asserted the
old `.pointer` default, update that assertion — the default genuinely changed.

- [x] **Step 7: Build and smoke**

Run: `./build.sh && ./run-smoke.sh`
Expected: both pass.

- [ ] Step 8: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/Defaults.swift Tests/SettingsTests.swift
git commit -m "feat: add orb settings and open the wheel at the centre by default"
```

---

### Task 4: OrbView — drawing

**Files:**
- Create: `Sources/OrbView.swift`
- Modify: `build.sh`, `run-tests.sh`, `run-smoke.sh`, `render-preview.sh`
- Modify: `Tools/Smoke.swift`

**Interfaces:**
- Consumes: `OrbGeometry`, `RingItem.dominantColor(of:)`.
- Produces:
  - `final class OrbView: NSView`
  - `var geometry: OrbGeometry`
  - `var dotColors: [NSColor?]` — one per outer slot, nil for an empty slot
  - `var rotation: CGFloat`
  - `func redraw()`

- [x] **Step 1: Add the file to the build scripts**

Add `Sources/OrbView.swift` after `Sources/WheelView.swift` in `build.sh`'s
`SOURCES` array and in the three `swiftc` invocations. Check each script parses:
`bash -n build.sh run-tests.sh run-smoke.sh render-preview.sh`.

- [x] **Step 2: Write the drawing**

Create `Sources/OrbView.swift`:

```swift
import AppKit

/// Draws the orb: the user's outer-ring apps as coloured dots on a dark disc.
///
/// The colour comes from the user's own apps rather than a chosen palette, so the
/// orb is a miniature of their ring and no two people's orbs look alike. Eight
/// dots is also the menu-bar glyph, which is what makes the two read as the same
/// object.
final class OrbView: NSView {
    var geometry = OrbGeometry(size: OrbGeometry.defaultSize) {
        didSet { if geometry != oldValue { needsDisplay = true } }
    }

    /// One entry per outer slot, in ring order. A nil entry is an empty slot.
    var dotColors: [NSColor?] = [] {
        didSet { needsDisplay = true }
    }

    /// The outer ring's rotation, so the orb and a turned wheel agree about which
    /// app is at the top.
    var rotation: CGFloat = 0 {
        didSet { if rotation != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    /// The orb can be clicked while another application is frontmost. Without
    /// this the first click is spent ordering the window and never reaches the
    /// view, so the orb would need two clicks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel is square; the orb is not. Returning nil outside the disc stops
    /// the corners swallowing clicks aimed at whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return geometry.contains(local) ? self : nil
    }

    func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        let centre = CGPoint(x: g.radius, y: g.radius)

        // A flat disc rather than an NSVisualEffectView: a blur composited over
        // every Space all day is real work, and at this size it is indistinguishable
        // from a solid plate.
        NSColor(white: 0.09, alpha: 0.82).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: g.size, height: g.size)).fill()

        let count = dotColors.count
        for (index, colour) in dotColors.enumerated() {
            let at = g.dotCenter(index: index, count: count, rotation: rotation)
            let r = index == 0 ? g.leadDotRadius : g.dotRadius
            (colour ?? NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: at.x - r, y: at.y - r,
                                        width: r * 2, height: r * 2)).fill()
        }

        NSColor(white: 1, alpha: 0.75).setFill()
        let cr = g.centreDotRadius
        NSBezierPath(ovalIn: NSRect(x: centre.x - cr, y: centre.y - cr,
                                    width: cr * 2, height: cr * 2)).fill()
    }
}
```

- [x] **Step 3: Add the smoke checks**

In `Tools/Smoke.swift`, add this function and call it from `main()` inside the
appearance loop, after `exerciseWheel(...)`:

```swift
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
        // Used from Task 6 onwards; referenced here so the unused parameter is not
        // a warning, and `-warnings-as-errors` is on.
        _ = settings
    }
```

Call it from `main()` inside the appearance loop, after `exerciseWheel(...)`:

```swift
                exerciseOrb(outer: outer, settings: settings, appearance: name.rawValue)
```

- [x] **Step 4: Run the smoke test**

Run: `./run-smoke.sh`
Expected: `✓ N smoke checks passed`, N larger by roughly 35.

- [x] **Step 5: Build**

Run: `./build.sh`
Expected: `built build/Chakra.app`, no warnings.

- [ ] Step 6: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/OrbView.swift Tools/Smoke.swift build.sh run-tests.sh \
        run-smoke.sh render-preview.sh
git commit -m "feat: draw the orb"
```

---

### Task 5: OrbView — hover and drag

**Files:**
- Modify: `Sources/OrbView.swift`
- Modify: `Tools/Smoke.swift`

**Interfaces:**
- Consumes: Task 4's `OrbView`.
- Produces, on `OrbView`:
  - `var onClick: (() -> Void)?`
  - `var onRightClick: ((NSEvent) -> Void)?`
  - `var onDropPaths: (([String]) -> Void)?`
  - `var onHoverChanged: ((Bool) -> Void)?`
  - `var onDragBegan: (() -> Void)?`
  - `var onDragMoved: ((CGPoint) -> Void)?` — a proposed **screen** origin
  - `var onDragEnded: (() -> Void)?`
  - `static let clickSlop: CGFloat` (3)

- [x] **Step 1: Write the interaction**

Add to `Sources/OrbView.swift`, inside `OrbView`:

```swift
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDropPaths: (([String]) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    /// A proposed origin for the panel, in screen coordinates. The controller
    /// clamps it; the view does not know which screen it is on.
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    /// Movement under this counts as a click rather than a drag, so a slightly
    /// unsteady click still opens the wheel.
    static let clickSlop: CGFloat = 3

    /// The offset from the pointer to the panel's origin when the press landed.
    /// Held in screen coordinates: deriving it from window-relative coordinates
    /// while the window is moving is the classic cause of jitter and drift.
    private var grabOffset: CGSize?
    private var pressedAt: CGPoint?
    private var didDrag = false
    private var isTargetedByDrag = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
        rebuildTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        for area in trackingAreas { removeTrackingArea(area) }
        guard window != nil else { return }
        // `.activeAlways` is what makes hover work while Chakra is not the front
        // application, and it needs no permission.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways,
                                                 .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        grabOffset = CGSize(width: window.frame.origin.x - pointer.x,
                            height: window.frame.origin.y - pointer.y)
        pressedAt = pointer
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = grabOffset, let start = pressedAt else { return }
        let pointer = NSEvent.mouseLocation
        guard didDrag || hypot(pointer.x - start.x, pointer.y - start.y) > Self.clickSlop
        else { return }
        if !didDrag {
            didDrag = true
            onDragBegan?()
        }
        onDragMoved?(CGPoint(x: pointer.x + offset.width, y: pointer.y + offset.height))
    }

    override func mouseUp(with event: NSEvent) {
        defer { grabOffset = nil; pressedAt = nil }
        if didDrag {
            didDrag = false
            onDragEnded?()
            return
        }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    private func paths(from info: NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: options) as? [URL] else {
            return []
        }
        return urls.map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargetedByDrag = !paths(from: sender).isEmpty
        needsDisplay = true
        return isTargetedByDrag ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargetedByDrag = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargetedByDrag = false
        needsDisplay = true
        let dropped = paths(from: sender)
        guard !dropped.isEmpty else { return false }
        onDropPaths?(dropped)
        return true
    }
```

- [x] **Step 2: Show the drop target**

Still in `OrbView.draw(_:)`, immediately before the centre dot is filled, add:

```swift
        if isTargetedByDrag {
            // A ring round the whole orb rather than a tint, so the feedback is
            // visible whatever colours the user's apps happen to be.
            NSColor.controlAccentColor.setStroke()
            let inset = max(1.5, g.size * 0.03)
            let path = NSBezierPath(ovalIn: NSRect(x: inset / 2, y: inset / 2,
                                                   width: g.size - inset,
                                                   height: g.size - inset))
            path.lineWidth = inset
            path.stroke()
        }
```

- [x] **Step 3: Add the smoke checks**

In `Tools/Smoke.swift`, inside `exerciseOrb`, after the existing loop:

```swift
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
```

`NSEvent()` is a bare event with a zero location, which is all these overrides
read beyond `NSEvent.mouseLocation`; the drag path itself is exercised by hand,
because synthesising a moving pointer needs a real pointer.

- [x] **Step 4: Run the smoke test**

Run: `./run-smoke.sh`
Expected: `✓ N smoke checks passed`.

- [x] **Step 5: Build**

Run: `./build.sh`

- [ ] Step 6: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/OrbView.swift Tools/Smoke.swift
git commit -m "feat: make the orb clickable, draggable and a drop target"
```

---

### Task 6: OrbController — the panel and its lifecycle

**Files:**
- Create: `Sources/OrbController.swift`
- Modify: `build.sh`, `run-tests.sh`, `run-smoke.sh`, `render-preview.sh`
- Modify: `Tools/Smoke.swift`

**Interfaces:**
- Consumes: `OrbView`, `OrbGeometry`, `OrbPlacement`, `OrbEdge`, `Settings`, `OuterRing`, `RingItem.dominantColor(of:)`.
- Produces:
  - `final class OrbController: NSObject`
  - `init(outer: OuterRing, settings: Settings)`
  - `var onClick: (() -> Void)?`
  - `var onRightClick: ((NSEvent) -> Void)?`
  - `var onDropPaths: (([String]) -> Void)?`
  - `func show()` / `func hide()` / `var isVisible: Bool`
  - `func settingsDidChange()`
  - `func setSuppressed(_ suppressed: Bool)` — hides the orb while the wheel is open
  - `func recentre()` — for an orb stranded off screen
  - `static func makePanel(size: CGFloat, hiddenFromCapture: Bool) -> NSPanel`

- [x] **Step 1: Add the file to the build scripts**

Add `Sources/OrbController.swift` after `Sources/OrbView.swift` in all four
scripts. Verify with `bash -n`.

- [x] **Step 2: Write the controller**

Create `Sources/OrbController.swift`:

```swift
import AppKit

/// A panel that can never take keyboard focus.
///
/// Chakra is an accessory app, so activating it would take the menu bar and the
/// typing focus away from whatever the user is working in. The overrides are kept
/// even though a borderless panel already reports false for both: adding `.titled`
/// to the style mask flips `canBecomeKey` to true, and this makes that mistake
/// impossible to make silently.
final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating orb: its panel, where it sits, and when it is on screen.
final class OrbController: NSObject {
    private let outer: OuterRing
    private let settings: Settings

    private var panel: NSPanel?
    private var view: OrbView?

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDropPaths: (([String]) -> Void)?

    private var isHovered = false
    private var isDragging = false
    /// True while the wheel is open. The orb hides then: the wheel is centred and
    /// the orb would sit on top of it.
    private var isSuppressed = false
    private var screenChangeWork: DispatchWorkItem?

    init(outer: OuterRing, settings: Settings) {
        self.outer = outer
        self.settings = settings
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(ringChanged),
            name: OuterRing.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        screenChangeWork?.cancel()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - The panel

    /// Builds the panel with the window-server configuration the orb needs.
    ///
    /// Static and returning the panel so a test can assert the configuration
    /// without going through the whole controller.
    static func makePanel(size: CGFloat, hiddenFromCapture: Bool) -> NSPanel {
        let panel = OrbPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false

        // One below the menu bar: above the Dock (20) and normal windows, but not
        // drawing over the user's menu bar the way `.statusBar` (25) would.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

        // Every Space, over full-screen apps, and hidden while Mission Control is
        // up so the orb is never a stray tile. `.moveToActiveSpace` must never be
        // added: with `.canJoinAllSpaces` it raises an exception and kills the app.
        var behavior: NSWindow.CollectionBehavior =
            [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        if #available(macOS 13, *) { behavior.insert(.canJoinAllApplications) }
        panel.collectionBehavior = behavior

        // Hides the orb's pixels from recordings. It does not hide the window's
        // existence: it is still enumerated by CGWindowListCopyWindowInfo.
        panel.sharingType = hiddenFromCapture ? .none : .readOnly
        return panel
    }

    // MARK: - Lifecycle

    func show() {
        // `isSuppressed` is checked here rather than only in the callers, because
        // there are several and one of them is reached while the wheel is open:
        // dragging the wheel to a new position posts `Settings.didChangeNotification`,
        // which the app delegate turns into `settingsDidChange()`. Without this the
        // orb would reappear on top of the very wheel it is meant to stay out of.
        guard settings.showOrb, !isSuppressed else { return }
        let size = CGFloat(settings.orbSize)
        if panel == nil { build(size: size) }
        guard let panel, let view else { return }

        view.geometry = OrbGeometry(size: size)
        panel.setContentSize(NSSize(width: view.geometry.size, height: view.geometry.size))
        view.frame = NSRect(origin: .zero, size: panel.frame.size)
        refreshDots()

        panel.setFrameOrigin(restoredOrigin(size: view.geometry.size))
        applyIdleState(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Applies a change of setting to an orb that may or may not be on screen.
    func settingsDidChange() {
        guard settings.showOrb else {
            hide()
            // Torn down rather than merely hidden, so an orb that is off costs
            // nothing at all.
            panel = nil
            view = nil
            return
        }
        show()
    }

    func setSuppressed(_ suppressed: Bool) {
        guard isSuppressed != suppressed else { return }
        isSuppressed = suppressed
        if suppressed { hide() } else if settings.showOrb { show() }
    }

    /// Puts a stranded orb back in the middle of the main screen.
    func recentre() {
        settings.clearOrbPosition()
        show()
    }

    private func build(size: CGFloat) {
        let panel = Self.makePanel(size: size,
                                   hiddenFromCapture: settings.orbHiddenFromCapture)
        let view = OrbView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.geometry = OrbGeometry(size: size)
        view.wantsLayer = true
        panel.contentView = view

        view.onClick = { [weak self] in self?.onClick?() }
        view.onRightClick = { [weak self] event in self?.onRightClick?(event) }
        view.onDropPaths = { [weak self] paths in self?.onDropPaths?(paths) }
        view.onHoverChanged = { [weak self] hovered in
            self?.isHovered = hovered
            self?.applyIdleState(animated: true)
        }
        view.onDragBegan = { [weak self] in
            self?.isDragging = true
            self?.applyIdleState(animated: false)
        }
        view.onDragMoved = { [weak self] proposed in self?.move(to: proposed) }
        view.onDragEnded = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            self.savePosition()
            self.applyIdleState(animated: true)
        }

        self.panel = panel
        self.view = view
    }

    // MARK: - Contents

    @objc private func ringChanged() { refreshDots() }

    private func refreshDots() {
        guard let view else { return }
        let count = outer.visibleCount
        view.dotColors = (0..<count).map { index in
            guard let item = outer.item(at: index) else { return nil }
            return RingItem.dominantColor(of: item.icon)
        }
        view.rotation = settings.rotation(for: .outer, slotCount: count)
    }

    // MARK: - Position

    /// The screen the orb should be on, resolved from what was saved.
    ///
    /// By display id first, then by localised name, then the main screen. Display
    /// ids are not stable across reboots or GPU switches, which is why the name is
    /// the second chance rather than the only one.
    private func targetScreen() -> NSScreen? {
        let saved = settings.orbDisplayID
        if saved != 0,
           let byID = NSScreen.screens.first(where: { screen in
               (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                   as? NSNumber)?.intValue == saved
           }) {
            return byID
        }
        let name = settings.orbDisplayName
        if !name.isEmpty,
           let byName = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return byName
        }
        return NSScreen.main
    }

    private func restoredOrigin(size: CGFloat) -> CGPoint {
        guard let screen = targetScreen() else { return .zero }
        let visible = screen.visibleFrame
        guard let fraction = settings.orbFraction else {
            // Never placed. The right-hand edge, two-thirds up: out of the way of
            // the Dock and of most windows' content, and on the side the pointer
            // usually is.
            let start = CGPoint(x: visible.maxX - size - 24,
                                y: visible.minY + visible.height * 0.66)
            return OrbPlacement.clamp(start, size: size, in: visible)
        }
        return OrbPlacement.origin(fromFraction: fraction, size: size, in: visible)
    }

    private func move(to proposed: CGPoint) {
        guard let panel, let view else { return }
        let size = view.geometry.size
        // The screen under the *pointer*, so the orb can be dragged to a second
        // display. Clamping to the starting screen would refuse to cross.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? panel.screen ?? NSScreen.main
        guard let screen else { return }
        var origin = OrbPlacement.clamp(proposed, size: size, in: screen.visibleFrame)
        // Aligned to device pixels, or a fractional drag leaves the orb blurry on a
        // 2x display.
        origin = screen.backingAlignedRect(NSRect(origin: origin,
                                                  size: NSSize(width: size, height: size)),
                                           options: [.alignAllEdgesNearest]).origin
        panel.setFrameOrigin(origin)
    }

    private func savePosition() {
        guard let panel, let view, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        let size = view.geometry.size
        // The untucked origin is what gets saved: the orb must not creep further
        // off the edge every time it is saved while tucked.
        let origin = untuckedOrigin(of: panel.frame.origin, size: size, in: visible)
        settings.orbFraction = OrbPlacement.fraction(ofOrigin: origin, size: size,
                                                     in: visible)
        settings.orbDisplayID =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.intValue ?? 0
        settings.orbDisplayName = screen.localizedName
    }

    /// Where the orb would be if it were not tucked, given where it is now.
    private func untuckedOrigin(of origin: CGPoint, size: CGFloat,
                                in visible: CGRect) -> CGPoint {
        OrbPlacement.clamp(origin, size: size, in: visible)
    }

    // MARK: - Idle, hover, tuck

    private func applyIdleState(animated: Bool) {
        guard let panel, let view else { return }
        let hot = isHovered || isDragging
        let size = view.geometry.size
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let resting = untuckedOrigin(of: panel.frame.origin, size: size, in: visible)

        var origin = resting
        if !hot, settings.orbTucksAtEdge {
            let edge = OrbPlacement.nearestEdge(origin: resting, size: size, in: visible)
            origin = OrbPlacement.tuckedOrigin(resting, size: size, in: visible, edge: edge)
        }
        let opacity = hot ? 1 : CGFloat(settings.orbIdleOpacity)

        guard animated else {
            panel.alphaValue = opacity
            panel.setFrameOrigin(origin)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = opacity
            panel.animator().setFrameOrigin(origin)
        }
    }

    // MARK: - Displays

    @objc private func screensChanged() {
        // Fires several times in a burst while a display is being reconfigured, so
        // the work is debounced rather than done per notification.
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.settings.showOrb, !self.isSuppressed else { return }
            self.show()
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
```

- [x] **Step 3: Add the smoke checks**

In `Tools/Smoke.swift`, inside `exerciseOrb`, append:

```swift
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
        let controller = OrbController(outer: outer, settings: orbSettings)
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
        orbSettings.showOrb = false
```

`exerciseOrb` already takes `settings` — Task 4 gave it that signature. Remove the
`_ = settings` line Task 4 added at the end of the function, since the parameter is
now genuinely used.

- [x] **Step 4: Run the smoke test**

Run: `./run-smoke.sh`
Expected: `✓ N smoke checks passed`.

- [x] **Step 5: Build**

Run: `./build.sh`

- [ ] Step 6: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/OrbController.swift Tools/Smoke.swift build.sh run-tests.sh \
        run-smoke.sh render-preview.sh
git commit -m "feat: add OrbController, the orb's panel and lifecycle"
```

---

### Task 7: Wire the orb into the app

**Files:**
- Modify: `Sources/main.swift`
- Modify: `Sources/WheelWindow.swift`

**Interfaces:**
- Consumes: `OrbController`.
- Produces: an orb that appears when the setting is on, hides while the wheel is open, opens the wheel when clicked, accepts dropped apps, and shows the menu-bar menu on right-click.

- [x] **Step 1: Let the wheel report its visibility to more than one listener**

`WheelController.onVisibilityChanged` is already claimed by `StatusItemController`
for the menu-bar highlight. Adding a second assignment would silently replace the
first, so change it to a list.

In `Sources/WheelWindow.swift`, replace the `onVisibilityChanged` property with:

```swift
    /// Called whenever the wheel appears or disappears.
    ///
    /// A list rather than a single closure: the menu-bar item uses it for its
    /// highlight and the orb uses it to get out of the way, and a second
    /// assignment to a single property would silently discard the first.
    private var visibilityObservers: [(Bool) -> Void] = []

    func observeVisibility(_ observer: @escaping (Bool) -> Void) {
        visibilityObservers.append(observer)
    }

    private func reportVisibility(_ visible: Bool) {
        for observer in visibilityObservers { observer(visible) }
    }
```

Replace the two call sites `onVisibilityChanged?(true)` and
`onVisibilityChanged?(false)` with `reportVisibility(true)` and
`reportVisibility(false)`.

In `Sources/StatusItem.swift`, replace

```swift
        wheel.onVisibilityChanged = { [weak self] visible in
            self?.statusItem.button?.highlight(visible)
        }
```

with

```swift
        wheel.observeVisibility { [weak self] visible in
            self?.statusItem.button?.highlight(visible)
        }
```

- [x] **Step 2: Create the orb in the app delegate**

In `Sources/main.swift`, add a stored property beside `status`:

```swift
    private var orb: OrbController?
```

In `applicationDidFinishLaunching`, after the `StatusItemController` is created and
assigned, add:

```swift
        installOrb()
```

Add these methods to `AppDelegate`:

```swift
    /// Creates the orb if the user has asked for one. Called again whenever the
    /// setting changes, so it is also the teardown path.
    private func installOrb() {
        guard settings.showOrb else {
            orb = nil
            return
        }
        if orb == nil {
            let controller = OrbController(outer: outer, settings: settings)
            controller.onClick = { [weak self] in self?.wheel.toggle(atCursor: false) }
            controller.onRightClick = { [weak self] event in
                self?.status?.showMenu(with: event)
            }
            controller.onDropPaths = { [weak self] paths in self?.status?.add(paths) }
            orb = controller
        }
        orb?.settingsDidChange()
    }
```

**The visibility observer is registered once, at launch, not here.** `observeVisibility`
appends to a list that is never pruned, and `installOrb()` runs again every time the
setting changes — so registering inside it would add another observer on every switch-on,
each of the earlier ones left holding a dead reference forever. Add this to
`applicationDidFinishLaunching` instead, immediately after `installOrb()`:

```swift
        // The orb hides while the wheel is up: the wheel opens at the centre of the
        // screen and the orb would sit on top of it. Registered once and reading
        // `self.orb` when it fires, rather than capturing a particular controller,
        // because the controller is thrown away and rebuilt whenever the setting is
        // switched off and on again.
        wheel.observeVisibility { [weak self] visible in
            self?.orb?.setSuppressed(visible)
        }
```

`StatusItemController.showMenu(with:)` and `.add(_:)` are currently private.
Change both to internal (drop the `private`) and add a line to each explaining
that the orb calls them so the two entry points behave identically.

- [x] **Step 3: React to the setting changing**

Still in `Sources/main.swift`, in `applicationDidFinishLaunching`, after the
existing notification observers, add:

```swift
        // The orb is switched on and off from the settings window, which has no
        // reference to the app delegate.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChangeNotification, object: nil)
```

and the handler:

```swift
    @objc private func settingsChanged() {
        // `installOrb` already ends with `settingsDidChange()`, so calling it again
        // here would reposition the panel and restart its fade a second time for
        // every setting the user touches.
        installOrb()
    }
```

Add `NotificationCenter.default.removeObserver(self)` to
`applicationWillTerminate` if it is not already there.

- [x] **Step 4: Build and smoke**

Run: `./build.sh && ./run-tests.sh && ./run-smoke.sh`
Expected: all three pass.

- [ ] **Step 5: Verify by hand** — **6 of the 10 checks below done, 4 not.** Driven with real
synthetic mouse events rather than by a person, in a single process so nothing could change
between observations. **Passed:** 1 (orb at x 1720, the expected `visible.maxX − size − 24`),
2 (full cycle: wheel opens, orb's level-23 window disappears, wheel dismisses on focus loss,
orb returns to the same pixel), 4 (drag to left edge → x 0; pointer away → x −35, which is 62%
of 56pt; pointer on the sliver → x 0), 9 (menu at (29, 494), i.e. at the orb, not the menu
bar), 10 (position restored to the pixel from the stored fraction). **Check 3 needs its
premise corrected:** clicking the orb *does* make Chakra frontmost, necessarily — the wheel
must be key to take arrow keys and Return, and `windowDidResignKey` is its only dismissal
mechanism. What is required, and what holds, is that the *panel* not activate the app, and
that focus return when the wheel closes. **Not done:** 5 (second display — none attached),
6 (full-screen — inconclusive: Terminal never entered full screen when sent ⌃⌘F, so the orb
staying visible proves nothing; the check was deliberately written to verify the transition
first so it could not produce a false pass), 7 (Mission Control), 8 (Finder drop).

Run: `./build.sh && pkill -x Chakra; open build/Chakra.app`

Then, since these cannot be tested without a person at the machine, check each and
report the result:

1. Settings → Orb → switch it on. The orb appears near the right edge.
2. Click the orb. The wheel opens at the centre of the screen. The orb disappears
   while the wheel is up and returns when it closes.
3. Type in another app, then click the orb. The other app keeps its focus — the
   menu bar must not change to Chakra's.
4. Drag the orb to the left edge, move the pointer away. It dims and slides mostly
   off. Point at the sliver; it comes back.
5. Drag the orb to a second display if one is attached. It crosses.
6. Switch to a full-screen app. Report whether the orb is still visible. If it is
   not, that is the risk the spec flagged; add
   `NSWorkspace.shared.notificationCenter` observation of
   `activeSpaceDidChangeNotification` calling `orderFrontRegardless()` and retest.
7. Open Mission Control. The orb should not appear as a window tile.
8. Drop an app from Finder onto the orb. It is added to the first free slot.
9. Right-click the orb. The menu-bar menu appears.
10. Quit and relaunch. The orb comes back where it was left.

- [ ] Step 6: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/main.swift Sources/WheelWindow.swift Sources/StatusItem.swift
git commit -m "feat: wire the orb into the app"
```

---

### Task 8: The Orb section in Settings

**Files:**
- Modify: `Sources/SettingsWindow.swift`
- Modify: `Sources/main.swift` (Step 2 only, to wire `onRecentreOrb`)

**Interfaces:**
- Consumes: `Settings`'s orb properties, `OrbController.recentre` via a callback.
- Produces: `var onRecentreOrb: (() -> Void)?` on `SettingsController`.

- [x] **Step 0: Stop the window reacting to its own changes**

This task is the first to call `settings.postDidChange()` from inside the settings
window on a per-tick control. `SettingsController` observes that same notification and
answers it with `refreshEverything()`, which sets every control's value back from
storage — including the slider currently under the user's thumb. Dragging the orb size
slider would therefore fight itself on every tick.

Add a re-entrancy flag beside the other stored properties:

```swift
    /// True while this window is applying a change of its own.
    ///
    /// `postDidChange()` is how the app delegate hears about a setting, so the window
    /// has to post; but it also observes that notification, and answering its own post
    /// with a full refresh resets the control the user is still dragging.
    private var isApplyingOwnChange = false

    /// Stores a setting, tells the rest of the app, and does not let the answer come
    /// back round to this window.
    private func applyingOwnChange(_ body: () -> Void) {
        isApplyingOwnChange = true
        body()
        settings.postDidChange()
        isApplyingOwnChange = false
    }
```

and make the observer respect it:

```swift
    @objc private func settingsChangedElsewhere() {
        guard !isApplyingOwnChange else { return }
        ...
    }
```

Read the existing `settingsChangedElsewhere` before editing: it already has guards for
a nil and a hidden window, and this one goes first. Then use `applyingOwnChange { }` in
place of a bare `settings.postDidChange()` in every handler this task adds.

This also fixes the existing Dock checkbox, which reaches the same notification through
`DockPresence.set` — one redundant refresh today rather than one per tick, but the same
bug.

- [x] **Step 1: Add the section**

In `Sources/SettingsWindow.swift`, add stored properties beside the other control
references:

```swift
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
```

Add `buildOrbSection(into: stack)` to `buildContent()`, after
`buildRotationSection(into: stack)`. Then add:

```swift
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
        settings.showOrb = sender.state == .on
        settings.postDidChange()
        refreshOrbSection()
    }

    @objc private func orbSizeChanged(_ sender: NSSlider) {
        settings.orbSize = sender.doubleValue
        orbSizeValue?.stringValue = "\(Int(settings.orbSize.rounded()))pt"
        settings.postDidChange()
    }

    @objc private func orbDimChanged(_ sender: NSSlider) {
        settings.orbIdleOpacity = sender.doubleValue
        orbDimValue?.stringValue = Self.percent(settings.orbIdleOpacity)
        settings.postDidChange()
    }

    @objc private func orbTuckChanged(_ sender: NSButton) {
        settings.orbTucksAtEdge = sender.state == .on
        settings.postDidChange()
    }

    @objc private func orbCaptureChanged(_ sender: NSButton) {
        settings.orbHiddenFromCapture = sender.state == .on
        settings.postDidChange()
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
        for control in [orbTuckBox, orbCaptureBox, orbRecentreButton] {
            control?.isEnabled = on
        }
    }
```

Add `refreshOrbSection()` to `refreshEverything()`.

- [x] **Step 2: Wire the recentre callback**

In `Sources/main.swift`, in `showSettings()`, inside the `if settingsWindow == nil`
block, add:

```swift
            controller.onRecentreOrb = { [weak self] in self?.orb?.recentre() }
```

- [x] **Step 3: Run the smoke test**

The smoke runner fires every control's action, so the new section is covered
automatically. `recentreOrb` opens no panel, so it does not need adding to
`modalActions`.

Run: `./run-smoke.sh`
Expected: `✓ N smoke checks passed`. The check that counts controls and the one
that asserts the settings stack's height may both need their expected numbers
raised; do that rather than loosening them.

- [ ] **Step 4: Build and verify by hand** — **build done, the four visual checks not watched by
a person.** All four are exercised and asserted by the smoke pass, which builds the real
Settings window and fires every control's real target-action: the orb switch, both sliders, and
the greying-out of the dependent controls. Two of them are additionally protected by checks
whose failure was demonstrated by removing the code they cover (the re-entrancy guard, and the
panel rebuild for `sharingType`). What was never done is a person watching the orb resize live
on screen, so "the size slider resizes it live" rests on the asserted setting plus the panel
rebuild path, not on an eye.

Run: `./build.sh && pkill -x Chakra; open build/Chakra.app`

Open Settings and confirm: the orb switch creates and removes the orb immediately;
the size slider resizes it live; the dim slider changes the idle opacity; the
controls below the switch are greyed out when the orb is off.

- [ ] Step 5: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Sources/SettingsWindow.swift Sources/main.swift
git commit -m "feat: add the Orb section to Settings"
```

---

### Task 9: Make the HTML mockups reproducible

The mockups read icons from `/tmp/chakra-icons`, dumped by a Swift file that lives
in `/tmp`. `/tmp` is cleared on reboot, so neither mockup can currently be rebuilt
from a fresh checkout.

**Files:**
- Create: `Tools/DumpIcons.swift`
- Create: `dump-icons.sh`
- Modify: `mockup_common.py`

- [x] **Step 1: Move the dumper into the repository**

Create `Tools/DumpIcons.swift`:

```swift
import AppKit

/// Dumps application icons to PNG, for the HTML design mockups.
///
/// In the repository rather than in /tmp so the mockups can be rebuilt from a
/// fresh checkout: they need the real icons to show the real colours, and a
/// mockup that cannot be regenerated is a mockup that quietly goes stale.
@main
struct DumpIcons {
    static func main() {
        let outputDirectory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "/tmp/chakra-icons"
        try? FileManager.default.createDirectory(atPath: outputDirectory,
                                                 withIntermediateDirectories: true)

        // Keyed by the file stem the mockups ask for. Any app that is not
        // installed is skipped and named, so a missing colour is explained rather
        // than mysterious.
        let apps = [
            ("slack", "/Applications/Slack.app"),
            ("teams", "/Applications/Microsoft Teams.app"),
            ("claude", "/Applications/Claude.app"),
            ("terminal", "/System/Applications/Utilities/Terminal.app"),
            ("chrome", "/Applications/Google Chrome.app"),
            ("apps", "/System/Applications/Apps.app"),
            ("finder", "/System/Library/CoreServices/Finder.app"),
            ("raycast", "/Applications/Raycast.app"),
            ("appstore", "/System/Applications/App Store.app"),
            ("settings", "/System/Applications/System Settings.app"),
            ("notes", "/System/Applications/Notes.app"),
            ("preview", "/System/Applications/Preview.app"),
        ]

        var written = 0
        for (name, path) in apps {
            guard FileManager.default.fileExists(atPath: path) else {
                print("skipped \(name): not installed")
                continue
            }
            let side = 256
            let icon = NSWorkspace.shared.icon(forFile: path)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: side, pixelsHigh: side,
                                             bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bytesPerRow: side * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // Freshly allocated bitmap memory is not zeroed, so an icon with no
            // representations would read back as garbage rather than as nothing.
            context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
            written += 1
        }
        print("wrote \(written) icons to \(outputDirectory)")
    }
}
```

Create `dump-icons.sh`, and `chmod +x` it:

```bash
#!/bin/bash
# Dumps application icons for the HTML design mockups.
#
# The mockups need the real icons so they show the colours the app will actually
# draw. Output goes to /tmp by default because it is regenerable and large.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -O \
  -warnings-as-errors \
  -o build/chakra-dumpicons \
  Tools/DumpIcons.swift

./build/chakra-dumpicons "${1:-/tmp/chakra-icons}"
```

- [x] **Step 2: Have the mockups regenerate what they need**

In `mockup_common.py`, replace the `ICON_DIR` line and add a helper above
`build_apps`:

```python
ICON_DIR = pathlib.Path("/tmp/chakra-icons")


def ensure_icons():
    """Dumps the icons if they are not there.

    /tmp is cleared on reboot, so without this the mockups could only be built
    on a machine where someone had happened to run the dumper already.
    """
    if ICON_DIR.exists() and any(ICON_DIR.glob("*.png")):
        return
    script = pathlib.Path(__file__).parent / "dump-icons.sh"
    subprocess.run([str(script), str(ICON_DIR)], check=True)
```

Add `import subprocess` at the top, and call `ensure_icons()` as the first line of
`build_apps`.

- [x] **Step 3: Verify from a clean state**

```bash
rm -rf /tmp/chakra-icons
python3 make_orb_mockup.py
python3 make_rotation_demo.py
```

Expected: the dumper runs, both HTML files are written, and the printed colours
match what they were before.

- [ ] Step 4: Commit — NOT DONE. Skipped throughout by a standing ruling: the repository has zero commits and no configured user.name/user.email, so no commit was made and no identity was invented.

```bash
git add Tools/DumpIcons.swift dump-icons.sh mockup_common.py
git commit -m "chore: make the HTML mockups reproducible from a checkout"
```

---

### Task 10: A floor of three apps on the outer ring — the model

Added after the orb work, at the user's request: the outer ring must never fall
below three apps, "even if someone wants to delete it". They were offered three
readings and chose the strongest removal rule: **a removal is refused when it would
leave fewer than three apps.** Seeding a fresh ring is explicitly *not* part of it.

Sequenced after the orb because Task 11 modifies `Sources/SettingsWindow.swift`,
which orb Task 8 also modifies.

**The rule, stated once so every step can be checked against it.** A mutation is
refused if it would reduce the number of apps in the *visible* slots to fewer than
`Settings.minOuterApps`. Consequences that are deliberate, not oversights:

- A ring that already holds fewer than three — a fresh install, or one emptied by
  an older build — also refuses removal. Allowing "it is already below three, so one
  fewer does no harm" is precisely how a ring reaches zero. `Choose…` replaces a slot
  and is never refused, so a mistake is always fixable.
- A slot hidden by a low slot count is not on the wheel, so emptying it is allowed.
- An app that has been uninstalled still occupies its slot and still counts. The floor
  governs what the *user* may delete, not what the world does to them.

**Files:**
- Modify: `Sources/Defaults.swift` (one constant)
- Modify: `Sources/OuterRing.swift`
- Modify: `Tests/OuterRingTests.swift`

**Interfaces produced:**
- `Settings.minOuterApps: Int` (3)
- `OuterRing.occupiedCount: Int`
- `OuterRing.canRemove(at:) -> Bool`
- `OuterRing.remove(at:) -> Bool` (was `-> Void`; now `@discardableResult`)
- `OuterRing.canSetVisibleCount(to:) -> Bool`
- `OuterRing.assign(_:at:)` changes behaviour: it now **swaps** rather than clearing.

- [x] **Step 1: Add the constant**

In `Sources/Defaults.swift`, immediately after the `minOuterSlots`/`maxOuterSlots`
group inside `struct Settings`:

```swift
    /// The fewest apps the outer ring may be reduced to.
    ///
    /// Three rather than one because a ring with one app in it is not a ring — the
    /// gesture the whole app is built on, "flick in a direction", stops meaning
    /// anything. Enforced on removal only: a fresh ring starts empty and is filled
    /// by onboarding, so this cannot be an invariant of the stored data.
    static let minOuterApps = 3
```

- [x] **Step 2: Write the failing tests**

In `Tests/OuterRingTests.swift`, add a new suite. It must fail before Step 3.

```swift
    suite("outer/three-app-floor") {
        // No `Settings` binding here: nothing in this suite reads one, and every build
        // script runs with -warnings-as-errors, so an unused `let` is a build failure.
        let ring = OuterRing(defaults: scratchDefaults())

        expectEqual(Settings.minOuterApps, 3, "the floor is three apps")

        // Four apps: one may go, and then no more.
        for (index, path) in ["/a.app", "/b.app", "/c.app", "/d.app"].enumerated() {
            ring.assign(path, at: index)
        }
        expectEqual(ring.occupiedCount, 4, "four apps are on the ring")
        expectEqual(ring.canRemove(at: 3), true, "the fourth app may be removed")
        expectEqual(ring.remove(at: 3), true, "removing the fourth app succeeds")
        expectEqual(ring.occupiedCount, 3, "three apps are left")

        expectEqual(ring.canRemove(at: 2), false, "the third app may not be removed")
        expectEqual(ring.remove(at: 2), false, "removing the third app is refused")
        expectEqual(ring.occupiedCount, 3, "the refused removal changed nothing")
        expectEqual(ring.slots[2], "/c.app", "the refused slot still holds its app")

        // Replacing is never refused, which is the escape from the floor.
        expectEqual(ring.set("/e.app", at: 2), true, "a slot at the floor can be replaced")
        expectEqual(ring.occupiedCount, 3, "replacing does not change the count")

        // An empty slot is not removable, and neither is one out of range.
        expectEqual(ring.canRemove(at: 3), false, "an empty slot cannot be removed")
        expectEqual(ring.canRemove(at: -1), false, "a negative index cannot be removed")
        expectEqual(ring.canRemove(at: OuterRing.capacity), false,
                    "an index past capacity cannot be removed")

        // A ring already below the floor still refuses, because allowing it is how a
        // ring reaches zero.
        let sparseDefaults = scratchDefaults()
        let sparse = OuterRing(defaults: sparseDefaults)
        sparse.assign("/a.app", at: 0)
        sparse.assign("/b.app", at: 1)
        expectEqual(sparse.occupiedCount, 2, "two apps on the ring")
        expectEqual(sparse.canRemove(at: 1), false,
                    "a ring below the floor still refuses a removal")
        expectEqual(sparse.set("/c.app", at: 1), true,
                    "but replacing still works, so a mistake is fixable")

        // A slot hidden by a low slot count is not on the wheel, so it may be emptied
        // even when the visible ring is at the floor.
        //
        // The layout matters. `minOuterSlots` is 4, so the narrowest visible ring is
        // four slots; filling all four would give an occupied count of 4, and removing
        // one of those would leave 3, which the floor permits. To put the VISIBLE ring
        // exactly at the floor the apps have to sit at 0, 1, 2 and 4 — three visible,
        // one parked out of sight.
        let hiddenDefaults = scratchDefaults()
        let hiddenSettings = Settings(defaults: hiddenDefaults)
        let hiddenRing = OuterRing(defaults: hiddenDefaults)
        for index in [0, 1, 2, 4] { hiddenRing.assign("/app\(index).app", at: index) }
        hiddenSettings.outerSlotCount = Settings.minOuterSlots
        expectEqual(hiddenRing.occupiedCount, 3, "only the visible slots count")
        expectEqual(hiddenRing.canRemove(at: 4), true,
                    "a hidden slot may be emptied, since it is not on the wheel")
        expectEqual(hiddenRing.canRemove(at: 0), false,
                    "a visible slot may not, because the visible ring is at the floor")
        // And with one more app visible, the same slot becomes removable again.
        hiddenSettings.outerSlotCount = 5
        expectEqual(hiddenRing.occupiedCount, 4, "raising the count reveals the fourth app")
        expectEqual(hiddenRing.canRemove(at: 0), true,
                    "four visible apps means one may go")
    }

    suite("outer/assign-swaps-rather-than-clears") {
        // `assign` used to clear whichever other slot held the app. Moving an app onto
        // an occupied slot therefore lost an app: it broke the three-app floor, and it
        // silently discarded whatever the user was displacing.
        let ring = OuterRing(defaults: scratchDefaults())
        ring.assign("/a.app", at: 0)
        ring.assign("/b.app", at: 1)
        ring.assign("/c.app", at: 2)
        expectEqual(ring.occupiedCount, 3, "three apps to start")

        expectEqual(ring.assign("/a.app", at: 2), true, "moving A onto C's slot succeeds")
        expectEqual(ring.occupiedCount, 3, "the count is unchanged by a move")
        expectEqual(ring.slots[2], "/a.app", "A is where it was dropped")
        expectEqual(ring.slots[0], "/c.app", "C took A's old slot rather than vanishing")
        expectEqual(ring.slots[1], "/b.app", "B was not touched")

        // Moving onto an empty slot still just moves, leaving the old slot empty.
        expectEqual(ring.assign("/b.app", at: 5), true, "moving B to an empty slot succeeds")
        expectEqual(ring.slots[1], "", "B's old slot is empty")
        expectEqual(ring.slots[5], "/b.app", "B is in its new slot")

        // Assigning an app to the slot it already occupies is a no-op, not a swap
        // with itself.
        expectEqual(ring.assign("/a.app", at: 2), true, "assigning in place succeeds")
        expectEqual(ring.slots[2], "/a.app", "and leaves the app where it was")
        expectEqual(ring.occupiedCount, 3, "with the count unchanged")
    }

    suite("outer/slot-count-cannot-hide-below-the-floor") {
        // Lowering the slot count deletes nothing, but it can put apps out of reach,
        // which leaves the user with a wheel of fewer than three apps just the same.
        let defaults = scratchDefaults()
        let settings = Settings(defaults: defaults)
        let ring = OuterRing(defaults: defaults)
        // Apps clustered at the far end of the ring: slots 0, 5, 6, 7.
        ring.assign("/a.app", at: 0)
        ring.assign("/b.app", at: 5)
        ring.assign("/c.app", at: 6)
        ring.assign("/d.app", at: 7)
        settings.outerSlotCount = 8
        expectEqual(ring.occupiedCount, 4, "four apps are reachable at eight slots")

        expectEqual(ring.canSetVisibleCount(to: 8), true, "staying put is allowed")
        expectEqual(ring.canSetVisibleCount(to: 10), true, "widening is always allowed")
        expectEqual(ring.canSetVisibleCount(to: 7), true,
                    "seven slots still reach three apps")
        expectEqual(ring.canSetVisibleCount(to: 6), false,
                    "six slots would reach only two apps")
        expectEqual(ring.canSetVisibleCount(to: 4), false,
                    "four slots would reach only one app")

        // A ring that is already below the floor must not freeze the slider: hiding
        // empty slots takes nothing away.
        let sparseDefaults = scratchDefaults()
        let sparseRing = OuterRing(defaults: sparseDefaults)
        sparseRing.assign("/a.app", at: 0)
        expectEqual(sparseRing.canSetVisibleCount(to: Settings.minOuterSlots), true,
                    "hiding empty slots is allowed even below the floor")

        // Out-of-range requests are judged on the value that would actually be stored.
        expectEqual(ring.canSetVisibleCount(to: 99), true, "an absurd widening is allowed")
        expectEqual(ring.canSetVisibleCount(to: -5), false,
                    "an absurd narrowing is judged as the clamped minimum")
    }
```

Run `./run-tests.sh`. Expected: it fails to compile, because `occupiedCount`,
`canRemove` and `canSetVisibleCount` do not exist yet and `remove` returns `Void`.

- [x] **Step 3: Implement the floor**

In `Sources/OuterRing.swift`, after `occupiedPaths`:

```swift
    /// How many apps the wheel is showing right now.
    var occupiedCount: Int { occupiedPaths.count }

    /// Whether a slot may be emptied.
    ///
    /// See `Settings.minOuterApps`. A ring that is already below the floor refuses
    /// too: allowing "it is already below three, so one fewer does no harm" is how a
    /// ring reaches zero. `set` and `assign` are never refused by the floor, so a
    /// slot can always be corrected by replacing it.
    func canRemove(at index: Int) -> Bool {
        guard index >= 0, index < Self.capacity, !slots[index].isEmpty else { return false }
        // A hidden slot is not on the wheel, so emptying it takes nothing away from
        // the user and cannot breach the floor.
        guard visibleRange.contains(index) else { return true }
        return occupiedCount - 1 >= Settings.minOuterApps
    }

    /// Whether the visible slot count may be set to `count`.
    ///
    /// Lowering the count deletes nothing, but it hides the tail of the ring, so it
    /// can leave the user with fewer than three reachable apps just as surely as
    /// deleting them would.
    func canSetVisibleCount(to count: Int) -> Bool {
        let clamped = min(max(count, Settings.minOuterSlots), Settings.maxOuterSlots)
        guard clamped < visibleCount else { return true }
        let reachable = (0..<min(clamped, slots.count)).filter { !slots[$0].isEmpty }.count
        // The second test is what stops a ring that is already below the floor from
        // freezing the slider: hiding slots that hold nothing takes nothing away.
        return reachable >= Settings.minOuterApps || reachable >= occupiedCount
    }
```

Replace `remove(at:)` with:

```swift
    /// Empties a slot. Returns false when the floor refuses it, so the caller can
    /// say why rather than appearing to do nothing.
    @discardableResult
    func remove(at index: Int) -> Bool {
        guard canRemove(at: index) else { return false }
        slots[index] = ""
        save()
        return true
    }
```

In `assign(_:at:)`, replace the loop that clears other slots:

```swift
        for (other, existing) in slots.enumerated() where existing == normalized && other != index {
            slots[other] = ""
        }
```

with a swap:

```swift
        // Swapped rather than cleared. Clearing the app's old slot loses an app
        // whenever the target slot was occupied, which both breaches the three-app
        // floor and silently discards the app the user was displacing. Putting the
        // displaced app into the vacated slot keeps the count and keeps it visible.
        // When the target slot was empty this assigns "" and so behaves exactly as
        // before; when the app is already in this slot, `firstIndex` finds `index`
        // itself and the swap is skipped.
        if let existing = slots.firstIndex(of: normalized), existing != index {
            slots[existing] = slots[index]
        }
```

Leave `replaceAll(_:)` alone, and add to its doc comment:

```swift
    /// The floor deliberately does not apply here. This is "the ring is now exactly
    /// this list", not a deletion, and its callers — onboarding and the settings
    /// window — pass a list they have already decided on. The floor is enforced where
    /// those lists are built instead, in Task 11.
```

- [x] **Step 4: Fix the callers that now warn**

`remove(at:)` gained a return value. `-warnings-as-errors` is on, so every caller
that ignores it must be found and dealt with. Find them:

```bash
grep -rn "\.remove(at:" Sources Tools Tests
```

`@discardableResult` means an ignored result is not a warning, so no caller *has* to
change to compile. Each one still has to be read and a decision recorded: a caller
that ignores a refusal will silently appear to do nothing. Task 11 handles the two
real ones (the settings window and the wheel's right-click menu). Note in your report
which callers you found and which task owns each.

- [x] **Step 5: Run the tests**

Run: `./run-tests.sh`. Expected: all previous checks still pass, plus the new suites.
If an existing check fails, read it before changing it — a test that assumed a
removal always succeeds, or that `assign` clears the old slot, is an assumption this
task deliberately changes, and its expectation should be updated with a comment
saying why. A test that fails for any other reason is a real defect in this task.

- [x] **Step 6: Build**

Run: `./build.sh` and `./run-smoke.sh`.

---

### Task 11: A floor of three apps — the interface honours it

**Files:**
- Modify: `Sources/SettingsWindow.swift`
- Modify: `Sources/WheelView.swift`
- Modify: `Sources/WheelWindow.swift` (only if the right-click removal path lives there)
- Modify: `Sources/Onboarding.swift`
- Modify: `Tools/Smoke.swift`

**Consumes:** Task 10's `canRemove(at:)`, `canSetVisibleCount(to:)`, `occupiedCount`,
and `remove(at:)`'s return value.

**The copy, fixed here so all three places say the same thing:**
> The ring keeps at least 3 apps. Use Choose… to replace this one instead.

Shortened for the wheel's centre note, which has room for about forty characters:
> The ring keeps at least 3 apps

- [x] **Step 1: The settings window's per-slot Clear**

Read `Sources/SettingsWindow.swift` around `refreshSlots()` and `clearSlot(_:)`
first — the line numbers below will have moved by the time this task runs.

Where the Clear buttons are enabled, currently `slotClears[index].isEnabled = item != nil`,
require the floor as well:

```swift
            // Greyed out at the floor rather than refusing on click, so the limit is
            // visible before the user tries.
            slotClears[index].isEnabled = item != nil && outer.canRemove(at: index)
```

In `clearSlot(_:)`, respect the refusal even so — a keyboard equivalent or an
accessibility client can invoke a greyed button's action. **The slot index comes from
`sender.tag`, not from a local named `index`**, and the refresh helper is `applied()`,
not `ringDidChange()`. The existing body is:

```swift
    @objc private func clearSlot(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < OuterRing.capacity else { return }
        outer.remove(at: sender.tag)
        applied()
    }
```

Make it:

```swift
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
```

Add the note helper near the other small helpers:

```swift
    /// Explains the three-app floor. An alert rather than a label, because this is
    /// only ever reached by a route that bypassed the greyed-out button, so there is
    /// no room set aside for it.
    private func presentFloorNote() {
        let alert = NSAlert()
        alert.messageText = "The ring keeps at least \(Settings.minOuterApps) apps"
        alert.informativeText = "Use Choose… to replace this one instead."
        alert.alertStyle = .informational
        alert.runModal()
    }
```

- [x] **Step 2: The settings window's "Clear All"**

A button labelled "Clear All" that cannot clear all is a lie. Rename it and make it
honest: it empties every visible slot except the first `Settings.minOuterApps`
occupied ones, and is disabled when there is nothing it may remove.

```swift
        buttons.addView(button("Clear the Others", #selector(clearOthers)), in: .leading)
```

Keep a reference to it so it can be enabled and disabled, alongside the other stored
controls. The existing `clearAll` is:

```swift
    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Empty every slot?"
        alert.informativeText = "The eight outer positions will be cleared. Your recently "
            + "used apps in the inner ring are not affected."
        ...
        outer.replaceAll([])
        applied()
    }
```

Two things are wrong with it beyond the floor. It empties the ring completely, and its
copy hardcodes "eight" — which stopped being true when the slot count became a setting
the user can move between 4 and 10. Replace the whole method:

```swift
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
```

Note `applied()` is this window's refresh helper — `refreshSlots()` plus
`wheel.settingsDidChange()`. There is no `ringDidChange()`.

Note that `replaceAll` compacts the ring — the kept apps move to slots 0, 1, 2. That
is a real behaviour change from "Clear All" and it is acceptable here only because
the user asked to start over. Say so in the button's note:

```swift
        stack.addView(note("Empties every slot except the first \(Settings.minOuterApps) "
                           + "apps, which move to the top of the ring. The ring keeps at "
                           + "least \(Settings.minOuterApps) apps, so there is always "
                           + "something to flick to."), in: .top)
```

Enable it only when it would do something:

```swift
        clearOthersButton?.isEnabled = outer.occupiedCount > Settings.minOuterApps
```

- [x] **Step 3: The slot-count slider**

In `outerCountChanged(_:)`, refuse a value that would hide apps below the floor and
put the slider back where it was, rather than storing it:

```swift
    @objc private func outerCountChanged(_ sender: NSSlider) {
        let wanted = Int(sender.doubleValue.rounded())
        guard outer.canSetVisibleCount(to: wanted) else {
            // Snapped back rather than left where the user dragged it, so the slider
            // never shows a count that is not in force.
            sender.doubleValue = Double(settings.outerSlotCount)
            flashSlotCountNote()
            return
        }
        settings.outerSlotCount = wanted
        applied()
    }
```

Read the existing `outerCountChanged` first: it is at roughly `SettingsWindow.swift:506`
and already does its own refresh work. Keep whatever it calls rather than substituting
`applied()` blindly — the point of this step is only the refusal and the snap-back.

Add a note field under the slider — an alert here would be far too heavy for a drag —
and a helper that shows it and clears it after a few seconds:

```swift
    /// Shown under the slot-count slider when a narrower ring is refused. A label
    /// rather than an alert: this fires while the user is dragging, and a modal in the
    /// middle of a drag would be intolerable.
    private func flashSlotCountNote() {
        guard let note = outerCountNote else { return }
        note.stringValue = "Turning it down that far would hide all but "
            + "\(outer.occupiedCount - 1) of your apps. The ring keeps at least "
            + "\(Settings.minOuterApps)."
        note.textColor = .systemOrange
        // Cancelled and rescheduled, so dragging the slider does not leave a stack of
        // timers each clearing the note out from under the next.
        slotCountNoteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.outerCountNote?.stringValue = ""
            self?.outerCountNote?.textColor = .secondaryLabelColor
        }
        slotCountNoteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
```

The message's "all but N" arithmetic is a guess about what the user would have been
left with. Compute it properly from the ring instead of subtracting one — read
`canSetVisibleCount` and mirror its counting, or drop the number and say "would hide
too many of your apps".

- [x] **Step 4: The wheel's right-click removal**

Find the right-click path — `onRemoveOuter` in `Sources/WheelView.swift`, wired up in
`Sources/WheelWindow.swift`. The menu item must be disabled at the floor, and the
"is missing" hint must stop telling the user to do something that will be refused.

In the wheel's context menu construction, disable the item:

```swift
        // Disabled rather than absent, so the menu does not change shape depending on
        // how many apps are on the ring.
        removeItem.isEnabled = outer.canRemove(at: index)
```

`WheelView` does not hold the ring, so pass the answer in rather than reaching for it:
add `var canRemoveOuter: ((Int) -> Bool)?` to `WheelView` and set it from
`WheelWindow` next to `onRemoveOuter`. Read both files and follow whichever pattern
they already use for this.

Then the two missing-app hints, currently:

```swift
            flashMessage("\(entry.name) is missing — right-click to remove")
```

become honest about the floor:

```swift
            let canRemove = canRemoveOuter?(index) ?? true
            flashMessage(canRemove
                ? "\(entry.name) is missing — right-click to remove"
                : "\(entry.name) is missing — right-click to replace it")
```

There are two of these (the click path and the keyboard path). Both must change, and
the `index` in scope at each may be named differently — read the surrounding code.

- [x] **Step 5: Onboarding stops offering an empty ring**

In `Sources/Onboarding.swift`, the welcome window offers "Start Empty", which
produces exactly the state the floor exists to prevent. Replace it with a button that
takes the user to Settings, so the escape from "I do not want your suggestions" still
exists:

```swift
        let choose = NSButton(title: "Choose Them Myself", target: self,
                              action: #selector(chooseManually))
        choose.bezelStyle = .rounded
        stack.addView(choose, in: .top)
```

```swift
    /// Marks onboarding done and opens Settings, where the user can fill the ring by
    /// hand. This replaced a "Start Empty" button: an empty ring is the one state the
    /// three-app floor exists to prevent, and offering it as a first-run choice made
    /// the floor look arbitrary the first time the user hit it.
    @objc private func chooseManually() {
        settings.didOnboard = true
        close()
        onOpenSettings?()
    }
```

`onOpenSettings` may not exist on the onboarding controller. Read the file: it already
has an `onSetUpRing` callback and the app delegate wires it. Add `onOpenSettings` in
the same shape and wire it in `Sources/main.swift` beside the others, or reuse an
existing callback if one already opens Settings.

Also check the "Nothing new to add" screen: its Done button currently calls
`chooseEmpty`. It must keep whatever the ring already has and simply dismiss — read
`chooseEmpty` and, if it does more than mark onboarding done, give the Done button its
own action that only dismisses.

Finally, the confirmation screen lets the user remove proposed apps one at a time. If
the proposal holds at least `Settings.minOuterApps` apps, stop the user from
deselecting below that: disable the remaining Remove buttons at the floor, with the
same wording. If the machine only offered one or two apps, do not block — there is
nothing to block with.

- [x] **Step 6: Smoke checks**

In `Tools/Smoke.swift`, the settings window pass already fires every control's action.
Add a check that the floor is visible in the interface, not just in the model — a
greyed button is the whole user-facing point:

```swift
        // A ring at the floor must show its Clear buttons greyed out. The smoke runner
        // fires every control's action, so without this the refusal would be exercised
        // but never asserted.
        // `scratchDefaults()` is a Tests/ helper and does not exist here. The smoke
        // runner has one scratch suite of its own, built in `main()` and named by
        // `Smoke.suiteName`; a second ring must be given its own suite name or it
        // would share — and corrupt — the state the rest of the pass is using.
        let floorSuite = "\(suiteName).floor"
        UserDefaults().removePersistentDomain(forName: floorSuite)
        guard let floorDefaults = UserDefaults(suiteName: floorSuite) else {
            fail("[\(appearance)] could not open a scratch defaults suite for the floor")
            return
        }
        defer { floorDefaults.removePersistentDomain(forName: floorSuite) }
        let floorRing = OuterRing(defaults: floorDefaults)
        for (index, path) in ["/System/Applications/Notes.app",
                              "/System/Applications/Mail.app",
                              "/System/Applications/Music.app"].enumerated() {
            floorRing.assign(path, at: index)
        }
        check(floorRing.occupiedCount == Settings.minOuterApps,
              "[\(appearance)] the test ring sits exactly at the floor")
        check(!floorRing.canRemove(at: 0),
              "[\(appearance)] a ring at the floor refuses removal")
        let floorSettings = Settings(defaults: floorDefaults)
        let floorWheel = WheelController(outer: floorRing, recents: recents,
                                        settings: floorSettings)
        let floorWindow = SettingsController(outer: floorRing, settings: floorSettings,
                                            wheel: floorWheel)
        floorWindow.show()
        let disabled = allControls(in: floorWindow.window?.contentView)
            .filter { ($0 as? NSButton)?.title == "Clear" }
        check(!disabled.isEmpty, "[\(appearance)] the settings window has Clear buttons")
        check(disabled.allSatisfy { !$0.isEnabled },
              "[\(appearance)] every Clear button is greyed out at the floor")
        floorWindow.window?.orderOut(nil)
```

`allControls(in:)` takes a non-optional view in the existing helper, and
`SettingsController` may not expose `window`. Read `Tools/Smoke.swift` and
`Sources/SettingsWindow.swift` and adapt — find the window through `NSApp.windows` by
title, the way the existing settings pass does, rather than adding an accessor just
for the test.

- [ ] **Step 7: Verify** — **the three scripts pass; of the four by-hand checks, 1 is covered by
an assertion, 2 partly, 1 is void.** Scripts: 1,712 unit checks, 396 smoke checks, clean build,
zero warnings. **Check 1 (Clear buttons grey at the floor)** is now asserted by
`exerciseAppFloor` in `Tools/Smoke.swift`, including that a fourth app re-enables one, and the
check's failure was demonstrated by removing the floor from the button-enabling code ("3 of 10
were not"). **Check 2 (slider springs back, note appears):** the refusal and snap-back are
exercised, the note's appearance was not visually confirmed. **Check 3 (right-click Remove
greyed) is void** — there is no context menu on an outer slot; right-click calls
`onRemoveOuter` directly. That was an error in this plan, not a missing feature, and the
related hint wording was corrected as a result. **Check 4 (fresh onboarding offers "Choose Them
Myself" and no way to start empty):** the welcome window is built and walked by the onboarding
smoke pass, but a real first-run with the preferences deleted was not performed.

Run `./run-tests.sh`, `./run-smoke.sh` and `./build.sh`. All three must pass with no
warnings. Then check by hand, since this is interface behaviour:

1. Open Settings with four apps on the ring. Clear one. The remaining three Clear
   buttons grey out.
2. Try to drag the slot-count slider down far enough to hide apps. It springs back and
   the note appears.
3. Open the wheel, right-click an app. Remove is greyed.
4. Delete Chakra's preferences, launch, and confirm the welcome window offers
   "Choose Them Myself" and no way to start empty.

---

## Self-review

**Spec coverage.** Walked each spec section:

| Spec section | Task |
|---|---|
| 1. The orb window | 6 (`makePanel`), smoke-checked |
| 1. Content view — `acceptsFirstMouse`, `hitTest`, tracking area | 4, 5 |
| 2. Appearance | 4 |
| 3. Showing and hiding | 6 (`setSuppressed`), 7 |
| 4. Idle, hover, edge tuck | 1 (arithmetic), 6 (`applyIdleState`) |
| 5. Dragging | 5 (gesture), 6 (`move`, clamping, pixel alignment) |
| 6. Remembering where it is | 1 (fractions), 3 (keys), 6 (`targetScreen`, `savePosition`) |
| 7. Clicking the orb; `.center` default | 3, 7 |
| 8. Screen capture | 3 (setting), 6 (`sharingType`), 8 (control) |
| 9. Launching with the machine | Nothing to build; already shipped |
| 10. Keeping the wheel open | **Deliberately not in this plan.** Second phase, own plan. |
| Settings added | 8 |
| Testing | 1, 2, 3 unit; 4, 5, 6 smoke; 7 by hand |

**Placeholder scan.** No TBD, no "handle edge cases", no "similar to Task N". Every
code step carries the code. One deliberate instruction to read existing code rather
than assume: Task 3 Step 4 on `Settings.sane`, because that helper's exact
signature must be matched rather than guessed.

**Type consistency.** Checked across tasks: `OrbGeometry(size:)`,
`geometry.size`, `dotCenter(index:count:rotation:)`, `contains(_:)`,
`OrbPlacement.clamp(_:size:in:)`, `nearestEdge(origin:size:in:)`,
`tuckedOrigin(_:size:in:edge:)`, `fraction(ofOrigin:size:in:)`,
`origin(fromFraction:size:in:)`, `OrbView.dotColors`, `OrbView.rotation`,
`OrbController.makePanel(size:hiddenFromCapture:)`, `setSuppressed(_:)`,
`settingsDidChange()`, `recentre()`, `Settings.minOrbOpacity`. Each is defined in
one task and used with the same spelling in the others.

**Gap found and closed during review:** `WheelController.onVisibilityChanged` is a
single closure already used by the menu-bar item. The orb needs the same signal, and
a second assignment would have silently broken the menu-bar highlight. Task 7 Step 1
converts it to a list of observers.

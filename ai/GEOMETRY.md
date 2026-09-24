# Geometry

Every measurement, and a picture of what it means. All values are **unscaled points**; the whole wheel
multiplies by one scale factor, so nothing can drift apart.

Source of truth: `Sources/Geometry.swift`, `Sources/OrbGeometry.swift`, `Sources/OrbPlacement.swift`.
Every number below was read from those files, not recalled.

## The wheel in cross-section

Read this as a slice from the centre outwards. It is the single most useful diagram in the project,
because hit-testing, drawing and the glass mask all derive from these same radii.

```
  centre
    │
    │◄── 72 ──►│                                              hole: see-through
    │          │                                              HitTarget = .center
    │          │◄─ inner glass band ─►│
    │          │   72 ──────── 128    │
    │              │  ● icon 40pt │                           inner ring: recents
    │              │  radius 100  │                           HitTarget = .slot(.inner, i)
    │                             │
    │                        133.5 ─┤ ringBoundary — derived, never hardcoded:
    │                               │   ((100 + 40/2) + (175 − 56/2)) / 2
    │                               │   i.e. exactly midway between where the
    │                               │   two rings' icons stop
    │                               │
    │                        │◄─ outer glass band ─►│
    │                        │  139 ────────── 211  │
    │                             │ ●● icon 56pt │                outer ring: pinned
    │                             │ radius 175   │                HitTarget = .slot(.outer, i)
    │                                           │
    │                                       211 ─┤ glass edge (baseDiscRadius 227 − margin 8… see note)
    │                                            │
    │                                       221 ─┤ 211 + grace 10 — still counts as a hit
    │                                            │
    │                                            └─►  HitTarget = .outside
```

**The 10pt grace margin** exists so a click a hair outside the glass still launches rather than
dismissing. Beyond it, the click is a dismissal.

## Every constant

| Constant | Value | What it is |
|---|---|---|
| `baseHoleRadius` | 72 | The see-through hole. Also where the centre pill must fit. |
| `baseInnerRadius` | 100 | Inner ring icon centres |
| `baseInnerIconSize` | 40 | Inner icon edge length |
| `baseOuterRadius` | 175 | Outer ring icon centres |
| `baseOuterIconSize` | 56 | Outer icon edge length |
| `baseDiscRadius` | 227 | Outermost extent used for screen fitting |
| `baseGrace` | 10 | Forgiveness band outside the glass |
| `baseMargin` | 8 | Padding used to derive the glass bands |
| `basePillHeight` | 26 | The centre label |
| `basePillTextWidth` | 104 | " |
| `hoverGrowth` | **1.5** | How much a pointed-at icon grows |
| `baseHighlightInset` | 11 | Plate drawn around a grown icon, per side |
| `minScale` / `maxScale` | 0.2 / 1.4 | 0.2 keeps icons recognisable; 1.4 is the largest the slider offers |
| `ringBoundary` | 133.5 | **Derived**, see the diagram |

Glass bands, at scale 1: **72 → 128** (inner) and **139 → 211** (outer), an 11pt gap between them.

## The tightest number in the project

A hovered icon grows 1.5× and gains an 11pt plate per side. It must not touch its neighbour at the
**maximum** slot count. `Tests/GeometryTests.swift` → `geometry/slot-crowding` proves it, computing
both sides from the constants rather than hardcoding — so raising a slot count fails the build instead
of shipping overlapping icons.

| Ring | Max slots | Grown plate | Centre spacing | Margin |
|---|---|---|---|---|
| Outer | 10 | 56 × 1.5 + 22 = **106.0** | **108.2** | **2.2pt** ← tightest in the app |
| Inner | 7 | 40 × 1.5 + 22 = **82.0** | 86.8 | 4.8pt |

**Spacing is the straight-line (chord) distance between adjacent centres**, which is what the test
measures with `hypot`. The *arc* lengths are 110.0 and 89.8. Quoting the arc overstates the outer
ring's headroom by nearly 2pt out of a total of 2.2 — the source comment used to do exactly that and
was corrected. If you change `hoverGrowth`, `baseHighlightInset`, or either maximum slot count, this
test is the one that will stop you.

## Angles: slot 0 at twelve o'clock, clockwise

```
                       slot 0
                         │
              slot 7  ╲  │  ╱  slot 1
                       ╲ │ ╱
          slot 6 ───────  ● ─────── slot 2        θ(i, n) = π/2 − 2π·i/n
                       ╱ │ ╲
              slot 5  ╱  │  ╲  slot 3
                         │
                       slot 4
```

Reverse mapping, angle → slot index:

```
turns = (π/2 − angle − rotation) / 2π
turns −= floor(turns)              // normalise into [0, 1)
index  = round(turns × count) mod count
```

The `mod` is load-bearing: a point a hair *counter-clockwise* of twelve o'clock rounds up to `count`,
and the modulo wraps it back to 0. There is a test for exactly that point.

## Rotation is stored as whole slots, never as an angle

```
stored:  steps ∈ [−1000, 1000]           an integer count of slots
derived: wrapped  = ((steps % count) + count) % count
         rotation = 2π × wrapped / count
```

Two reasons, both from the source: a ring only ever comes to rest **on** a slot, and a slot offset
stays meaningful when the user changes the slot count — a saved *angle* would land between two apps.
The modulo also means a ring turned five notches and then cut to four slots returns somewhere sensible
rather than spinning past its own start.

## Screen fitting

An unscaled wheel needs `2 × (227 + 8) = 470pt`. Below that it shrinks:

```
fittingScale = min((shorter_dimension − 16) / 454, 1.4)      clamped to 0.2 … 1.4
drawnScale   = min(what the user chose, fittingScale)
```

Both are resolved in one place so drawing and hit-testing can never disagree. Note the source checks
**both** screen dimensions rather than only the shorter one, because `min` hands NaN through in one
argument order and swallows it in the other.

## Motion

| | Value | Note |
|---|---|---|
| Opening sweep | 0.25 s, ease-out cubic `1 − (1 − t)³` | Fast then settling — reads mechanical rather than like a linear slide |
| Snap after a spin | 0.26 s | |
| Outer ring start offset | 0.55 rad | Outer **leads** |
| Inner ring start offset | 0.80 rad | Inner **follows**, so it reads as one object settling |
| Scroll → radians, trackpad | `delta × 0.012` | A trackpad sends many small precise deltas |
| Scroll → radians, mouse wheel | `delta × 0.15` | A wheel sends a few large line-based ones |

One factor for both input kinds would make the trackpad useless or the wheel unusable.

## The glass, from four circles

The glass is two separate bands with see-through desktop in the hole, *between* them, and outside them.
Rather than composing shapes, four concentric circles are nested under the **even-odd winding rule**:

```
radii:  72      128     139     211
        │        │       │       │
   ─────┴────────┴───────┴───────┴─────►
        ▓▓▓▓▓▓▓▓▓▓        ▓▓▓▓▓▓▓▓        ▓ = filled (odd number of circles contain it)
   hole            gap             outside
```

A point is filled only when an odd number of circles contain it, which alternates band, gap, band as
the radius grows. Every radius is derived from a ring's radius, icon size and padding, so the glass can
never drift out of step with the icons behind it.

Implementation note: the mask is applied to `NSVisualEffectView.maskImage` — the supported route for a
non-rectangular blur, since a CALayer mask can defeat it — and drawn through
`NSImage(size:flipped:drawingHandler:)` rather than `lockFocus`, which would bake one bitmap at the
current screen's scale and stay soft after a move to a different display.

## The orb

```
        ┌──────────────────────┐
        │    ●   ← lead dot    │    size:  36 … 56 … 76 pt   (min, default, max)
        │  ●       ●           │    level: 23  (menu bar is 24, Dock is 20)
        │      ·               │    idle alpha: 0.35  (floor 0.15)
        │  ●       ●           │
        │      ●               │    all dot measurements are FRACTIONS of size,
        └──────────────────────┘    so everything scales with the one slider
```

| Measurement | Fraction of size | At 56pt |
|---|---|---|
| Dot ring radius | 0.30 | 16.8 |
| Lead dot radius (slot 0) | 0.075 | 4.2 |
| Other dot radius | 0.055 | 3.1 |
| Centre dot radius | 0.035 | 2.0 |

Slot 0's dot is drawn larger so the orb has a visible orientation rather than reading as a symmetrical
smear. The outer ring's rotation is applied to the dots, so a turned wheel and the orb agree about
which app is at the top.

Size bounds have a stated reason: below 36pt the dots stop being distinguishable; above 76pt the orb
stops reading as a button and starts reading as a window.

The plate is a flat disc, **deliberately not** an `NSVisualEffectView`: a blur composited over every
Space all day is real work, and at this size it is indistinguishable from a solid plate.

## Orb placement and the edge tuck

```
  edgeThreshold = 14pt      within this of an edge → counts as "at" that edge
  tuckFraction  = 0.62      how much slides off, leaving a 38% sliver

       mid-screen            at the edge            tucked
   ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
   │             │      │            ◕│      │            ◖│  ← 38% of 56 = 21pt
   │      ◕      │      │             │      │             │     sliver showing
   └─────────────┘      └─────────────┘      └─────────────┘
                          x = maxX−size        x = maxX−size+34.72
```

At a **corner**, two edges are within threshold at once and the horizontal one wins: sliding sideways
hides less of a circle's silhouette than sliding up or down does.

A test pins the *purpose* rather than the formula — the remaining sliver must be at least **18pt**
wide, because a sliver you cannot point at is not a sliver.

**That test only checks one orb size, and the invariant does not hold at all of them.**
`Tests/OrbPlacementTests.swift:8` sets `size = 56`, the default, giving a 21.3pt sliver. The sliver is
`size × (1 − 0.62)`, so:

| Orb size | Sliver | Against the project's own 18pt bar |
|---|---|---|
| 36 (minimum) | **13.7pt** | **below it** |
| 56 (default) | 21.3pt | fine |
| 76 (maximum) | 28.9pt | fine |

So a user who shrinks the orb to its minimum and tucks it gets a sliver smaller than this project
itself considers pointable. It is still visible and still hoverable — this is a comfort gap, not a
broken feature — but the test gives more confidence than it earns, because it never varies the size.
Listed in `PENDING.md`; fixing it is a product decision (scale `tuckFraction` with size, raise the
minimum orb size, or accept and delete the 18pt claim).

## Position persistence: a fraction of *travel*

```
travel   = visible.width − size          NOT visible.width
fraction = (origin.x − visible.minX) / travel
```

The denominator is the travel available to the *origin*, which is what makes the round trip exact at
both extremes. Stored as `{display id, display name, fraction x, fraction y}` rather than a point, so
the orb returns to the same relative place after a resolution change, a reboot, or a monitor being
unplugged. The display is resolved by id first, then by localised name, then the main screen — display
ids are not stable across reboots or GPU switches, which is why the name is a second chance rather than
the only one.

Verified against the running app: stored `0.7746559 × (1800 − 56) = 1351.0`, matching the observed
window frame to the pixel, on a display whose `visibleFrame` differs from its `frame`.

Also: the frame is put through `NSScreen.backingAlignedRect(_:options:)`, or a fractional drag leaves
the orb blurry on a 2× display.

## Slot counts and the floor

| | Min | Default | Max |
|---|---|---|---|
| Outer slots | 4 | 8 | 10 |
| Inner slots | 0 (ring off) | 5 | 7 |
| Outer **apps** | **3** | — | — |

`Settings.minOuterApps = 3` is a floor on *apps*, not slots: a removal that would leave fewer than
three is refused. Note `minOuterApps (3) < minOuterSlots (4)`. If a future edit ever makes
`minOuterApps ≥ minOuterSlots`, the ring becomes impossible to satisfy at the minimum slot count —
it would not crash, but no removal could ever succeed. See `INVARIANTS.md`.

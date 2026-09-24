# Chakra — Design Spec

**Date:** 2026-09-10
**Status:** Approved for implementation (v1)

## Goal

A macOS menu-bar app that opens a circular, two-ring launcher at the press of a
key. The outer ring holds eight apps the user chooses and never moves. The inner
ring shows the five apps they most recently used, refreshed automatically. One
click launches; the ring disappears.

Chakra needs **no system permissions** — no Accessibility, no Screen Recording,
no Automation. This is a hard constraint, not a preference: every design choice
below that looks roundabout exists to preserve it.

## Non-goals for v1

Project/workspace groups (one slot firing several apps at once) are deferred to
v2 by explicit decision. So are nested rings, profiles and window-level
switching.

Two things listed here originally have since been built, at the user's request,
and are specified below: a **settings window** (§ Settings) and **rearranging the
outer ring** by dragging one slot onto another (§ The outer ring).

## Naming

The app is **Chakra** — Sanskrit for *wheel*. Bundle identifier `local.chakra`,
executable `Chakra`, no App Store ambition (the name collides with the Chakra UI
React library in developer mindshare; the user accepted that trade for a
personal tool).

## Architecture

Thirteen focused Swift files compiled by `swiftc` directly into a hand-assembled
`.app` bundle. No Xcode project, no SwiftPM, no third-party dependencies.

```
Sources/
  Geometry.swift    Pure math. Radii, slot angles, hit-testing, the size clamp
                    and the saved-position conversion. Zero AppKit state — this
                    is the file the unit tests hammer.
  Models.swift      RingItem: a launchable thing (path, name, icon, missing
                    flag), path canonicalisation, the item cache, icon loading
                    and dominant-colour extraction.
  Shortcut.swift    Carbon hot keys, modifier translation and how a shortcut is
                    spelled. No window, so the labelling is testable.
  Defaults.swift    Every persisted key, the typed and clamped `Settings` view
                    over `UserDefaults`, and `DockPresence`.
  OuterRing.swift   The 8 fixed, user-owned slots. Persisted.
  Recents.swift     The recency queue: live tracking, persistence, Spotlight
                    seeding, and the substitution rule.
  Proposal.swift    Which apps to offer at set-up, and reading the Dock's own
                    pinned list. No AppKit, so both are testable.
  WheelView.swift   All drawing and mouse/keyboard interaction.
  WheelWindow.swift The transparent full-screen window + the two glass bands.
  StatusItem.swift  Menu-bar button, its drop target, and the right-click menu.
  SettingsWindow.swift  The settings window, the shortcut recorder and the
                    login-item helper.
  Onboarding.swift  First-launch window.
  main.swift        AppDelegate, hotkey registration, the main menu, wiring.
Tests/
  TestMain.swift    Assertion-based test runner compiled as a separate binary,
                    plus one file per subject: Geometry, Model, OuterRing,
                    Recents, Settings, Proposal, Shortcut.
Tools/
  Preview.swift     Renders the wheel to PNG offscreen, so it can be inspected
                    without Screen Recording permission.
  MakeIcon.swift    Draws the app icon and writes an .iconset for iconutil.
```

`Geometry`, `Models`, `Shortcut`, `Defaults`, `OuterRing`, `Recents` and
`Proposal` hold no reference to any view, so the test binary links them without
pulling in the UI. Stores take a `UserDefaults` instance in their initialiser so
tests write to a scratch domain instead of the user's real preferences.

## Geometry

All distances in points, measured from the ring's centre. Fixed, not derived
from item count — a ring that resizes as you add apps means muscle memory never
forms.

| Quantity | Value | Reasoning |
|---|---|---|
| `holeRadius` | 72 | See-through centre. Must clear the name pill's corner. |
| `innerRadius` | 100 | Recents sit here; icons occupy 80–120. |
| `innerIconSize` | 40 | Visibly subordinate to the outer ring. |
| `outerRadius` | 175 | Fixed apps; icons occupy 147–203. 27pt clear gap. |
| `outerIconSize` | 56 | The primary targets, so the larger hit area. |
| `discRadius` | 227 | Area the window reserves for the glass and its glow. |
| `ringBoundary` | 133.5 | Midpoint of the 120–147 gap; splits the two rings. |
| `innerBand` | 72–128 | Glass under the inner ring: `innerRadius ± (20 + 8)`. |
| `outerBand` | 139–211 | Glass under the outer ring: `outerRadius ± (28 + 8)`. |

**Two bands, not one disc.** Each ring gets its own glass band, with the desktop
showing through the 72pt hole, through the 11pt gap between the bands, and
outside the outer band. The inner ring therefore reads as its own circle rather
than as small icons floating on one wide disc, and most of what the wheel covers
stays see-through. The bands are cut from a single even-odd path of four nested
circles, so a point is glass only when an odd number of those circles contain
it: hole, band, gap, band, outside.
| `outerSlotCount` | 8 | User's own list of eight apps. |
| `innerSlotCount` | 5 | User's choice. |

**Slot angles.** Slot 0 sits at twelve o'clock and indices advance clockwise:

```
θ(i, n) = π/2 − 2π·i/n
```

Both rings start at the top, so slot 0 of each is vertically aligned. With 8 and
5 slots the rings otherwise never align, which is desirable — it makes the two
rings visually distinguishable at a glance.

**Hit-testing** is two independent decisions: distance picks the ring, angle
picks the slot within it.

```
d = hypot(p.x − c.x, p.y − c.y)

d < holeRadius                          → .center   (dismiss)
holeRadius ≤ d < ringBoundary           → .inner(slotIndex(angle, 5))
ringBoundary ≤ d ≤ outerBandOuter + 10  → .outer(slotIndex(angle, 8))
d > outerBandOuter + 10                 → .outside  (dismiss)
```

```
slotIndex(angle, n):
    turns = (π/2 − angle) / 2π
    turns −= floor(turns)              // wrap into [0, 1)
    return Int((turns · n).rounded()) % n
```

The `% n` after rounding is load-bearing: a point just counter-clockwise of
twelve o'clock rounds up to exactly `n`, which must wrap to 0.

The 11pt gap between the bands stays clickable and belongs to whichever ring it
is nearer — `ringBoundary` runs through the middle of it. A see-through gap is a
visual separation, not a dead zone.

**Small-screen clamp.** If `2·(discRadius + 8)` exceeds the shorter side of the
target screen, every radius and icon size is multiplied by
`(min(screen.width, screen.height) − 16) / (2·discRadius)`. Hit-testing uses the
same scaled values, so the two can never disagree.

**Centre placement.** Opened by hotkey, the ring centres on the mouse; opened by
clicking the menu-bar item, it centres on the screen (the cursor is at the menu
bar, which would clip the ring). Either way the centre is clamped to
`[discRadius + 8, dimension − discRadius − 8]` so the ring is never cut off. A
menu toggle forces screen-centring always.

## The outer ring

Eight slots, positionally fixed, persisted as an 8-element array of paths where
an empty string means an empty slot. Filling slot 5 leaves slots 0–4 untouched.

- Empty slots draw a dashed rounded square with a `+`, which doubles as a
  visible drop target — the app teaches its own affordance.
- The same app cannot occupy two slots. A duplicate add beeps and is refused.
- Dropping onto an occupied slot replaces it.
- Dropping onto the menu-bar item fills the first empty slot. If all eight are
  full, Chakra beeps, opens the ring, and shows *"Ring is full — drop onto a
  slot to replace"* in the centre pill.
- Right-clicking a slot removes it.
- An item whose file has disappeared is **kept, not silently dropped**, and
  drawn at 40% alpha with a dashed border. Clicking it shows *"Missing —
  right-click to remove"*. Losing a slot silently would hide the fact that
  something broke.

## The recents engine

A queue of application paths, most-recent-first, capped at 40 entries.

**Live tracking.** `NSWorkspace.didActivateApplicationNotification` fires on
every app activation, including apps launched from Spotlight or the Dock — so
recency is real, not just "things launched from Chakra". Requires no permission.
Only apps with `activationPolicy == .regular` count; background agents and
Chakra itself are excluded. Every change writes through to disk immediately, so
the ring survives a restart with its history intact.

**Seeding.** On first run the queue is empty, so it is seeded from Spotlight:
enumerate `/Applications`, `/Applications/Utilities`, `/System/Applications`,
`/System/Applications/Utilities` and `~/Applications`, read `kMDItemLastUsedDate`
through the synchronous `MDItemCopyAttribute` API, and sort descending. Verified
working on this machine.

**The substitution rule.** The inner ring shows the first five queue entries
that pass every one of these filters:

1. Not already in the outer ring — but instead of leaving a hole, Chakra pulls
   the next eligible entry up. If recents #3 is on the outer ring, #6 takes the
   fifth position. The inner ring always shows five *distinct* apps that are not
   visible elsewhere on the wheel.
2. Still present on disk.
3. On the boot volume (`URLResourceKey.volumeIsRootFileSystemKey`), which keeps
   apps on mounted DMGs out of the ring.
4. Not Chakra itself.

If fewer than five entries qualify, fewer are drawn — at their fixed positions,
not redistributed, so nothing jumps between openings.

## Interaction

| Input | Result |
|---|---|
| Left-click menu-bar item | Toggle ring, centred on screen |
| ⌥Space | Toggle ring, centred on cursor |
| Right-click menu-bar item | Menu: open, add app, style, hotkey, login item, quit |
| Click a slot | Launch (or activate, if already running), then dismiss |
| ⌥-click a slot | Quit that app |
| Right-click an outer slot | Remove it |
| Right-click an inner slot | Promote it into the first empty outer slot |
| Drag an inner slot outward onto an outer slot | Promote into that slot |
| Drop a `.app` (or folder) onto a slot | Set that slot |
| Esc, click outside, or click the hole | Dismiss |
| ← → | Move within the current ring |
| ↑ ↓ / Tab | Switch between rings |
| Return | Launch the highlighted slot |
| 1–8 | Launch that outer slot |

Dismissal is driven by `windowDidResignKey`, deliberately — a global event
monitor would demand Accessibility permission for no gain.

## Appearance

Style D from the approved mockup, with the see-through centre from style B.

An `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, `.active`, `alphaValue`
0.85) masked to the two bands via its `maskImage` property — the supported route,
unlike a layer mask, which can defeat the private blur. Everything the bands do
not cover is fully transparent, so the wheel sits on the desktop rather than over
it. Hovering a slot draws a rounded plate with a `controlAccentColor` stroke and
glow; nothing else is tinted.

The hovered item's name appears in a frosted pill at dead centre: 128×26, corner
radius 13, 13pt semibold, tail-truncated. Its corner sits 65.3pt from centre,
inside the 72pt hole, so the pill can never overlap an inner icon.

A **Colorful highlights** menu toggle (default off) swaps the accent glow for a
halo in each app's own dominant colour, extracted by downscaling the icon to
32×32, discarding transparent, near-black, near-white and grey pixels, bucketing
the rest at 5-bit precision, and boosting the winning bucket's saturation by
1.45×. This exists because the user's original ask was "make it more colorful"
before they picked the minimal style; the toggle honours both.

Running apps get a small dot beneath their icon.

The menu-bar icon is drawn in code as a ring of eight dots — a template image,
so macOS handles light/dark and menu-bar tinting. Drawing it avoids depending on
any particular SF Symbol being present.

## Onboarding

On first launch only, a 460×560 window offers two choices, per the user's
decision:

1. **Set up from my Dock and recent apps** — Chakra proposes eight apps from
   `com.apple.dock persistent-apps` topped up from the Spotlight recency list,
   and shows them for confirmation. Each can be dropped from the list before
   accepting.
2. **Start empty** — eight `+` placeholders to fill by hand.

Either way the window closes having set `didOnboard`, and the ring opens once so
the user sees what they just built.

## Persistence

`UserDefaults`, injected rather than global so tests stay isolated.

| Key | Type | Default |
|---|---|---|
| `outerSlots` | `[String]`, length 8 | eight empty strings |
| `recents` | `[String]`, ≤40 | `[]` |
| `didOnboard` | `Bool` | `false` |
| `hotkeyEnabled` | `Bool` | `true` |
| `colorfulHighlights` | `Bool` | `false` |
| `alwaysCenterOnScreen` | `Bool` | `false` |

Every read is defensive. A value of the wrong type falls back to the default. A
short `outerSlots` array is padded with empty slots and a long one is truncated,
rather than discarded: a partial write should cost the user the missing entries,
not their whole ring.

## Global hotkey

Carbon's `RegisterEventHotKey` with ⌥Space. Chosen over `NSEvent`'s global
monitor because Carbon hot keys need no Accessibility permission. If
registration fails — another app already owns the combination — the menu shows
*"⌥Space unavailable"* instead of failing silently.

## Corner cases

Each of these is a required behaviour, not a nicety.

| Case | Required behaviour |
|---|---|
| No apps configured, no recents | Eight `+` placeholders, pill reads *"Drop apps here"* |
| Fewer than 5 eligible recents | Draw what exists at fixed positions |
| App deleted after being added | Dimmed, dashed, right-click to remove |
| Same app added twice | Beep, refuse |
| Recents entry also on outer ring | Substitute the next eligible entry |
| App on an unmounted/removed volume | Excluded from recents; dimmed if pinned |
| Multiple displays | Ring opens on the display containing the cursor |
| Screen smaller than the ring | Uniform scale-down; hit-testing scales identically |
| Screen configuration changes while open | Dismiss |
| Rapid toggling | Guarded by a visibility flag; no stacked animations |
| Second instance launched | Detect by bundle id and exit, so there is one icon |
| Launch of a missing app fails | Pill shows the error; ring stays open |
| Hotkey already taken | Menu reports it |
| Appearance switches light/dark | Redraw on `viewDidChangeEffectiveAppearance` |
| Corrupt `UserDefaults` values | Repaired to defaults |
| Clicking the exact centre | Dismiss |

## Verification

1. **Unit tests** — a separate binary asserting on `Geometry`, `OuterRing` and
   `Recents`: sector boundaries, twelve-o'clock wraparound, ring-boundary
   distances, the scale clamp, slot occupancy, duplicate refusal, the
   substitution rule with and without enough candidates, defensive decoding.
2. **Compile clean** — no warnings.
3. **Visual verification** — a `--demo` flag opens the ring on launch so it can
   be screenshotted and inspected.
4. **Independent review** — parallel subagents audit the source against this
   spec: one for logic and corner cases, one for AppKit correctness (threading,
   retain cycles, API misuse), one re-deriving the geometry from scratch.

## Build

```
swiftc -O -target arm64-apple-macos14.0 -o Chakra.app/Contents/MacOS/Chakra Sources/*.swift
```

Deployment target 14.0 despite the macOS 26 SDK, so the compiler enforces
availability checks rather than letting newer APIs slip in unguarded. Ad-hoc
signed with `codesign --sign -`.

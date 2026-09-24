# Chakra Orb — Design Spec

**Date:** 2026-09-11
**Status:** Awaiting review
**Supersedes nothing.** Extends `2026-09-10-chakra-design.md`, which stays the
authority on the wheel itself.

## Goal

A small circular button that floats above other applications, always reachable,
which opens the Chakra wheel when clicked. It is dragged wherever the user wants
it, dims when idle, tucks into a screen edge when parked there, and comes back
with the machine at login.

The menu-bar icon stays exactly as it is. The orb is an additional way in, off by
default, switched on in Settings.

## Non-goals

- The orb is not a second launcher. It opens the wheel; the wheel does the work.
- No animation of the orb itself beyond fading and the edge slide. A perpetually
  animating overlay is what puts an app in "Apps Using Significant Energy".
- No badge, count, or status on the orb. It is a button.
- The orb does not wander on its own. It goes where it is put.

## Decisions taken

| Question | Answer |
|---|---|
| Look | Variant A — the user's eight app colours as dots on a dark disc |
| Default size | 56pt, adjustable in Settings |
| Idle behaviour | Fade to 35%, and tuck into a screen edge when parked at one |
| Menu-bar icon | Stays. Orb is optional, off by default |
| Where the wheel opens from the orb | Same as any other trigger: the existing "Where it opens" setting |
| Hidden from screen capture | Yes, by default, with a setting to turn it off |

## 1. The orb window

`NSPanel`, not `NSWindow`, with style mask `[.borderless, .nonactivatingPanel]`.

The non-activating panel is the requirement, not a preference: clicking a plain
borderless `NSWindow` can still activate the application, and Chakra is an
accessory app, so activating it takes the menu bar and the keyboard focus away
from whatever the user is typing in. `.nonactivatingPanel` is documented as
"a panel that does not activate the owning application", and only applies to
`NSPanel`.

```swift
final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

Both overrides are kept even though a borderless panel already reports `false`
for them: adding `.titled` to the style mask flips `canBecomeKey` to `true`, and
the override means that mistake cannot silently steal focus.

| Property | Value | Why |
|---|---|---|
| `level` | `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)` | 23: above the Dock (20) and normal windows, below the menu bar (24). `.statusBar` is 25, so it would draw **over** the menu bar. |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`, plus `.canJoinAllApplications` | Every Space, over full-screen apps, hidden while Mission Control is up so it is never a stray tile. |
| `isOpaque` | `false` | |
| `backgroundColor` | `.clear` | |
| `hasShadow` | `true` | A circular layer's shadow reads as "floating". |
| `hidesOnDeactivate` | `false` | Panels can default to hiding when the app deactivates; the orb must not. |
| `isReleasedWhenClosed` | `false` | It is shown and hidden repeatedly. |
| `animationBehavior` | `.none` | Stops AppKit adding its own fade, which fights ours. |
| `acceptsMouseMovedEvents` | `true` | Needed for the hover fade. |
| `sharingType` | `.none` (default; a setting turns it off) | See section 8. |
| `isMovableByWindowBackground` | `false` | The drag is manual; see section 5. |

Ordered on screen with `orderFrontRegardless()`, never `makeKeyAndOrderFront`.

**Never set `.moveToActiveSpace`.** Combined with `.canJoinAllSpaces` it raises
`NSInternalInconsistencyException` from `-[NSWindow _validateCollectionBehavior:]`
and terminates the app. This was reproduced on macOS 26.5, not inferred. Do not
set `.managed` either: it would put the orb into Mission Control and the window
cycle.

### The content view

- `wantsLayer = true`, drawn with layers rather than `drawRect:` so a drag does
  not re-rasterise the orb on every mouse event.
- `override func acceptsFirstMouse(for:) -> Bool { true }`. Without this the
  first click while Chakra is inactive is consumed as an ordering click and never
  reaches the view, so the orb would need two clicks. This is the single most
  commonly missed piece of a floating-panel implementation.
- `override func hitTest(_:) -> NSView?` returns `nil` outside the circle, so the
  square corners of the panel do not swallow clicks meant for what is behind it.
- One `NSTrackingArea` with `[.mouseEnteredAndExited, .activeAlways, .inVisibleRect]`.
  `.activeAlways` is what makes hover work while Chakra is not the front
  application, and needs no permission.

## 2. Appearance

Variant A, chosen from the mockup. The orb is a miniature of the user's own ring,
which is where the colour comes from — not an invented palette. Eight dots is
also the existing menu-bar glyph, so the two read as the same object.

At a nominal size `S` (default 56pt, range 36–76):

| Element | Measurement |
|---|---|
| Plate | Filled circle, radius `S/2`, `NSColor(white: 0.09, alpha: 0.82)` |
| Dot ring radius | `0.30 · S` |
| Dot radius, slot 0 | `0.075 · S` |
| Dot radius, other slots | `0.055 · S` |
| Centre dot | `0.035 · S`, white at 75% |

Each dot takes the dominant colour of the app in that outer slot, via the
existing `RingItem.dominantColor`, cached exactly as the wheel caches it. An
empty slot draws at `NSColor.tertiaryLabelColor`. Slot 0's dot is larger so the
orb has a visible "up" and reads as a wheel with an orientation.

The orb's dots follow the outer ring's rotation, so a wheel the user has turned
and an orb agree about which app is at the top.

The plate is a solid dark disc rather than an `NSVisualEffectView`. A blur is
expensive to keep composited over every Space all day, and at 56pt across a
frosted plate is indistinguishable from a flat one.

**Rebuilt when, and only when:** the outer ring's contents change
(`OuterRing.didChangeNotification`), the size setting changes, the rotation
settles, or the appearance switches between light and dark. Not on hover — the
fade is an opacity change on the layer, not a redraw.

## 3. Showing and hiding

The orb exists only while `settings.showOrb` is true. Toggling the setting
creates or closes the panel; it is not merely hidden, so an orb that is off costs
nothing.

The orb hides itself while the wheel is open, and returns when the wheel closes.
Two reasons: the wheel is centred on the screen and the orb would sit on top of
it, and the orb's own click would otherwise be a way to open a wheel that is
already open.

## 4. Idle, hover, and the edge tuck

Three states, in one place so they cannot disagree:

| State | Opacity | Position |
|---|---|---|
| Hot — pointer inside, or being dragged | 1.0 | Fully on screen |
| Idle — pointer elsewhere | 0.35 (setting, 0.15–1.0) | Unchanged, unless parked at an edge |
| Tucked — idle and parked within 14pt of a screen edge | 0.35 | Slid `0.62 · S` off that edge |

Opacity changes animate over 180ms. The tuck slides over the same 180ms.

An orb tucked off the edge still has `0.38 · S` on screen, and its hit area is
that sliver, so pointing at the sliver brings it back. The tuck is off when the
orb is not near an edge, so a user who parks it in the middle of the screen never
sees it move.

Tucking is a setting, on by default. With it off the orb dims but never moves.

**Which edge:** whichever of the four the orb's frame is nearest, measured
against the screen's `visibleFrame`. Ties go to the horizontal edge, because
horizontal tucking loses less of the orb's silhouette.

## 5. Dragging

Manual `mouseDown` / `mouseDragged` / `mouseUp` on the content view, moving the
panel with `setFrameOrigin`.

Rejected alternatives, and why:

- `isMovableByWindowBackground` — no clamping, and no way to tell a click from a
  drag.
- `performDrag(with:)` — smoothest, since it runs in the window server, but
  documented to possibly not deliver a mouse-up, which makes both tap detection
  and snap-on-release unreliable. A 56pt window is cheap enough to move by hand.

Implementation notes that matter:

- Record the grab offset from **`NSEvent.mouseLocation`** — global screen
  coordinates — never `event.locationInWindow`. Deriving the origin from
  window-relative coordinates while the window is moving is the classic cause of
  jitter and runaway drift.
- The target screen is the one containing the **pointer**, not the one containing
  the window: `NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }`.
  Clamping to the starting screen would make the orb refuse to cross to a second
  display.
- Clamp the origin so the whole frame sits inside that screen's `visibleFrame`,
  which already excludes the menu bar and the Dock.
- On a notched display, also avoid `safeAreaInsets.top` so the orb cannot hide
  behind the notch.
- Snap the final frame with
  `screen.backingAlignedRect(rect, options: [.alignAllEdgesNearest])` so a
  fractional drag does not leave the orb blurry on a 2× display.
- Movement under 3pt with a quick release is a click, not a drag.

## 6. Remembering where it is

Stored as a fraction of a named screen, not as absolute coordinates, so the orb
survives a reboot, a resolution change, and a monitor being unplugged.

```
orbDisplayID    Int      screen.cgDirectDisplayID
orbDisplayName  String   screen.localizedName, as a fallback match
orbFractionX    Double   0...1 within that screen's visibleFrame
orbFractionY    Double   0...1
```

On restore: match by display ID; failing that by localised name; failing that use
`NSScreen.main`. Then convert the fractions and clamp, so a saved position that no
longer fits lands somewhere reachable rather than off screen.

`NSScreen.cgDirectDisplayID` is the correct spelling on macOS 26 — `displayID`
does not compile. Display IDs are not guaranteed stable across reboots or GPU
switches, which is why the name is stored too.

`setFrameAutosaveName` is not used: it is oriented at titled windows and does no
clamping.

Re-resolved on `NSApplication.didChangeScreenParametersNotification`, debounced
200ms because it fires several times in a burst during a display reconfiguration.

## 7. Clicking the orb

A click opens the wheel exactly as a menu-bar click does — at the position the
existing "Where it opens" setting names. Dragging the wheel already saves its
position and reopens there, which is the behaviour asked for, so **no new
positioning mechanism is added.**

One change to an existing default: "Where it opens" ships as `.center` rather
than `.pointer`. Opening at the pointer made sense when the only triggers were a
keyboard shortcut and a menu-bar icon; with an orb that lives at a screen edge,
the pointer is a poor place to centre a wheel.

The orb accepts dropped applications, like the menu-bar icon, and reports the
result the same way.

Right-clicking the orb shows the same menu as the menu-bar icon.

## 8. Screen capture

`sharingType = .none`, so the orb is not captured in a screen share or recording.
Requires no entitlement.

Two honest limits, both verified:

- It hides pixels, not existence. The panel is still enumerated by
  `CGWindowListCopyWindowInfo`, with `kCGWindowSharingState = 0`. There is no API
  to remove a window from the window list.
- The user's own screenshots are affected too: ⌘⇧4 will not contain the orb.

Because of the second point this is a setting — "Hide the orb from screen
recordings", on by default — so a user who wants the orb in a screenshot can turn
it off without hunting through code.

## 9. Launching with the machine

Already built: `SMAppService.mainApp` behind the "Open Chakra at login"
checkbox. The orb needs nothing new; it appears with the app.

The known limitation stands and is not fixable here: the ad-hoc signature changes
on every rebuild, so macOS treats each build as a different program and drops the
registration back to "requires approval". Settings already says so when that
happens. A Developer ID certificate is the only real fix.

## 10. Keeping the wheel open — corrected, and deferred to a second phase

**Scope note.** Everything above is one coherent piece of work: a new window that
draws, drags, remembers where it is, and opens the existing wheel. This section is
not. It changes how the wheel is dismissed, which is core behaviour the whole app
already depends on, and it carries risk the orb does not. It gets its own
implementation plan, run after the orb is working, so a problem in one cannot
strand the other.

The earlier proposal was to keep the wheel on screen for a few seconds after it
loses focus, so an app could be dragged in from Finder. **That does not work as
described, and the correction matters.**

The wheel's window currently spans the whole `visibleFrame`, because a click
anywhere outside the ring is how it is dismissed, and a window only receives
clicks where it has drawn something. If that window merely lingered after losing
focus, it would block the entire screen for the duration: the user could not click
Finder at all, so the Finder drag it was meant to enable still could not start.

Three parts, in order of value:

**10a. Shrink the wheel's window to the wheel.** Size it to the wheel's footprint
plus the toast area instead of the whole screen. This is an improvement on its own
terms and is worth doing regardless of the orb:

- Clicking elsewhere activates that application, Chakra resigns key, and the wheel
  hides — the same dismissal, with no permission, and the click now reaches the
  app the user aimed at instead of being swallowed.
- Escape and click-outside-the-ring keep working; there is simply less "outside".
- The window stops claiming every pixel of the screen while open.

**10b. A pin.** While pinned, losing focus does not dismiss the wheel. This is what
actually enables the Finder drag: pin, go to Finder, drag an app, drop it on a
slot. Entered by ⌥-clicking the orb or the menu-bar icon; left by clicking that
again, by clicking the wheel's centre, or by Escape. The wheel shows a small pin
mark while pinned so the state is never invisible.

**10c. No timeout.** A wheel that vanishes on its own clock is worse than one with
an explicit pin: the user cannot tell whether it is about to disappear. Dropped
from the design.

## Settings added

Under a new "Orb" section:

- Show the orb on screen — off by default
- Size — 36–76pt, default 56
- Dim when idle — 15–100%, default 35%
- Tuck into the screen edge — on
- Hide the orb from screen recordings — on
- Put the Orb Back in the Middle — for an orb stranded off screen

## Testing

The existing split holds: pure logic in the `swiftc` test binary, AppKit in the
smoke runner.

**Unit-testable, and therefore extracted from the view:**

- `OrbGeometry` — the dot ring's measurements at a given size, and the hit test
  for "is this point inside the circle".
- `OrbPlacement` — clamping a proposed origin into a `visibleFrame`; choosing the
  nearest edge; the tucked offset; converting between an absolute origin and a
  `{display, fraction}` pair, in both directions, including the cases where the
  saved display is gone and where the saved fraction no longer fits.
- `Settings` — the new keys, their defaults, their clamps, and their behaviour on
  wrong-typed values.

**Smoke-testable:**

- The panel is created with the intended level, collection behaviour, and
  `canBecomeKey == false`.
- The collection behaviour does **not** contain `.moveToActiveSpace` alongside
  `.canJoinAllSpaces` — a direct guard against the crash above.
- The orb draws at the smallest, default, and largest sizes, in light and dark, on
  a full ring, a ring with gaps, and an empty ring.
- A synthesised press, drag, and release moves the panel, clamps it, and reports a
  settled position; a press and release without movement reports a click instead.
- Hover and idle produce the intended opacity, and the tuck offset appears only
  when the orb is parked near an edge.
- Toggling the setting creates and closes the panel without leaking it.

**Not testable without a person at the machine**, and to be checked by hand:
behaviour over a full-screen app, appearance in Mission Control, Stage Manager,
and whether a screen recording really omits the orb.

## Risks

| Risk | Standing |
|---|---|
| Orb does not stay visible over a full-screen app | The collection-behaviour combination is the documented one, but this could not be verified without interactive testing. Fallback: re-issue `orderFrontRegardless()` on `NSWorkspace.activeSpaceDidChangeNotification`. |
| Stage Manager's thumbnail strip overlaps an orb parked at the left edge | `visibleFrame` does not exclude the strip. Mitigation: nothing automatic; the user can move the orb. |
| An always-on-top orb keeps the Mac awake | Ruled out. `pmset -g assertions` against a live test panel showed zero assertions owned by the process. Window level and collection behaviour have no power-management surface. |
| The orb becomes an annoyance | This is what the idle fade and the edge tuck are for, and it is off by default. |

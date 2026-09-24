# Architecture

18 source files, 6,346 lines. The organising rule is that **anything testable without a screen is
pulled out into a pure value type**, so a test binary can link it with no window server.

## The layers

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  main.swift — AppDelegate                                           │
  │  Owns everything, wires every callback, handles single-instance.     │
  │  CANNOT be linked into any test binary (top-level code vs @main).    │
  └───────┬──────────────────┬──────────────────┬─────────────────┬─────┘
          │                  │                  │                 │
  ┌───────▼──────┐  ┌────────▼───────┐  ┌───────▼──────┐  ┌───────▼────────┐
  │ StatusItem   │  │ WheelController│  │ OrbController│  │ Settings/      │
  │ menu bar +   │  │ the overlay    │  │ floating     │  │ Onboarding     │
  │ drop target  │  │ window + glass │  │ NSPanel      │  │ windows        │
  └───────┬──────┘  └────────┬───────┘  └───────┬──────┘  └───────┬────────┘
          │                  │                  │                 │
          │         ┌────────▼───────┐  ┌───────▼──────┐          │
          │         │  WheelView     │  │  OrbView     │          │
          │         │  draws + turns │  │  draws +     │          │
          │         │  events into   │  │  hover/drag  │          │
          │         │  intents       │  │              │          │
          │         │  OWNS NO DATA  │  │ OWNS NO DATA │          │
          │         └────────┬───────┘  └───────┬──────┘          │
          │                  │                  │                 │
  ════════▼══════════════════▼══════════════════▼═════════════════▼════════
   PURE / TESTABLE — no window server needed, linked by run-tests.sh
  ═════════════════════════════════════════════════════════════════════════
   RingGeometry     OrbGeometry     OrbPlacement     Shortcut     RingProposal
   (wheel maths)    (dot maths)     (where the orb   (key names   (first-run
                                     may sit)         + deny list) suggestions)

   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │  OuterRing   │  │   Recents    │  │   Settings   │   ← the three stores
   │  4–10 pinned │  │  40-deep     │  │  30 keys,    │     all take an injected
   │  slots       │  │  queue       │  │  all clamped │     UserDefaults
   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
          └─────────────────┴─────────────────┘
                            │
                    UserDefaults(suiteName:)
              real domain: local.chakra  (= the bundle id)
```

## Why the views own no data

`WheelView` and `OrbView` draw and translate events into *intents* — `onLaunch`, `onQuit`,
`onRemoveOuter`, `onDropPaths`, `canRemoveOuter` — which their controllers wire to the stores. The
views never read `UserDefaults` and never mutate a ring.

That is what makes the geometry testable: `RingGeometry.hit(_:center:)` is a pure function, so a test
can assert every point on an 11pt grid across every slot count without a screen existing.

## How a click becomes a launched app

```
  user clicks
      │
      ▼
  WheelView.mouseUp                                    (Sources/WheelView.swift)
      │  press and release must agree on the same slot —
      │  otherwise ordinary trackpad wobble launches the wrong app
      ▼
  geometry.hit(point, center:) ──► HitTarget           (Geometry.swift, PURE)
      │                            .center / .outside / .slot(Ring, Int)
      ▼
  onLaunch?(entry, ring, index)                        a closure, not a reference
      │
      ▼
  WheelController                                      (WheelWindow.swift)
      │  hide the wheel, then
      ▼
  NSWorkspace.openApplication(at:configuration:)
      │
      ▼
  Recents.record(path)                                 (Recents.swift)
      │  moves to front, caps at 40, filters junk on the way IN
      ▼
  UserDefaults
```

## The callback wiring, all of it in one place

Every connection is made in `AppDelegate` (`Sources/main.swift`). Nothing else wires anything, which
is why that file is the one to read when tracing behaviour — and also why it has no automated
coverage.

| Set on | Callback | Goes to |
|---|---|---|
| `StatusItemController` | `onSetUpRing`, `onOpenSettings` | `AppDelegate` presenters |
| `OnboardingController` | `onOpenSettings` | same |
| `WheelController` | `observeVisibility { }` | orb suppression, and menu-bar highlight |
| `SettingsController` | `onSetUpRing`, `onRecentreOrb` | `AppDelegate`, `OrbController.recentre()` |
| `OrbController` | `onDropPaths` | `StatusItemController.add(_:)` — one code path for both drop targets |

**`observeVisibility` is a list, not a single closure.** It used to be one, shared by the menu-bar
highlight; adding the orb as a second listener would have silently broken the first. It is registered
**once at launch**, never inside `installOrb()`, because `installOrb()` runs again on every settings
change and the list is never pruned — registering there leaked one dead observer per toggle.

## The two windows, and why they are different classes

| | Wheel | Orb |
|---|---|---|
| Class | `WheelWindow: NSWindow` | `OrbPanel: NSPanel` |
| Style | `.borderless` | `[.borderless, .nonactivatingPanel]` |
| `canBecomeKey` | **`true`** (overridden) | **`false`** (overridden) |
| Level | `.popUpMenu` | `CGWindowLevelForKey(.mainMenuWindow) - 1` = 23 |
| Why | It must take key focus: keyboard control, and `windowDidResignKey` is the **entire** dismissal mechanism | It must not, or clicking it would steal the menu bar and typing focus from the user's real work |

Only `NSPanel` supports `.nonactivatingPanel`; a borderless `NSWindow` can still activate the app.
That single fact is why the orb is a panel.

**Consequence worth understanding before you call it a bug:** clicking the orb *does* make Chakra
frontmost. The *panel* does not activate the app, but the wheel it opens must, because the wheel needs
key status. Focus returns as soon as the wheel closes. This is the same behaviour the menu-bar icon and
the hotkey have always had.

## The three stores

| Store | Holds | Repairs on load |
|---|---|---|
| `OuterRing` | 10 slots (4–10 visible) of app paths | Wrong type → empty. Short array → **padded**. Long → truncated. Duplicate → becomes an empty slot. **Writes the repair back**, or it would be redone every launch. |
| `Recents` | Up to 40 recently used app paths | Drops Chakra itself, de-duplicates, filters implausible paths, trims. Also writes back. |
| `Settings` | 30 scalar keys | Every read clamps; `isFinite` is checked **before** clamping, because NaN compares false with everything and would slip through `min`/`max`. |

All three take an injected `UserDefaults`, so tests use a throwaway domain and never touch the real
one. See `GOTCHAS.md` for what that costs.

## What is deliberately not tested automatically

| Not covered | Why |
|---|---|
| `Sources/main.swift` | Cannot be linked — top-level code vs `@main`. Checked by hand. |
| `Sources/StatusItem.swift` | The smoke tool never touches it. No `StatusItem`, `statusItem` or `showMenu` appears in `Tools/Smoke.swift`. Menu-bar behaviour rests on manual use. |
| Four modal actions | `chooseSlot:`, `fillFromDock`, `clearOthers`, `loginChanged:` are named in `Smoke.modalActions` and skipped, because `runModal` blocks forever with nobody to click. |
| The physical Finder drag | Everything the orb decides once a drag arrives *is* covered, via a stub `NSDraggingInfo`. The drag leaving Finder is not. |

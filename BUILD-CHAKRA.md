# Building Chakra — the complete record

Chakra is a radial application launcher for macOS: a ring of app icons that opens
where you ask it to, plus a small always-on-top orb that opens the ring when clicked.

This document records how it was built: every file, every design decision and the
options that were rejected, every setting, every test, and — at length — every failure
and how it was resolved.

**Provenance, so you can judge what is trustworthy here.** Everything about the orb and
the three-app floor is drawn from the ledger at
`.superpowers/sdd/2026-09-11-chakra-orb/progress.md` (1,086 lines), written as the work
happened. File lists, line counts, constants, setting keys and test names in this
document were extracted from the files themselves, not recalled. The earlier phase —
the wheel, rotation, hover growth, slot counts — predates that ledger, so its record
comes from the working session rather than a contemporaneous file; exact line numbers
are omitted there rather than guessed.

Where something was **not** verified, this document says so instead of implying it was.

**Sections 12–15 were added later**, from a deliberate research sweep across four dimensions the
earlier sections were thin on: every Apple API used and why, the build pipeline exactly, every
algorithm with its real arithmetic, and the techniques that actually found the defects. That sweep
used four parallel read-only agents, and **their output was checked rather than trusted** — three
claims did not survive:

- one reported that `build.sh` compiles 17 source files; it compiles **18**
- one cited `OrbView.swift:437` for a call that does not exist in a 202-line file
- one reported no deprecated API in use; `NSApp.activate(ignoringOtherApps:)` is the newer API's
  predecessor and is used deliberately five times, so this was settled by compiling that exact call
  at the project's own target and flags — it produces no diagnostic, which is why the build stays
  clean

A fourth error was found in the *source*, not in a report: a comment overstating the hover-growth
margin. It is described at the end of section 15 and was corrected.

---

## 1. Where it lives, and how to run it

Everything is in `~/Claude/projects/Chakra`.

| Command | What it does |
|---|---|
| `./build.sh` | Builds `build/Chakra.app`. Universal (arm64 + x86_64), `-warnings-as-errors`, ad-hoc signed. |
| `./run-tests.sh` | Pure-logic unit tests. No window server needed. Deletes its scratch preference domains afterwards — see 6.16. |
| `./run-smoke.sh` | Builds the real windows and fires the real target-action of every control. Needs a window server and an **unlocked screen**. Also cleans up its scratch domains. |
| `./render-preview.sh` | Renders the wheel to `build/preview-*.png` without opening a window. |
| `./make-icon.sh` | Generates the app icon. |
| `./dump-icons.sh [dir]` | Dumps real app icons as PNGs for the HTML mockups. |
| `python3 make_orb_mockup.py` | Builds `orb-mockup.html`. Regenerates icons if missing. |
| `python3 make_rotation_demo.py` | Builds `rotation-demo.html`. Same. |

Current state, from a run at the time of writing:

```
./run-tests.sh   ✓ 1712 checks passed
./run-smoke.sh   ✓ 422 smoke checks passed
./build.sh       built build/Chakra.app   (zero warnings)
```

**Installed at `/Applications/Chakra.app` and running from there.** Verified: five files, and
`codesign -v` passes.

It first went to `~/Applications`, because `/Applications` needs admin rights that could not be
obtained non-interactively; the user later ran the `sudo cp` themselves. The `~/Applications`
copy was then deleted with their approval, so there is exactly one copy — two would have
mattered, because Chakra refuses to run twice and the older copy kept winning.

Settings survived the move untouched, as expected: they are keyed on the bundle identifier
`local.chakra`, not on a path. Confirmed by measuring the orb from the window server after the
switch — back at x 1351, which is the stored fraction `0.7746559 × 1744` to the pixel, at level
23 and 35% alpha.

**Nothing is committed.** The repository has zero commits and no configured
`user.name`/`user.email`, so no commit was ever made and no name was invented. To start:

```bash
git config user.name "Your Name"
git config user.email "you@example.com"
```

---

## 2. Every file

### Sources — 6,346 lines

| File | Lines | Responsibility |
|---|---|---|
| `Sources/main.swift` | 271 | `AppDelegate`, app lifecycle, global hotkey install, orb install/teardown, single-instance handling. |
| `Sources/Defaults.swift` | 532 | `Settings` (every preference, with clamping and wrong-type fallbacks), `DefaultsKey`, `OpenLocation`, `GlassTint`, `DockPresence`. |
| `Sources/Geometry.swift` | 302 | `RingGeometry` — every measurement of the wheel, hit-testing, rotation, screen-fit scaling. Pure; no AppKit beyond CoreGraphics types. |
| `Sources/Models.swift` | 248 | `RingItem` (an app in a slot), path normalisation, dominant-colour extraction, the recents eligibility filter. |
| `Sources/OuterRing.swift` | 222 | The eight-to-ten fixed slots the user owns. Storage, repair on load, the three-app floor. |
| `Sources/Recents.swift` | 205 | The inner ring's recency queue, Spotlight seeding, junk filtering. |
| `Sources/Proposal.swift` | 71 | `RingProposal` — what to suggest at first run, from the Dock and Spotlight. |
| `Sources/Shortcut.swift` | 139 | Keyboard-shortcut spelling, and the reserved-combination deny list. |
| `Sources/HotKey.swift` | 93 | Carbon `RegisterEventHotKey` wrapper, with a typed failure reason. |
| `Sources/WheelView.swift` | 1071 | Draws the wheel; turns mouse, keyboard, scroll and drag events into intents. Owns no data. |
| `Sources/WheelWindow.swift` | 507 | `WheelController` — the overlay window, glass, layout, show/hide, rotation persistence. |
| `Sources/SettingsWindow.swift` | 1299 | The whole settings window. |
| `Sources/StatusItem.swift` | 323 | The menu-bar item, its menu, and drops onto it. |
| `Sources/Onboarding.swift` | 359 | First-run welcome, proposal confirmation, "nothing to add" screen. |
| `Sources/OrbView.swift` | 202 | Draws the orb; hover, click, drag and file-drop handling. |
| `Sources/OrbController.swift` | 357 | `OrbPanel` and `OrbController` — the floating panel, where it sits, when it is on screen. |
| `Sources/OrbGeometry.swift` | 54 | The orb's measurements and dot placement. Pure. |
| `Sources/OrbPlacement.swift` | 91 | Where the orb may sit: clamping, nearest edge, tuck offset, fraction round-trip. Pure. |

### Tests and tools — 3,821 lines

| File | Lines | Purpose |
|---|---|---|
| `Tests/TestMain.swift` | 94 | The whole test harness. `suite`, `expect`, `expectEqual`, `expectClose`, `expectPoint`. Not XCTest — XCTest needs an Xcode test bundle and this project builds with bare `swiftc`. |
| `Tests/GeometryTests.swift` | 520 | Wheel geometry, rotation, slot counts, crowding. |
| `Tests/OuterRingTests.swift` | 463 | Slots, persistence, repair, the three-app floor. |
| `Tests/SettingsTests.swift` | 350 | Every setting: defaults, clamping, wrong types, NaN. |
| `Tests/ModelTests.swift` | 247 | Path handling, colour extraction, recents eligibility. |
| `Tests/RecentsTests.swift` | 185 | The recency queue. |
| `Tests/ShortcutTests.swift` | 171 | Shortcut spelling and the reserved list. |
| `Tests/OrbPlacementTests.swift` | 133 | Orb placement arithmetic. |
| `Tests/ProposalTests.swift` | 110 | First-run proposal. |
| `Tests/OrbGeometryTests.swift` | 84 | Orb measurements and dots. |
| `Tools/Smoke.swift` | 1,119 | Builds the real windows and fires every control's real action. |
| `Tools/MakeIcon.swift` | 136 | Draws the app icon. |
| `Tools/Preview.swift` | 134 | Renders the wheel to PNG offscreen. |
| `Tools/DumpIcons.swift` | 75 | Dumps app icons for the mockups. |

### Documents, mockups, scripts

| File | Purpose |
|---|---|
| `docs/superpowers/specs/2026-09-10-chakra-design.md` | The wheel's design spec. |
| `docs/superpowers/specs/2026-09-11-chakra-orb-design.md` | The orb's design spec. Approved before any orb code was written. |
| `docs/superpowers/plans/2026-09-10-chakra.md` | The wheel's implementation plan. |
| `docs/superpowers/plans/2026-09-11-chakra-orb.md` | The orb plan, 11 tasks, each carrying real code. |
| `.superpowers/sdd/2026-09-11-chakra-orb/progress.md` | The ledger. Every ruling, failure and resolution, 1,086 lines. |
| `.superpowers/sdd/2026-09-11-chakra-orb/package.sh` | Builds a review diff against a tar snapshot (there are no commits to diff against). |
| `.superpowers/sdd/2026-09-11-chakra-orb/snapshots/` | `pre-task-N.tgz`, one per task, for exact rollback. |
| `.superpowers/sdd/2026-09-11-chakra-orb/review-task-N.diff` | The package each reviewer read. |
| `rotation-demo.html` | Live demo of the rotation options, real icons, real colours. |
| `orb-mockup.html` | Four orb designs on a simulated desktop, draggable, with edge tuck. |
| `mockup_common.py`, `make_orb_mockup.py`, `make_rotation_demo.py` | Build the mockups. |

---

## 3. The decisions, and the options that were rejected

These were put to the user as explicit choices. The rejected options are recorded
because knowing what was *not* chosen explains the shape of the code.

### The orb's appearance — four options, A chosen

The palette was deliberately not invented. Chakra already had a vocabulary — dots on a
ring, two frosted bands, a see-through hole, per-app colour — so the orb's colour comes
from the user's own eight apps. No two people's orbs look alike.

| Option | What it was | Outcome |
|---|---|---|
| **A — App dots** | Eight coloured dots on a dark frosted disc, the menu-bar glyph in colour. | **Chosen.** |
| B — Tiny wheel | A miniature of the ring with real icons, about 64pt. | Rejected. |
| C — Quiet disc | One colour field with the monochrome dot glyph on top. | Rejected. |
| D — Colour sweep | The eight app colours as a conic ring with the hole through it. | Rejected. |

Shown on a simulated desktop with a dull window behind it, on purpose: the real question
was "will this annoy me all day", which cannot be judged against a grey swatch.

### Idle behaviour — three options

| Option | Outcome |
|---|---|
| Always full opacity | Rejected. |
| **Fades when idle, and tucks into the screen edge** | **Chosen.** |
| Fades only | Rejected. |

### Entry points

Keep both the orb and the menu-bar icon; the orb is optional and **off by default**.
Rejected: replacing the menu-bar icon with the orb.

### Rotation — four options shown as a live HTML demo

The demo let the user try each with their real icons before any Swift was written.
Option 4 was chosen: **sweep into place when the wheel opens, and scroll over a ring to
turn it**, with the position remembered.

One thing from the demo was deliberately **not** built: drag-to-spin. Dragging an inner
icon already means "pin this to the outer ring", and two meanings on one gesture would
fight. Spinning is scroll-only.

### Hover feedback

Chosen: the hover plate takes the app's own colour (on by default), and the icon grows
**50%**. The plate grows with it — an earlier version kept the plate at the resting size
and the icon spilled out of it, so the growth did not read as growth.

### The three-app floor — three readings offered

The user asked that the ring never fall below three apps, "even if someone wants to
delete it". Three readings were put to them:

| Reading | Outcome |
|---|---|
| **Refuse to go below 3 apps** | **Chosen.** Clear greys out at three; onboarding's "Start Empty" removed. |
| Seed 3 apps but allow emptying | Rejected. |
| Both | Rejected. |

Consequences accepted deliberately, not overlooked:

- A ring already holding fewer than three *also* refuses removal. Allowing "it is already
  below three, so one fewer does no harm" is exactly how a ring reaches zero. `Choose…`
  replaces a slot and is never refused, so a mistake is always fixable.
- A slot hidden by a low slot count may be emptied, because it is not on the wheel.
- An uninstalled app still occupies its slot and still counts. The floor governs what the
  *user* may delete, not what the world does to them.

### Screen capture

Chosen: hide the orb from screen recordings, as a setting, **on** by default. The cost was
stated up front — your own ⌘⇧4 screenshots will not contain it either.

### Where the wheel opens

The shipped default changed from "at the pointer" to **"at the centre"**. Opening at the
pointer made sense when only a hotkey and the menu bar could open the wheel; with an orb
parked at a screen edge, the pointer is a bad place to centre a wheel.

### Deferred, with the reason stated

**Keeping the wheel open** (so an app could be dragged in from Finder) was requested and
then corrected rather than built. The wheel's window spans the whole `visibleFrame`,
because a click anywhere outside is how it is dismissed. A window that merely lingered
would block the entire screen, so the Finder drag it was meant to enable still could not
start. The real fix is two parts — shrink the wheel's window to the wheel, and add a pin
entered with ⌥-click — and it changes core dismissal behaviour, so it was given its own
phase rather than bundled with a brand-new orb.

---

## 4. Every setting

Thirty keys, all in `DefaultsKey` in `Sources/Defaults.swift`. Every getter clamps and
falls back on a wrong type, so a hand-edited or corrupted preferences file cannot produce
a broken window.

### The wheel

| Key | Range | Default |
|---|---|---|
| `outerSlots` | array of paths, `maxOuterSlots` long | empty |
| `recents` | array of paths, 40 long | empty |
| `didOnboard` | bool | false |
| `outerSlotCount` | 4–10 | 8 |
| `innerSlotCount` | 0–7 (0 switches the inner ring off) | 5 |
| `wheelSize` | 0.7–1.4 | 1.0 |
| `glassOpacity` | 0–1 | 0.85 |
| `glassTint` | none, blue, purple, green, graphite | — |
| `colorfulHighlights` | bool | **true** |
| `openLocation` | pointer, saved, center | **center** |
| `savedCenterX`, `savedCenterY` | fractions | unset |
| `outerRotationSteps`, `innerRotationSteps` | −1000…1000 whole slots | 0 |
| `spinOnOpen` | bool | true |
| `scrollToSpin` | bool | true |
| `showInDock` | bool | false |

Rotation is stored as **whole slots, not an angle**. A slot offset stays meaningful when
the user changes how many slots the ring has; a saved angle would land between two apps.

### The shortcut

| Key | Default |
|---|---|
| `hotkeyEnabled` | true |
| `hotkeyKeyCode` | `kVK_Space` |
| `hotkeyModifiers` | `optionKey` — so ⌥Space |
| `hotkeyLabel` | derived |

### The orb

| Key | Range | Default |
|---|---|---|
| `showOrb` | bool | **false** |
| `orbSize` | 36–76 pt | 56 |
| `orbIdleOpacity` | 0.15–1.0 | 0.35 |
| `orbTucksAtEdge` | bool | true |
| `orbHiddenFromCapture` | bool | true |
| `orbDisplayID` | int | 0 |
| `orbDisplayName` | string | empty |
| `orbFractionX`, `orbFractionY` | 0–1 | unset |

The orb's position is stored as **{display id, display name, fraction x, fraction y}**,
not raw coordinates, and re-clamped on restore. It therefore survives a reboot, a
resolution change and unplugging a monitor. The display is resolved by id first, then by
localised name, then the main screen — display ids are not stable across reboots or GPU
switches, which is why the name is a second chance rather than the only one.

### The floor

`Settings.minOuterApps = 3`. Three rather than one because a ring with one app in it is
not a ring — the gesture the whole app is built on, "flick in a direction", stops meaning
anything.

---

## 5. The geometry, in numbers

All wheel measurements derive from one scale factor, so nothing can drift apart.
From `Sources/Geometry.swift`:

| Constant | Value |
|---|---|
| `baseHoleRadius` | 72 |
| `baseInnerRadius` | 100 |
| `baseOuterRadius` | 175 |
| `baseDiscRadius` | 227 |
| `baseInnerIconSize` | 40 |
| `baseOuterIconSize` | 56 |
| `baseGrace` | 10 |
| `baseMargin` | 8 |
| `basePillHeight` | 26 |
| `basePillTextWidth` | 104 |
| `hoverGrowth` | **1.5** |
| `baseHighlightInset` | 11 |
| `minScale` / `maxScale` | 0.2 / 1.4 |

`hoverGrowth` and `baseHighlightInset` live in the geometry, not in the drawing code, so
the test proving a hovered icon cannot touch its neighbour reads the same numbers the
drawing uses. At ten outer slots the grown plate is 106pt across and the slot centres are
110pt apart. Raising a slot count or the growth factor therefore fails the build rather
than shipping icons that overlap.

The orb, from `Sources/OrbGeometry.swift` and `Sources/OrbPlacement.swift`:

| Constant | Value |
|---|---|
| `OrbGeometry.minSize` / `defaultSize` / `maxSize` | 36 / 56 / 76 |
| `OrbPlacement.edgeThreshold` | 14 pt — closer than this counts as "at an edge" |
| `OrbPlacement.tuckFraction` | 0.62 — how much slides off, leaving a 38% sliver |
| `OrbEdge` | none, left, right, top, bottom |

The orb's window, from `Sources/OrbController.swift`:

| Property | Value | Why |
|---|---|---|
| class | `NSPanel`, style `[.borderless, .nonactivatingPanel]` | A borderless `NSWindow` can still activate the app. Only `NSPanel` supports `.nonactivatingPanel`. |
| `level` | `CGWindowLevelForKey(.mainMenuWindow) - 1` = **23** | Above the Dock (20) and normal windows, below the menu bar (24). `.statusBar` is 25 and would draw *over* the menu bar. |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]` plus `.canJoinAllApplications` | Every Space, over full-screen apps, hidden in Mission Control. |
| `sharingType` | `.none` or `.readOnly` | Hides pixels from recordings. Does not hide the window's existence. |
| `constrainFrameRect` | overridden to return the proposal unchanged | See failure 6.5. |

**A hard constraint written into the plan:** never set `.moveToActiveSpace` together with
`.canJoinAllSpaces`. It raises `NSInternalInconsistencyException` and terminates the app.
A smoke check asserts it is absent.

---

## 6. Every failure, and how it was resolved

This is the substance of the build. Failures are grouped by how they were found, because
that turned out to matter more than what they were.

### 6.1 Sixteen defects found in the plan before any code was written

Each task brief was checked against the real sources before dispatch. This "Scan" stage
was the cheapest place to find anything.

1. Task 1 listed `Sources/OrbGeometry.swift` in the build scripts, but Task 2 creates it.
   `swiftc` would have failed on Task 1's own build check.
2. `exerciseOrb` was declared with one signature in Task 4 and changed in Task 6, churning
   a file across a review boundary. Task 4 now declares the final signature.
3. `run-tests.sh` lists its test files explicitly rather than globbing, so a new test file
   that is not listed leaves its `runXTests()` undefined and the link fails. (Found by the
   Task 1 implementer; the plan was corrected so nobody rediscovered it.)
4. `OrbController.show()` guarded only on `settings.showOrb`, not on `isSuppressed`.
   Reachable, not theoretical: dragging the **wheel** posts `Settings.didChangeNotification`
   while the wheel is open, which becomes `settingsDidChange()` → `show()`. The orb would
   have reappeared on top of the wheel it exists to stay out of.
5. Task 11's smoke check used `scratchDefaults()`, a `Tests/` helper that does not exist in
   `Tools/Smoke.swift`. Worse, the obvious substitute — reusing `Smoke.suiteName` — would
   have corrupted the defaults domain the rest of the pass runs against.
6. **Task 7 observer leak.** `installOrb()` registered a `wheel.observeVisibility` closure,
   and `installOrb()` runs on every settings change. That list is never pruned, so switching
   the orb off and on N times would leave N observers, all but one holding a dead reference,
   called on every wheel open for the rest of the session. Moved to launch.
7. Task 7 called `settingsDidChange()` twice per settings change, repositioning the panel
   and restarting its fade for every setting the user touched.
8. **Task 8 self-refresh.** Task 8 is the first code to post `Settings.didChangeNotification`
   from inside the settings window on a per-tick control. The window observes that same
   notification and answers with `refreshEverything()`, which writes every control's value
   back from storage — including the slider under the user's thumb. Fixed with a
   re-entrancy guard, which also fixed the existing Dock checkbox.
9. Task 10's test declared a `let settings` it never read. Every build script runs
   `-warnings-as-errors`, so that is a build failure, not a nit.
10. **Task 10 asserted the wrong answer.** The hidden-slot case filled slots 0–4 and showed
    four, then asserted removal was refused. Four visible apps minus one leaves three, which
    the floor permits. The test was wrong, not the code.
11. Task 11 referred to a local named `index`; `clearSlot(_:)` takes its slot from
    `sender.tag`.
12. Task 11 invented `ringDidChange()` in three places. The real helper is `applied()`.
13. Task 11's rewrite silently dropped `clearAll`'s existing confirmation alert.
14. That alert's copy said "The eight outer positions will be cleared", which stopped being
    true when the slot count became a user setting between 4 and 10. Now counted from the
    ring and pluralised.
15. Task 8's Files list named only `SettingsWindow.swift` while its Step 2 edits
    `main.swift`, leaving the implementer unsure of its own scope.
16. **Task 9 fixed the wrong file.** It only changed `mockup_common.py`, but
    `make_rotation_demo.py` never imported that module — it carries its own PNG decoder and
    its own `ICON_DIR`. The rotation demo would have stayed just as unbuildable after a
    reboot, which is the entire problem the task existed to solve.

### 6.2 "Forget Saved Position" sent the user to the wrong place

The shipped default for where the wheel opens was changed from "at the pointer" to "at the
centre" (section 3). The "Forget Saved Position" button in Settings still fell back to
`.pointer`, so pressing it sent the user somewhere the default no longer was. Found by the
Task 3 review; a real user path, not a theoretical one.

The implementer reported honestly that it could not reach the fixed line from a unit test,
because the fallback lives in `SettingsWindow` rather than in `Settings`, and pinned the
reachable invariant instead. That is the right answer over a fake test. The line **is**
executed by the smoke runner, which fires every settings control's action including
`forgetPosition`, so it is covered by execution though not by assertion — recorded as such
rather than described as covered.

### 6.3 The dead tuck animation — the worst bug of the run

`panel.animator().setFrameOrigin(_:)` is **silently swallowed** by the animator proxy. A
borderless non-activating `NSPanel` asked to animate from x 200 to x 600 over one second
read x = 200 at every sample and never arrived. The alpha animation in the same group
worked, so the failure was specific to the frame call.

Consequence: pointing away from the orb faded it but **never tucked it** — the feature the
user had specifically chosen was silently dead.

`animator().setFrame(_:display:)` animates correctly: 319 → 473 → 554 → 591 → 600 over the
same second.

**All 340 smoke checks passed while this was broken**, because nothing asserted the orb's
frame actually moved. Four checks were added, then extended to all four edges.

### 6.4 A "cancellation" block that did nothing, with a comment that said it did

Three lines claimed to cancel an in-flight animation:

```swift
NSAnimationContext.current.duration = 0
panel.alphaValue = panel.alphaValue
panel.setFrameOrigin(panel.frame.origin)
```

Running the interruption scenario with and without them gave identical results
(alpha 1.000, x 200.0 both times) — the second animation replaces the first anyway. A
self-assignment cannot cancel an animation, and `NSAnimationContext.current.duration` only
affects animations begun afterwards. Deleted. A comment claiming behaviour the code does
not have is treated as a defect in this project.

### 6.5 The top edge could not tuck at all, and it was not the test's fault

The implementer extended the tuck checks to all four edges, proved they catch the broken
call, then reported honestly that the **top** edge still failed and it could not work out
why — leaving the suite red. The honesty was right; the diagnosis was not.

AppKit constrains a window's frame so it cannot cover the menu bar, via
`NSWindow.constrainFrameRect(_:to:)`. The orb sits at level 23, one *below* the menu bar at
24, so the constraint applied to it and silently refused every move above
`visibleFrame.maxY - size` — which is exactly what a top tuck asks for. **A real user could
not tuck the orb to the top of the screen either.**

Probe, level 23, `visibleFrame` (0, 0, 1800, 1130), asking for y = 1108.72:

```
plain NSPanel:                   setFrameOrigin -> 1074.00 refused
                                 animator setFrame -> 1074.00 refused
overriding constrainFrameRect:   setFrameOrigin -> 1108.00 accepted
                                 animator setFrame -> 1108.00 accepted
```

Resolved by overriding `constrainFrameRect` to return the proposal unchanged. Nothing is
lost: `OrbPlacement.clamp` already decides where the orb may sit, and the tuck deliberately
goes past the edge, so AppKit's constraint was fighting the app's own.

The residual 0.72pt is device-pixel snapping, not slack, which is why the assertions use a
1pt tolerance. The smallest real tuck the code can produce is 36 × 0.62 = **22.32pt**, so
1pt still fails a wrong direction, a wrong axis, or no movement at all.

### 6.6 Three tests that were not tests

1. **A test that could only pass.** Task 8's re-entrancy check asserted that firing the
   slider changed `orbSize` to the slider's midpoint. The size slider's midpoint is
   (36 + 76) / 2 = **56**, which is exactly the shipped default. It passed without the
   action ever running. Now drives the slider to a quarter of its range.
2. **A test that failed for the wrong reason.** The same check found its window with
   `NSApp.windows.first(where: { $0.title == "Chakra Settings" })`. Windows from an earlier
   pass are still in `NSApp.windows` after being ordered out, carrying the same title, so it
   fired a slider belonging to a **different** controller — whose guard flag was then set,
   while the controller being measured correctly refreshed. The implementer reported the
   guard as broken and could not see why. Now identified by being new.
3. **The same window-by-title weakness** in the onboarding check, found by the Task 8
   reviewer and fixed rather than deferred, because the pattern had already caused two false
   results in one session.

### 6.7 A modal alert that hung the entire suite

Task 11 left the smoke suite hanging, and the implementer reported after roughly twenty
minutes that it could not find the cause.

The renamed `clearOthers` was correctly added to the modal skip list. The hang was
**`clearSlot:`**, which is not on that list: the smoke ring holds exactly three apps, so
every Clear is refused, and the new refusal put up an `NSAlert`. `runModal` blocks until
somebody clicks, and nobody was there.

Resolved by making the refusal **non-modal** — a note label — rather than by adding
`clearSlot:` to the skip list, which would have left that refusal untested for good. The
same file already argues for exactly this, one function below, for the slot-count refusal.

### 6.8 User-facing copy that lied

- The hint at the floor read "**is missing — right-click to replace it**". Right-clicking
  *removes*, and at the floor that removal is refused, so the hint told the user to do
  something that cannot work. Both sites now read "**replace it in Settings**", which is
  where replacing actually happens.
- A first attempt to fix it used a replace-all whose search string included its leading
  whitespace. The keyboard path is indented four spaces less than the click path, so only
  one of the two matched. The tool truthfully reported "all occurrences replaced" — of the
  string it was given. Caught by the reviewer.
- The doc comment above the rewritten refusal still said "An alert rather than a label",
  contradicting both the code and the new comment inside it.

### 6.9 `sharingType` — the conclusion was right, the reason was false

"Hide the orb from screen recordings" sets `sharingType`, which was found not to apply to a
panel that already exists. The code rebuilds the panel. The comment claimed sharingType
"cannot be changed afterwards", which is untrue. Probed with fresh windows per case:

```
.readOnly -> asked .none      -> got .none      ACCEPTED
.none     -> asked .readOnly  -> got .none      REFUSED
.readOnly -> asked .readWrite -> got .none      REFUSED
.none     -> asked .readWrite -> got .none      REFUSED
never ordered in: .none -> asked .readOnly -> got .none
```

macOS lets a window become **more** private at any time but never less. `.none` is a
one-way door, even before the window is ordered in. So the rebuild is required only for the
un-hide direction; it is done unconditionally for simplicity, and the comment now says so.

### 6.10 The right-click menu would have appeared at the menu bar

`NSMenu.popUpContextMenu(_:with:for:)` positions relative to the view it is passed. Handing
an orb event to the status item's own view would have popped the menu up at the menu bar.
The callback became `((NSEvent, NSView) -> Void)` and `showMenu(with:relativeTo:)` uses
`view ?? dropView`, so the status-item path is unchanged.

### 6.11 A 0.35-second dead spot on the orb

`toggle(atCursor:)` blocks any open within 0.35s of a focus-driven hide. Its own comment
explains why: "the click that took focus away may be the one on the menu-bar icon" — one
physical click both dismissing and reopening.

That cannot apply to the orb, which is ordered off screen while the wheel is open (verified
with the window server — its level-23 window disappears). The dismissing click was always
an earlier click elsewhere, so the guard could only do harm: close the wheel by clicking
the desktop, click the orb immediately, and nothing happened. Fixed with an explicit
`ignoringRecentHide` parameter, defaulted false, passed true only from the orb.

The hotkey shares the same latent annoyance. Left alone **deliberately** — it is
pre-existing, far less likely, and outside the task. The cost is a rare swallowed ⌥Space.

### 6.12 `deinit` touching AppKit off the main thread

`deinit` called `panel?.orderOut(nil)`. AppKit is main-thread-only and `deinit` runs on
whichever thread drops the last reference. Latent rather than live — the only owners are the
app delegate and the smoke tool, both on main — but fixed properly: dispatch to main only
when not already there. An unconditional async hop from a main-thread deinit would leave the
panel on screen for an extra turn of the run loop, which is visible.

### 6.13 The wheel's earlier phase

These predate the ledger. Line numbers are omitted rather than guessed.

- **⌘Q could become the global ring shortcut.** There was no deny list, and
  `RegisterEventHotKey` accepts it, so nothing stopped Chakra from breaking Quit in every
  app on the Mac. Now denied, along with ⇧⌘Q (log out), ⌃⌘Q (lock), ⌘Tab, ⌘Space, ⌥⌘Esc,
  and plain ⌘ with any single character key, which is where app menus live.
- **The shortcut recorder ate every key in the app.** A local monitor sees every key press
  delivered anywhere in the process. Arm the recorder, open the ring, press Esc, and the
  ring would not close. Now scoped to its own window, and disarmed when focus leaves.
- **The login-item checkbox refused to stay ticked, forever.** macOS reports "registered,
  awaiting approval" as `requiresApproval`, and only `.enabled` was treated as on. Every
  further click repeated the same successful registration.
- The login-item failure alert appended "This usually means Chakra is not in your
  Applications folder" to *every* error, which was wrong about half the time.
- The Dock-icon toggle existed in two places that could disagree.
- A minimised settings window was unreachable forever: `makeKeyAndOrderFront` is ignored for
  a miniaturised window, and with no Dock icon there was no other way back.
- A click that began on the desktop and slid twenty points inward launched an app; one that
  began on an icon and slid into the hole closed the wheel. Ordinary trackpad wobble. Press
  and release must now agree.
- A digit key launched a missing app, skipping the check both clicking and Return performed.
- A live toast drawn outside the wheel's footprint left stale pixels when the wheel moved.
- The glass mask was rebuilt on every mouse-move while dragging — four ovals into a
  454-point bitmap, for nothing.
- **The recents queue had recorded junk in the real preferences file:** a bare command-line
  executable with no bundle, and an App Translocation path that dies when the app quits.
  Anything that activates looks like an application to the workspace notification. Now
  filtered, and the stored queue repairs itself on load.
- **The preview tool lied.** The "small" preview was byte-identical to the full-size one,
  because it was rendered from a "small screen" that in fact fitted the wheel at full size.
- **`assign` silently discarded an app.** It cleared whichever other slot held the app, so
  dragging an app onto an occupied slot in Settings lost whatever was displaced. Found while
  reading the code for the floor work; fixed by swapping instead of clearing, which also
  means the floor never has to refuse a move.

### 6.14 Two false alarms, withdrawn rather than left standing

1. **"The wheel is stuck open."** Opening the ring through the app's distributed
   notification left the wheel on screen, and activating another app did not dismiss it. It
   was being written up as a real dismissal bug when `NSWorkspace` reported the frontmost
   application as `loginwindow` — the screen was **locked**. No app can take focus while
   locked, so activation was refused and `windowDidResignKey` could never fire. Fully
   explained by the lock. Withdrawn.
2. **"The tuck test is flaky."** Three consecutive runs failed identically. Two mistakes in
   reading them: `tail -4` truncated the list, so eight failures (four edges × two
   appearances) looked like four and "both appearances" looked like "DarkAqua only"; and the
   runs happened while the screen was locked, which refuses window repositioning. With the
   screen unlocked, 396 checks pass.

That confound cost real time twice, so the tuck checks now nudge the orb 7pt and read the
position back first. If the window server refused the move they fail **once** with "the
window server refused to move the orb … This is what a locked screen or an inactive session
looks like; unlock the screen and run again", instead of producing eight failures that look
exactly like a broken animation.

### 6.15 A defect in this document's own tooling

`Tools/DumpIcons.swift` would not compile: "'main' attribute cannot be used in a module that
contains top-level code". A single-file `swiftc` compile treats the only file as a script,
which allows top-level code and clashes with `@main`. The other tools escape this by being
compiled alongside the app's sources. Fixed with `-parse-as-library`, which the compiler
itself suggested. Found by running it, not by reading it.

### 6.16 The tests littered the user's preferences folder

Found after the build was otherwise finished, by listing `~/Library/Preferences` while
checking an unrelated claim. The suites had left **52 plist files** there —
`local.chakra.tests.outer.1` through `.25`, twelve `recents`, eleven `settings`, three
`smoke`, and one `local.chakra.audit` left by a probe two days earlier. They held real
data, not empty husks.

The design was right and the discipline was half-applied. Every suite deliberately takes its
own throwaway defaults domain so it can never touch the user's real ring, and
`scratchDefaults()` cleared that domain **on the way in**. Nothing ever cleared it on the way
out.

Fixing it took three attempts, and the first two are worth recording because each looked
sufficient:

1. **Clear the domain when the run ends.** `Tests/TestMain.swift` gained a registry of every
   scratch domain and removes them all before `main()` exits, on the failing path as well as
   the passing one. This worked, but only on the *data*: each file shrank from ~70 bytes to
   42 and `plutil` showed `{}`. The **files stayed**, because merely asking
   `UserDefaults(suiteName:)` for a domain is what creates the file. Nothing inside the
   process can prevent that.
2. **`rm` the files from the shell script, after the binary exits.** This worked for
   `run-smoke.sh` and appeared to work for `run-tests.sh` — and then all 48 test plists came
   back during the next run. `cfprefsd` caches preference domains and rewrites the file from
   that cache, so deleting only the file is undone by the next process that touches
   preferences.
3. **`defaults delete` the domain, then `rm` the file.** `defaults delete` goes through
   `cfprefsd` and makes it forget the domain, so the removal sticks. Both scripts now loop
   over their own plists and do exactly that.

Verified rather than assumed, since step 2 had already produced a false pass:

- Ran both suites in both orders — tests-then-smoke and smoke-then-tests. Afterwards
  `~/Library/Preferences` holds exactly one Chakra file, `local.chakra.plist`, the user's own.
- Broke one assertion on purpose, ran `./run-tests.sh`, and confirmed **exit code 1** — the
  cleanup is wrapped in `set +e` to survive a failing run, and that must not swallow the
  failure — and confirmed the cleanup still ran on that failing path.
- The `.tests.` and `.smoke` infixes in both globs are what keep them off
  `local.chakra.plist`. Stated in a comment at each site.

The 52 existing files were deleted the same way, with the user's explicit approval, after
showing them the exact delete list and the one file being kept.

**Not fixed, and it is a real limitation.** The files still exist *while* a run is in
progress, and a run killed part-way leaves them behind. Removing that too would mean the
suites no longer using `UserDefaults` at all — an in-memory store behind a protocol — which is
a real refactor across all three test files and the three types they exercise. Out of
proportion to 2 KB of empty files.

### 6.17 The final review, which had never been scheduled

Three entries in the ledger said "flag to the final review" — `progress.md:160`, `:174` and
`:187`. The plan contained no such task. Those notes therefore pointed at a stage that was never
going to happen, which is a planning defect, not an implementation one. Run afterwards at the
user's request.

**It is a self-review, and that is a real weakness.** Every per-task review in this project was
done by an independent reviewer that had not written the code. This one was not, so it carries
none of that independence. Stated rather than glossed.

**Flagged item 1 — `orbDisplayID` clamped on read but not on write. Real, fixed.** The getter
clamped to `0...Int32.max`; the setter wrote whatever it was handed. The assertion was written
first and failed in exactly the shape that proves the defect: the *read-back* checks passed
(the getter tidied the value on the way out) while the *stored-value* checks failed with
`got -5` and `got 2147484647`. So nonsense really did reach the plist, and anything reading that
file without going through `Settings` — `defaults read`, a support dump, a future migration —
would have seen it. `Self.sane` was deliberately not reused: it exists to replace NaN, which an
`Int` cannot hold.

**Flagged items 2 and 3 — the same gap, stated twice. Real, fixed.** "Forget Saved Position"
had been fixed once already (6.2), but only *execution* covered it: the smoke pass fires every
settings control's action, so the line ran, and nothing asserted on its effect. A future edit
putting `.pointer` back would have kept the suite green. `exerciseForgetPositionFallback` now
asserts it. Proved by putting the original bug back and reading the failure:
`forgetting the position falls back to the shipped default, got pointer`. The assertion compares
against a freshly constructed `Settings` rather than a literal `.center`, so a deliberate future
change of the shipped default carries the check with it instead of breaking it.

**The sweep was aimed at the four defect classes that actually bit in this project**, rather
than at a generic checklist:

| Class | Result |
|---|---|
| Test windows found by title — bit **twice** (6.6, and again in onboarding) | Clean. All five window lookups in `Tools/Smoke.swift` now identify the window by being *new*, via a `windowNumber` diff. |
| `animator().setFrameOrigin`, silently swallowed (6.3) | No occurrences remain. The orb uses `setFrame(_:display:)`, proven by probe to animate; the wheel animates `alphaValue` only, which does. |
| `runModal` on a path the smoke runner fires — hung the suite (6.7) | Six call sites, all accounted for: four sit in actions named on the `modalActions` skip list, one is inside `LoginItem.setEnabled` and reachable only through `loginChanged:`, one is a comment. `presentFloorNote` no longer uses an alert at all. |
| Comments stating a false reason (6.4, 6.9) | The `sharingType` comment was already corrected. No `TODO`, `FIXME`, `HACK` or `XXX` anywhere in `Sources` or `Tools`. |

Also confirmed the one documented crash risk is *asserted* and not merely commented:
`Tools/Smoke.swift:499` checks the orb never sets `.moveToActiveSpace`, which together with
`.canJoinAllSpaces` raises `NSInternalInconsistencyException` and terminates the app.

**One coverage gap found and deliberately not fixed:** `Sources/StatusItem.swift` is untouched by
the smoke tool. See the note under section 8.

---

## 7. The process, and why each stage exists

Stages, named after what actually happens:

**Project, once:** `Brainstorm → Spec → Plan → Tasks → Integrate → Ship`
**Per task, eleven times:** `Scan → Snap → Build → Check → Review → Fix? → Close`

- **Scan** — pre-flight the task brief against the real code before dispatching anyone.
  Sixteen defects were caught here, for nothing.
- **Snap** — `tar` the source tree so a bad task can be rolled back exactly. Used instead of
  a git branch because the repository has no commits to branch from.
- **Build** — the implementer writes the failing test first, then the code.
- **Check** — re-run the tests, the smoke pass and the build, and read the diff. Never repeat
  a number that was not personally observed.
- **Review** — an independent agent audits it and does not trust the implementer.
- **Fix?** — entered only when a review finds a real defect; loops back to Check.
- **Close** — record the outcome and any ruling in the ledger.

**Check and Review are deliberately separate.** Check is one's own verification; Review is
somebody else's. Collapsing them is how a plausible-but-wrong implementation gets through —
and three of the failures above (6.3, 6.5, 6.7) were found in Check, after the implementer
had reported success.

### Mutation testing became routine

An implementer's claim that "these checks would have failed" was not accepted. Every new
behavioural check was verified by breaking the thing it covers and watching it fail:

| Mutation | Result |
|---|---|
| `animator().setFrame` → `setFrameOrigin` | 8 tuck checks fail, "got 0.0, expected 34.72" |
| remove `constrainFrameRect` override | exactly the 2 top-edge checks fail |
| `ignoringRecentHide \|\| !recentlyHidden` → `!recentlyHidden` | 2 checks fail |
| disable the sharingType rebuild | 2 checks fail, "got 0" |
| `canRemove` floor → `return true` | 6 checks fail |
| `assign` swap → clearing | 3 checks fail |
| `canSetVisibleCount` → always allow | 3 checks fail |
| drop `&& outer.canRemove(at: index)` | "every Clear button is greyed out at the floor, 3 of 10 were not" |

A test whose failure has not been witnessed is not yet a test.

### Rulings recorded with their cost

Eighteen judgement calls are recorded in the ledger, each with what it would cost if wrong.
The significant ones:

- **No git worktree; work in place.** Nothing to branch from, and no git identity. Cost: no
  branch to throw away — mitigated by tar snapshots.
- **Tasks stay sequential, never parallel.** Every task runs the same three scripts into the
  same `build/` directory, so two agents at once would read each other's half-written files
  and report failures that are not real. Cost: wall-clock time. Cheaper than a false failure.
- **All commit steps skipped, and no name invented.**
- **`replaceAll` is exempt from the floor.** It means "the ring is now exactly this list", not
  a deletion. Enforcing the floor inside it would stop onboarding proposing a one-app ring on
  a machine that only has one app.
- **Opting out of AppKit's frame constraining is correct here.** `OrbPlacement.clamp` already
  decides where the orb may sit.
- **Tolerance of 1pt, not more.** The 0.72pt discrepancy is real pixel snapping, not slack.
- **At the floor, Clear is greyed *and* the refusal is implemented behind it.** A greyed
  button is the honest signal, but a key equivalent or an accessibility client can still
  invoke a disabled button's action.

---

## 8. Every test

**78 unit suites, 1,712 checks.** The harness is 94 lines in `Tests/TestMain.swift` — not
XCTest, which needs an Xcode test bundle this project does not have.

| Group | Suites |
|---|---|
| `geometry/` | clamp-centre, constants, everything-scales, fraction-round-trip, hit-bands, hit-edges, hit-round-trip, invariants-at-every-scale, placement, rotation, scale, sector-index, slot-counts-drive-hit-testing, slot-crowding, user-size |
| `model/` | boot-volume, cache-validity, dominant-colour, item-cache, missing, normalize-path, plausible-app-path, resolution |
| `orb-geometry/` | dots, hit-test, sizes |
| `orb-placement/` | clamp, fraction-round-trip, nearest-edge, tuck |
| `outer/` | assign, assign-swaps-rather-than-clears, bounds, change-notification, defensive-decoding, duplicates, empty, first-empty, fixed-positions, full, persistence, repair-write-back, replace-all, replace-and-remove, slot-count-cannot-hide-below-the-floor, three-app-floor, visible-count |
| `proposal/` | dock-parsing, exclusions, free-slots, order |
| `recents/` | capacity, persistence, record, rejections, repairs-stored-junk, scarcity, seeding, spotlight, substitution |
| `settings/` | clamping, defaults, enum-cases, forget-position-fallback, geometry-agreement, not-a-number, opens-at-centre-by-default, orb, rotation, round-trip, saved-position, wrong-types |
| `shortcut/` | acceptable, carbon-modifiers, glyphs, key-label, labels, reserved |

**422 smoke checks**, in seven passes, each run twice — once in Aqua and once in Dark Aqua:

| Pass | What it drives |
|---|---|
| `exerciseSettingsWindow` | Builds the real window, walks the hierarchy, fires every control's real target-action, checks layout and that displayed values match the settings behind them. |
| `exerciseWheel` | Every slot count (4–10 outer × 0–7 inner) at both ends of the size slider, hit-testing every point on an 11pt grid, the opening sweep, a synthesised scroll, the snap, keyboard navigation. |
| `exerciseOrb` | Every orb size against a full, gappy and empty ring; the panel's window-server configuration; the lifecycle; the tuck and untuck at all four edges with real frame assertions. |
| `exerciseAppFloor` | A ring at exactly the floor: every Clear button greyed, and a fourth app re-enabling one. |
| `exerciseForgetPositionFallback` | "Forget Saved Position" clears the position, falls back to the *shipped* default rather than a hardcoded case, and disables its own button. Added by the final review; see 6.17. |
| `exerciseOrbDrop` | A file dropped onto the orb: one app accepted and handed on unchanged, two apps both handed on, and an empty drag refused without the handler being called. Driven through a stub `NSDraggingInfo`, since `OrbView` reads only `draggingPasteboard` from it. Added by the final review. |
| `exerciseOnboarding` | The welcome, confirmation and nothing-to-add screens. |

Actions that open a modal are deliberately not fired — `runModal` would block forever with
nobody to click — and are named in `modalActions` so what is left uncovered stays visible:
`chooseSlot:`, `fillFromDock`, `clearOthers`, `loginChanged:`.

**`Sources/StatusItem.swift` is not exercised at all.** There is no occurrence of `StatusItem`,
`statusItem` or `showMenu` in `Tools/Smoke.swift`, so the menu-bar item, the drop target on it
and `addAppFromPanel` rest entirely on manual use. Found by the final review and recorded rather
than fixed, so it is not mistaken for covered.

`Sources/main.swift` **cannot** be linked into the smoke binary: top-level code cannot
coexist with the smoke tool's `@main`. The app-delegate wiring is therefore inherently
untested by the automated suites, which is why it was checked by hand.

---

## 9. What was verified against the running app, and what was not

Verified with real synthetic mouse events, driven in a single process so nothing could change
between observations:

| Check | Result |
|---|---|
| Orb position, level, idle alpha | x 1720 = `visible.maxX − size − 24`; y = `visible.height × 0.66`; level 23; alpha 0.350 |
| Click the orb → wheel opens | pass |
| Orb hides while the wheel is up | pass — its level-23 window disappears |
| Wheel dismisses on losing focus | pass |
| Orb returns afterwards | pass |
| Focus returns to the previous app | pass — back to Terminal |
| Orb does not drift over a cycle | pass — same pixel |
| Drag to the left edge | pass — x = 0 |
| Tuck when the pointer leaves | pass — x = **−35**, which is 62% of 56pt |
| Untuck when pointed at | pass — back to x = 0 |
| Right-click menu at the orb | pass — at (29, 494), not the menu bar |
| Saved position restores exactly | pass — fraction 0.7746559 × 1744 = 1351.0, and 0.9832402 × 1074 = 1056.0, both to the pixel |
| Universal binary | pass — x86_64 + arm64 |

**Clicking the orb does make Chakra frontmost.** This was nearly written up as a defect and
is not one. The wheel must be key to take arrow keys and Return, and `windowDidResignKey` is
its only dismissal mechanism, so opening it necessarily activates the app — exactly as the
menu-bar icon and the hotkey always have. The spec's requirement is that the *panel* not
activate Chakra, which it does not. Focus returns as soon as the wheel closes.

**Not verified, and not claimed:**

**Since resolved by the user:** the orb over a real full-screen app **works** — reported by the
user after trying it, which is the only way this one could be settled. The automated attempt was
inconclusive and was recorded as such rather than claimed: it sent ⌃⌘F to Terminal, Terminal never
entered full screen, so the orb staying visible proved nothing. That check had deliberately been
written to verify the transition first so it could not produce a false pass. The panel's
`.fullScreenAuxiliary` flag is also asserted in the smoke pass, which was indirect evidence
pointing the same way.
**Since resolved by the user:** Mission Control behaves correctly — reported by the user after
looking. This one is inherently visual, so their eye is the evidence and there was never an
automated route to it; what the smoke pass asserts is the cause, not the effect (`.transient` is
set and `.managed` is absent).
- **The physical act** of dragging an app out of Finder and onto the orb. Everything the orb
  decides once a drag arrives *is* now covered by `exerciseOrbDrop` — acceptance, one file, two
  files, and refusal of an empty drag — and those checks were proved to fail by removing the line
  that hands the paths on. What is not covered is the drag itself leaving Finder.
- Whether `sharingType = .none` actually blocks a real screen capture.
  `CGWindowListCreateImage` returned an image for both values, but this machine appears to
  lack screen-recording permission — an earlier `screencapture` failed with "could not create
  image from display" — so that test proves nothing either way. The property-level asymmetry
  in 6.9 is solid; the capture-blocking claim rests on Apple's documentation alone.

---

## 10. Known limitations

- **The ad-hoc signature has no stable identity.** Its designated requirement is a bare
  cdhash, which changes on every recompile, so macOS treats each build as a different program
  and an "Open at login" registration made by an earlier build drops back to needing approval.
  Settings says so when it happens. A real Developer ID is the only fix, and this project
  deliberately has none. **Moving the app into `/Applications` did not change this**, and it was
  worth checking rather than assuming: `codesign -dvv` on the installed copy still reports
  `flags=0x2(adhoc)`, `TeamIdentifier=not set`, and a designated requirement that is a bare pair
  of cdhashes. What the move *did* remove is the separate `notFound` case, where macOS could not
  find a registerable copy at all because the app was running from a build folder.

  Chakra's own login-item state cannot be read from outside Chakra: `SMAppService.mainApp` refers
  to the *calling* bundle, so a probe asking it reports on the probe. One was written during this
  work, returned `notFound`, and that result was discarded rather than reported as Chakra's. The
  checkbox in Chakra's own Settings window is the only honest place to read it.
- **An unconfigured orb is faint on a near-black wallpaper.** With no apps assigned, the dots
  are `tertiaryLabelColor` on a plate of `NSColor(white: 0.09, alpha: 0.82)` with no rim.
  Verified by rendering against backdrops at brightness 0.04, 0.12, 0.45 and 0.97. Only
  reachable before onboarding fills the ring. The spec pinned that plate colour, so it was
  not changed silently; a hairline rim would fix it.
- **`run-smoke.sh` needs an unlocked screen.** It now says so when that is the problem.
- **The suites' scratch preference files exist while a run is in progress.** Both scripts
  delete them afterwards, but a run killed part-way leaves them in `~/Library/Preferences`.
  Removing that too means not using `UserDefaults` in the tests at all; see 6.16 for why that
  was judged out of proportion.
- **Hiding the orb from recordings also hides it from your own screenshots.** Stated when the
  setting was chosen.
- **The wheel cannot be pinned open yet**, so an app cannot be dragged onto a slot from
  Finder. Deferred with a written reason; see section 3.
- **A future edit making `minOuterApps` larger than `minOuterSlots`** would not crash but
  would be impossible to satisfy: a ring at the minimum slot count could never hold enough
  apps to allow a removal. Not a defect today (3 < 4).

---

## 11. Tally

| | |
|---|---|
| Source | 6,346 lines across 18 files |
| Tests and tools | 3,821 lines across 14 files |
| Unit checks | 1,712 in 78 suites |
| Smoke checks | 422, each pass run in both appearances |
| Warnings | zero, enforced by `-warnings-as-errors` in all six build scripts |
| Plan defects caught before any code | 16 |
| Real defects found in code | 13 in the wheel phase (6.13) and 12 in the orb phase (6.2–6.5, 6.7–6.12, 6.15–6.17) — every one enumerated, none aggregated |
| Tests found broken or vacuous | 3 |
| False alarms withdrawn | 2, both caused by a locked screen |
| Rulings recorded with their cost | 17, each prefixed `Ruling:` in the ledger |
| Tasks | 11, each with an independent review; Task 6 took three fix rounds. A final whole-project review was added afterwards — self-review, not independent; see 6.17 |
| Commits | 0 — no git identity is configured, and none was invented |

Four of the defects in section 6 originated in the plan's own author rather than in an
implementer, including the copy that told the user to right-click to replace when
right-clicking cannot replace. They are marked as such where they appear.

**Why the orb-phase count here is 11 and not the 9 reported while the work was running.**
The live tally counted only defects in shipped behaviour. This one also counts two items
that were fixed but do not fit that description: a comment that stated a false reason while
reaching the right conclusion (6.9), and a `deinit` touching AppKit off the main thread
(6.12), which was taken as cheap insurance and never demonstrated to fire. Neither reading
is wrong; they count different things. The narrower one is the honest number for "bugs a
user would have hit", and it is 9.

---

## 12. Every Apple API used, and why that one

Added after the build was finished, from a sweep of all 18 source files and 4 tools. Chakra
uses **no third-party code at all**, so this is the complete dependency list. Where the codebase
states its own reason in a comment, that reason is quoted — the *why* is the part worth keeping.

### The three APIs chosen to avoid a permission prompt

Chakra's founding constraint is that it never triggers an Accessibility, Screen Recording or
Automation prompt. Three separate API choices exist only to honour that, and each is the less
obvious option:

| Instead of | Chakra uses | Because |
|---|---|---|
| `NSEvent.addGlobalMonitorForEvents` | **Carbon `RegisterEventHotKey`** (`Sources/HotKey.swift:47`) | *"the latter would make macOS demand Accessibility permission. RegisterEventHotKey needs none, which is the entire reason for reaching back to a 20-year-old API."* |
| A global event monitor for the shortcut recorder | **`NSEvent.addLocalMonitorForEvents`** (`Sources/SettingsWindow.swift:127`) | *"a global monitor is what would make macOS demand Accessibility access, and Chakra never asks for a permission."* While the recorder is armed the app is frontmost anyway, so local is sufficient. |
| AppleScript "tell application to quit" | **`pkill -x Chakra`** (`build.sh:85`) | *"telling another app to quit through AppleScript would trigger an Automation permission prompt, and Chakra's whole premise is that it never asks for one."* |

Dismissal follows the same rule: it uses `windowDidResignKey`, never a global monitor. That single
decision is why the wheel *must* become key, which in turn is why clicking the orb legitimately
activates Chakra — a chain traced in section 9.

### Carbon.HIToolbox — the hot key

`RegisterEventHotKey`, `UnregisterEventHotKey`, `GetEventDispatcherTarget`,
`InstallEventHandler`, `GetEventParameter`, with `EventHotKeyRef`, `EventHotKeyID`,
`EventHandlerRef`, `EventTypeSpec`, `EventHandlerUPP`, `OSType`, `OSStatus`,
`kEventClassKeyboard`, `kEventHotKeyPressed`, `kEventParamDirectObject`, `typeEventHotKeyID`,
`eventNotHandledErr`, `noErr` — all in `Sources/HotKey.swift`.

The registration is tagged with a four-character signature, `0x43484B52` — ASCII `CHKR`
(`HotKey.swift:11`) — and the C callback checks it (`:79`) so Chakra only handles its own hot keys.

Carbon also supplies the modifier bits (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`) and every
virtual key code (`kVK_Space`, `kVK_Escape`, `kVK_F1`…`kVK_F12`, the arrows, and the letters used
by the reserved-shortcut deny list) in `Sources/Shortcut.swift`.

### CoreServices / Metadata — seeding the recents ring

`MDItemCreate` and `MDItemCopyAttribute(kMDItemLastUsedDate)` (`Sources/Recents.swift:173-174`).
Chosen over `NSMetadataQuery` deliberately: *"seeding happens once during onboarding and a
blocking read of a few hundred files is simpler than an asynchronous query."*

### ServiceManagement — the login item

`SMAppService.mainApp.status` / `.register()` / `.unregister()`, and
`SMAppService.openSystemSettingsLoginItems()` (`Sources/SettingsWindow.swift:26-80`).

The interesting part is the four-case status enum. *"`requiresApproval` is the case that matters:
`register()` returns without throwing, but the item does not run until the user approves it in
System Settings."* Treating only `.enabled` as "on" is what made the checkbox refuse to stay
ticked forever — failure 6.13.

### CoreGraphics

- `CGWindowLevelForKey(.mainMenuWindow)` (`Sources/OrbController.swift:98`) — the orb's level is
  computed from this **minus one**, rather than hardcoded: *"above the Dock (20) and normal
  windows, but not drawing over the user's menu bar the way `.statusBar` (25) would."*
- `CGWindowListCopyWindowInfo` — not used by the app, but the primary verification tool; see
  section 15.
- `CGEvent.scrollWheelEvent2Source` (`Tools/Smoke.swift`) — synthesises scroll for the smoke pass.
- `CGContext.clear(_:)` — *"freshly allocated bitmap memory is not zeroed."*

### AppKit — the window configuration that makes an orb possible

This is the densest part of the project, and the values matter more than the symbols.

| Property | Value | Reason from the code |
|---|---|---|
| Orb class | `NSPanel`, `[.borderless, .nonactivatingPanel]` (`OrbController.swift:85`) | Only `NSPanel` supports `.nonactivatingPanel`; a borderless `NSWindow` can still activate the app. |
| Orb level | `CGWindowLevelForKey(.mainMenuWindow) - 1` = 23 (`:98`) | One below the menu bar, above the Dock. |
| Orb collection behaviour | `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]` + `.canJoinAllApplications` (`:103-106`) | Every Space, over full-screen apps, and not a Mission Control tile. |
| **Never** set | `.moveToActiveSpace` (`:102`) | *"with `.canJoinAllSpaces` it raises an exception and kills the app."* Asserted absent in the smoke pass. |
| Wheel level | `.popUpMenu` (`WheelWindow.swift:357`) | — |
| Wheel collection behaviour | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` (`:358`) | — |
| Sharing type | `.none` or `.readOnly` (`OrbController.swift:110`) | Hides pixels from recordings. *"It does not hide the window's existence: it is still enumerated by `CGWindowListCopyWindowInfo`."* |

**`.canJoinAllApplications` is the only availability-guarded API in the project** —
`if #available(macOS 13, *)` at `OrbController.swift:105`. The deployment target is macOS 14, so
that guard is strictly unnecessary; it was suspected of causing a warning (which would fail the
build) and proved harmless by compiling both forms. See 6.x and section 15.

### The four deliberate subclass overrides

Each exists to defeat a specific default behaviour, and each is documented:

1. **`OrbPanel.constrainFrameRect(_:to:)` returns the proposal unchanged**
   (`OrbController.swift:21-23`). *"AppKit constrains a window so it cannot cover the menu bar.
   The orb sits one level below the menu bar, so that constraint applies to it and silently
   refuses any move above `visibleFrame.maxY - size`."* This is failure 6.5 — without the
   override, the top-edge tuck did nothing at all, for real users as well as tests.
2. **`OrbPanel.canBecomeKey` / `canBecomeMain` return `false`** (`:11-12`). Redundant today, kept
   on purpose: *"adding `.titled` to the style mask flips `canBecomeKey` to true, and this makes
   that mistake impossible to make silently."*
3. **`WheelWindow.canBecomeKey` returns `true`** (`WheelWindow.swift:6`) — the opposite, and for
   the reason above: *"otherwise the wheel could not receive key events and could not tell when to
   dismiss."*
4. **`OrbView.hitTest(_:)` returns nil outside the disc** (`OrbView.swift:34`). *"The panel is
   square; the orb is not. Returning nil outside the disc stops the corners swallowing clicks
   aimed at whatever is behind it."*

And one property override worth naming: **`acceptsFirstMouse(for:)` returns true** on both the orb
and the wheel (`OrbView.swift:30`, `WheelView.swift:159`) — *"the orb/ring can be clicked while
another application is frontmost. Without this the first click is spent ordering the window and
never reaches the view."*

### Drawing and hover

- `NSVisualEffectView` with `.hudWindow` material and `.behindWindow` blending, masked by a
  generated `maskImage` (`WheelWindow.swift:365-367`, `:233`) — *"masking an `NSVisualEffectView`
  through `maskImage` is the supported route for a non-rectangular blur; a CALayer mask can defeat
  it."*
- The **orb deliberately does not use it** (`OrbView.swift:133`): *"A flat disc rather than an
  `NSVisualEffectView`: a blur composited over every Space all day is real work, and at this size
  it is indistinguishable from a solid plate."*
- Masks are drawn through `NSImage(size:flipped:drawingHandler:)` rather than `lockFocus`, because
  *"`lockFocus` bakes a single bitmap at whatever scale the current screen has — the mask would
  stay soft after the wheel moved to a display with a different backing scale."*
- `NSTrackingArea` with **`.activeAlways`** (`OrbView.swift:79`) — *"what makes hover work while
  Chakra is not the front application, and it needs no permission."*

### Multi-display handling

`NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` for the display id,
`localizedName` as the fallback match, and **`backingAlignedRect(_:options:)`**
(`OrbController.swift:275`) — *"aligned to device pixels, or a fractional drag leaves the orb
blurry on a 2× display."* `NSApplication.didChangeScreenParametersNotification` is observed and
debounced, because it *"fires several times in a burst while a display is being reconfigured."*

### Single instance, without a lock file

`NSRunningApplication.runningApplications(withBundleIdentifier:)` compared against `.current`
(`main.swift:257-259`), and if another copy is found, the launch **hands off** through
`DistributedNotificationCenter` and exits: *"A second copy would install a second menu-bar item and
fight over the shortcut. Hand the request to the copy that is already running instead."*
`applicationShouldHandleReopen` covers the other route: *"Launching an already-running app sends
this instead of starting a second process, so it is the natural place to open the ring."*

### One API used against its own documentation

`NSApp.activate(ignoringOtherApps: true)` is used in five places rather than the cooperative
`activate()` added in macOS 14 (`WheelWindow.swift:134` and four others):

> *"The cooperative `activate()` added in macOS 14 is documented as refusable, and from an
> accessory app it is in fact refused. When that happens the window never becomes key: no
> keyboard, and no `windowDidResignKey`, which is the whole dismissal mechanism."*

**Verified rather than assumed:** a probe compiled that exact call at
`-target arm64-apple-macos14.0 -warnings-as-errors` and it produced no diagnostic, so it does not
warn at this deployment target — which is why every build stays clean despite the newer API
existing. Had it warned, the build would have failed.

### Concurrency, and the one lock

Everything UI is on the main queue. `Recents` does its Spotlight seeding on
`DispatchQueue.global(qos: .utility)`. `RingItem.make` guards its cache with an `NSLock`
(`Models.swift:84`) — *"a lock rather than a main-thread assumption: `make` is called from multiple
places, and one of them moving to a background queue must not silently corrupt a dictionary."*

`DispatchWorkItem` is used rather than a bare `asyncAfter` wherever a pending action must be
cancellable — the hover fade, the toast, the slot-count note — so a rapid sequence of events cannot
leave a stack of timers each undoing the next.

---

## 13. The build pipeline, exactly

No Xcode, no SwiftPM, no `Package.swift`, no dependencies. Six shell scripts driving `swiftc`
directly, and a `.app` bundle assembled by hand with `mkdir` and `cp`. The counts below were taken
from the scripts, not recalled.

### What each script compiles

| Script | `Sources/` | `Tests/` | `Tools/` | Arch | `-O` |
|---|---|---|---|---|---|
| `build.sh` | **18** (all) | — | — | arm64 **+ x86_64** | yes |
| `run-tests.sh` | **10** (pure logic only) | 10 | — | arm64 | no |
| `run-smoke.sh` | **17** (all but `main.swift`) | — | `Smoke.swift` | arm64 | no |
| `render-preview.sh` | **17** (all but `main.swift`) | — | `Preview.swift` | arm64 | no |
| `make-icon.sh` | — | — | `MakeIcon.swift` | arm64 | no |
| `dump-icons.sh` | — | — | `DumpIcons.swift` | arm64 | yes |

**All six use `-warnings-as-errors`.** From `build.sh`: *"the ring is small enough that no warning
is acceptable."*

### The one constraint that shapes every script

`Sources/main.swift` contains **top-level code**, and Swift forbids top-level code in a module that
also has an `@main` type. Every test and tool binary declares its own `@main`. So:

- `run-tests.sh`, `run-smoke.sh` and `render-preview.sh` all **exclude `main.swift`**. This is why
  the app-delegate wiring is inherently untestable by the automated suites, stated in section 8.
- `make-icon.sh` and `dump-icons.sh` compile a **single file** that carries `@main`, and a lone file
  is treated by `swiftc` as a script — which reintroduces the same clash. Both therefore pass
  **`-parse-as-library`**. The other tools escape this by being compiled alongside the app's
  sources. Discovering this was failure 6.15: the compiler named the fix and the error was only
  found by *running* the script.

`run-tests.sh` compiles only the 10 pure-logic sources — no `WheelView`, `OrbView`,
`OrbController`, `WheelWindow`, `StatusItem`, `SettingsWindow` or `Onboarding` — which is what lets
it run with no window server at all. `run-smoke.sh` exists precisely because those seven need one.

### Why the app is a universal binary and the tools are not

`build.sh` compiles twice and joins the slices with `lipo -create`:

> *"Universal, because Info.plist advertises macOS 14 as the minimum and macOS 14 still runs on
> Intel Macs. An arm64-only binary in a bundle making that promise simply fails to launch there."*

The tools and tests are arm64-only — they never leave this machine. Verified on the installed copy:
`Format=app bundle with Mach-O universal (x86_64 arm64)`.

### Why the deployment target is older than the SDK

Every invocation targets `macos14.0` while building against a much newer SDK, deliberately:

> *"The deployment target is deliberately older than the SDK so that using an API newer than
> macOS 14 is a compile error rather than a crash on someone's Mac."*

Combined with `-warnings-as-errors`, that turns the whole availability question into a build
failure rather than a field report. It is also why the project has exactly one `#available` guard.

### The bundle, assembled by hand

```
build/Chakra.app/
└── Contents/
    ├── Info.plist          copied verbatim from the repository root
    ├── PkgInfo             the 8 bytes `APPL????`
    ├── MacOS/Chakra        the universal binary from lipo
    └── Resources/Chakra.icns
```

Five files. Order matters: the bundle is emptied with `rm -rf`, the two directories are created,
the binary is compiled and joined, `Info.plist` and `PkgInfo` are written, the icon is generated if
stale and copied, and **only then** is the bundle signed — a signature must be applied after its
contents are final.

### Info.plist, key by key

| Key | Value | What it does |
|---|---|---|
| `CFBundleIdentifier` | `local.chakra` | **Also the preferences domain.** This is why settings survived the move from `~/Applications` to `/Applications` untouched. |
| `LSUIElement` | `true` | No Dock icon, no menu-bar presence of its own. The Dock toggle in Settings flips the *activation policy* at runtime rather than this key. |
| `LSMinimumSystemVersion` | `14.0` | The promise that forces the universal binary. |
| `NSHighResolutionCapable` | `true` | Retina. |
| `NSSupportsAutomaticTermination` | `false` | An always-available launcher must not be terminated for being idle. |
| `NSSupportsSuddenTermination` | `false` | Settings are written on change, but this avoids losing a write in flight. |
| `CFBundleIconFile` | `Chakra` | Names `Resources/Chakra.icns`. |
| `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable` | `Chakra` | — |
| `CFBundlePackageType` | `APPL` | — |
| `CFBundleShortVersionString`, `CFBundleVersion` | `1.0`, `1` | — |
| `CFBundleInfoDictionaryVersion` | `6.0` | — |

`CFBundleIconName` is **deliberately absent**: *"it names an entry in a compiled asset catalogue,
which a bundle built by `swiftc` alone does not have."*

### The icon is code, not a checked-in binary

`Tools/MakeIcon.swift` draws it, `make-icon.sh` compiles and runs that to produce a `.iconset`
directory, and `iconutil --convert icns` turns it into `Resources/Chakra.icns`. *"The icon is
generated rather than committed as a binary: `iconutil` ships with macOS, so the whole thing stays
inside the repository as readable code."*

`build.sh` regenerates it only when it is missing or when `Tools/MakeIcon.swift` is newer than the
`.icns` — *"so a build never quietly ships a stale icon, and never pays for `iconutil` when nothing
has changed."*

### The signature, and the limitation it creates

```
codesign --force --sign - build/Chakra.app
```

`--sign -` is an **ad-hoc** signature: no identity, no team. Enough for macOS to load the bundle and
for `SMAppService` to accept it at all. Not enough for a stable identity — see section 10, where the
consequence is measured on the installed copy rather than assumed.

### Both test scripts clean up after themselves

`run-tests.sh` and `run-smoke.sh` end by deleting their scratch preference domains with
`defaults delete` followed by `rm`, wrapped so the exit status of the test run survives. The reason
`rm` alone is not enough, and the three attempts it took to get right, are failure 6.16.

---

## 14. Every algorithm, with its real arithmetic

Extracted from the source and then re-checked constant by constant, because the point of writing
these down is that the numbers are right. Where a comment states the reasoning, it is quoted.

### Dominant colour from an app icon

The wheel tints each app's hover plate with a colour taken from its own icon
(`Sources/Models.swift:196-247`). A naive average produces grey for almost everything, so the
algorithm throws pixels away aggressively first:

1. Render the icon into a **32 × 32** bitmap.
2. Discard `alpha < 180` — transparent edges.
3. Discard `max(r,g,b) < 42` (near-black) and `min(r,g,b) > 226` (near-white).
4. Discard `max(r,g,b) - min(r,g,b) < 26` — greys.
5. Bucket what remains into **512 buckets** by taking the top 3 bits of each channel:
   `key = (r >> 5) << 10 | (g >> 5) << 5 | (b >> 5)`.
6. Take the most populous bucket.
7. Push it away from grey: `channel' = min(255, mean + (channel - mean) × 1.45)`.
8. If nothing survived, fall back to `NSColor(srgbRed: 0.58, green: 0.58, blue: 0.66)`.

> *"Transparent, near-black, near-white and grey pixels are discarded first, otherwise almost every
> icon resolves to the same washed-out grey."*

A test pins the outcome rather than the algorithm: a saturated icon must yield saturation > 0.15.

### Radial hit-testing

Four distance bands from the wheel's centre, unscaled (`Sources/Geometry.swift:235-248`):

| Distance | Result |
|---|---|
| `< 72` | the hole — `.center` |
| `72 … 133.5` | `.inner` ring |
| `133.5 … 221` | `.outer` ring |
| `> 221` | `.outside` |

`133.5` is not a constant; it is derived so the boundary always sits midway between where the two
rings' icons end: `((100 + 40/2) + (175 − 56/2)) / 2`. The outer limit is `211 + 10`, the glass edge
plus a 10pt grace margin so a click a hair outside still counts.

Sector index, given an angle:

```
turns = (π/2 − angle − rotation) / 2π
turns −= floor(turns)          // into [0, 1)
index  = round(turns × count) mod count
```

Slot 0 sits at `π/2` — twelve o'clock — and indices run clockwise. The `mod` is doing real work:
> *"A point a hair counter-clockwise of twelve o'clock rounds up to `count`, so the modulo is what
> wraps it back to slot 0."*

### Hover growth, and the tightest number in the project

A hovered icon grows by **1.5×** and is drawn on a plate inset **11pt** per side. The test
`geometry/slot-crowding` proves that a grown plate cannot touch its neighbour, at the maximum slot
count for both rings — and it computes both sides from the constants rather than hardcoding them, so
raising a slot count fails the build instead of shipping overlapping icons.

| Ring | Slots | Plate | Centre spacing | Margin |
|---|---|---|---|---|
| Outer | 10 | 56 × 1.5 + 22 = **106.0** | **108.2** | **2.2pt** |
| Inner | 7 | 40 × 1.5 + 22 = **82.0** | 86.8 | 4.8pt |

The spacing figures are **straight-line** distances between adjacent centres, which is what the test
measures with `hypot`. The arc lengths are 110.0 and 89.8. The source comment used to quote the arc,
which overstated the outer ring's headroom by nearly two points out of a total of 2.2; it was
corrected while this section was being written.

### Screen-fit scaling

An unscaled wheel needs `2 × (227 + 8) = 470pt`. On anything smaller it shrinks:
`min((shorter − 16) / 454, 1.4)`, clamped to `0.2 … 1.4`. The drawn scale is
`min(what the user chose, what the screen can hold)`, resolved in one place because *"drawing and
hit-testing can never work from different numbers."*

One subtlety worth preserving, from the comment at `Geometry.swift:155`: both dimensions are checked
rather than just the shorter one, because *"`min` hands NaN through in one argument order and
swallows it in the other."*

### Rotation stored as whole slots, never as an angle

`Sources/Defaults.swift:325-353`. The stored value is an integer number of slots; radians are
derived as `2π × wrapped / count` where `wrapped = ((steps % count) + count) % count`.

> *"A ring only ever comes to rest on a slot, and a slot offset stays meaningful when the user
> changes how many slots the ring has, where a saved angle would land between two apps."*

And the modulo has a specific job: *"a ring that was turned five notches and then cut down to four
slots comes back to a sensible place rather than spinning on past its own start."*

### The opening sweep, and why it feels mechanical

Ease-out cubic, `1 − (1 − t)³`, over **0.25s** (`Sources/WheelView.swift:191`). The two rings start
from different offsets — outer **0.55 rad**, inner **0.8 rad** — so *"the outer ring leads and the
inner follows a little further behind, which reads as one object settling rather than two rings
moving independently."*

> *"Ease-out cubic: fast at first, settling gently, which is what makes a mechanical-feeling wheel
> rather than a linear slide."*

### Scroll-to-spin, with two different conversion factors

`delta × 0.012` for a trackpad, `delta × 0.15` for a mouse wheel, selected on
`event.hasPreciseScrollingDeltas` (`WheelView.swift:227`):

> *"A trackpad sends many small precise deltas; a wheel sends a few large line-based ones. One
> factor for both would make the trackpad useless or the wheel unusable."*

### The glass donut, from four circles

`Sources/WheelWindow.swift:308-345`. The glass is two separate bands with see-through desktop in the
hole, between them, and outside them. Rather than compose shapes, four concentric circles are nested
under the **even-odd winding rule**:

> *"Nesting four circles under the even-odd rule fills a point only when an odd number of circles
> contain it, which alternates band, gap, band as the radius grows."*

At scale 1 the radii are **72, 128, 139, 211** — an 11pt gap between the two bands. Each is derived
from a ring's radius, icon size and padding, so the glass can never drift out of step with the icons
it is behind.

### Orb placement and the fraction round-trip

`Sources/OrbPlacement.swift`. Edge threshold **14pt**, tuck fraction **0.62**.

Clamping subtracts the orb's own size from the upper bound, *"so it is the orb that stays on screen
rather than merely its origin."* At a corner, two edges are within threshold at once and the
horizontal one wins: *"sliding sideways hides less of a circle's silhouette than sliding up or down
does."*

Position is persisted as a **fraction of available travel**, not as a point:

```
travel  = visible.width − size
fraction = (origin.x − visible.minX) / travel
```

> *"The denominator is the *travel* available to the origin, not the screen width, which is what
> makes the round trip exact at both extremes."*

That exactness was confirmed against the running app: stored `0.7746559` × `(1800 − 56)` = `1351.0`,
matching the observed window frame to the pixel, on a display whose `visibleFrame` differs from its
`frame`.

A test pins the *purpose* rather than the formula: the sliver left showing after a tuck must be at
least **18pt** wide, because a sliver you cannot point at is not a sliver.

### Orb dots

`Sources/OrbGeometry.swift`. Every measurement is a fraction of the orb's size, so all of it scales
with the one slider: ring radius `0.30`, lead dot `0.075`, other dots `0.055`, centre dot `0.035`.

Slot 0's dot is drawn larger *"so the orb has a visible orientation rather than reading as a
symmetrical smear of colour"*, and the outer ring's rotation is applied to the dots *"so a turned
wheel and the orb agree about which app is at the top."*

The size bounds have a stated reason: *"below 36pt the dots stop being distinguishable; above 76pt
the orb stops reading as a button and starts reading as a window."*

### Recents: the substitution rule the user asked for

`Sources/Recents.swift`. Capacity **40**, move-to-front on activation, Chakra never records itself.

The inner ring shows the most recent apps that are **not** already pinned to the outer ring — and
crucially it does not leave a hole where one is skipped:

> *"An app that is already pinned to the outer ring does not leave a gap here — the next eligible app
> is pulled up in its place, so the inner ring always shows `limit` *distinct* apps that appear
> nowhere else on the wheel. This was the user's explicit rule."*

Filtering happens on the way **in**, not only on the way out, *"because the queue holds forty entries
and anything junk in it pushes a real app out of history"* — which is exactly the defect in 6.13
where a bare command-line executable and an App Translocation path had been recorded.

Spotlight seeding reads `kMDItemLastUsedDate` across five directories (`/Applications`,
`/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`,
`~/Applications`) and appends **underneath** existing history, so it is safe to run more than once.

### Repair-on-load, and why it writes back

`Sources/OuterRing.swift:45-67` turns whatever is on disk into exactly `capacity` valid, distinct
slots: wrong type becomes empty, a short array is **padded** rather than discarded, an over-long one
is truncated, and a duplicate *"becomes an empty slot rather than a second copy of one app, which
`set` would then refuse to move."*

> *"A short array is padded rather than discarded so a partial write — or a ring saved by a build
> with a smaller capacity — costs the user only the missing entries, not their whole ring."*

The repair is **saved back**, which is the non-obvious part: *"a repair that stays in memory would be
redone on every launch, and the broken value would outlive the app."*

`Settings` does the same for scalars through three helpers. Two carry reasoning worth keeping:

- `bool(forKey:default:)` exists because *"`bool(forKey:)` cannot distinguish 'false' from 'never
  set', which matters for a setting whose default is on."*
- `sane(_:min:max:fallback:)` checks `isFinite` **before** clamping, because *"NaN compares false
  with everything, so `min` and `max` would hand it straight through and a NaN would end up in the
  stored plist."*
- `choice(forKey:default:allowed:)` validates against the allowed set so *"an unknown or wrong-typed
  value cannot put the app into a state it has no code for."*

---

## 15. How the defects were actually found

Section 6 lists *what* broke. This is *how* it was caught, because the methods transferred between
tasks far better than the individual fixes did.

### Sixty throwaway probe programs

A count taken from disk, not from memory: **60 single-purpose Swift programs** survive in `/tmp` from
this project — 42 loose files and 18 inside eleven probe directories. Split by author:

| Written by | Count | Naming |
|---|---|---|
| The implementer/author | 30 | `orbshot`, `orbback`, `animprobe`, `topedge`, `sharing`, `orbwin`, `clicktest`, `cycle`, `dragtest`, `geoprobe1-3`, `probe1-2`, `measure`, … |
| Independent reviewers | 30 | `test_hittest`, `test_panel_level`, `test_resign_timing`, `test_dragging_protocol`, `floor_breaker`, `comprehensive_floor_test`, `test_reentrancy_deep`, … |

That reviewers wrote **as many probes as the author did** is the part worth noting. They were not
reading diffs and forming opinions; they were compiling programs to check claims. `floor_breaker.swift`
is the clearest example — written to attack the three-app floor rather than to review it.

The oldest six, dated 2026-09-10 20:29–21:06, are the only surviving evidence of the wheel phase's
verification, and `geoprobe.swift` opens by declaring its own method:

> *"Independent re-derivation of Chakra's geometry, from the spec only. Nothing here calls into
> RingGeometry to decide what is expected; expected values are computed from first principles (or
> hardcoded from paper) and then compared with the code."*

### What probes were for: settling questions documentation could not

Every significant orb defect was found by a probe, not by reading. Three cases where the probe
**contradicted** a confident assumption:

| Assumption | Probe result |
|---|---|
| `panel.animator().setFrameOrigin(_:)` animates a window | It is **silently swallowed**. Asked to move x from 200 to 600 over one second, the window read x = 200 at every sample. `setFrame(_:display:)` sampled 319 → 473 → 554 → 591 → 600. The whole edge-tuck feature was dead (6.3). |
| `sharingType` cannot be changed after a window is built | It can be **tightened but never loosened**. Four transitions on fresh windows: `.readOnly → .none` accepted; `.none → .readOnly`, `.readOnly → .readWrite` and `.none → .readWrite` all refused. The conclusion in the code was right and its stated reason was false (6.9). |
| The top-edge tuck failure is a test-environment quirk | A **real product defect**. A plain `NSPanel` asked for y = 1108.72 landed at 1074.00; one overriding `constrainFrameRect` reached 1108.00. AppKit refuses to let a window below menu-bar level cover the menu bar, so no user could tuck the orb to the top either (6.5). |

### Mutation testing, applied to every new check

The rule that emerged: **a check whose failure you have never witnessed is not yet a check.** So each
new assertion was proved by deliberately breaking the code it covers and reading the failure text.
Eight mutations were run:

| Broken on purpose | Failure text |
|---|---|
| Tuck restored to `setFrameOrigin` | `the orb tucked by the expected distance: got 0.0, expected 34.72` |
| `constrainFrameRect` override removed | `got (900.0, 1074.0), expected (900.0, 1108.72)` |
| Orb's bypass of the 0.35s guard removed | `toggle with bypass opens despite recent hide` |
| Settings re-entrancy guard removed | refresh count 1 → 6 |
| `sharingType` panel rebuild disabled | `has sharingType .readOnly, got 0` |
| Three-app floor: `canRemove`, the `assign` swap, and `canSetVisibleCount`, separately | 6, 3 and 3 failures respectively, e.g. `C took A's old slot rather than vanishing: got , want /c.app` |
| Floor dropped from Clear-button enabling | `every Clear button is greyed out at the floor, 3 of 10 were not` |
| `onDropPaths?(dropped)` removed | `the dropped path is handed on unchanged, got []` |
| Fallback reverted to `.pointer` | `falls back to the shipped default, got pointer` |

Mutation testing also caught the worst test defect in the project (6.6): a check that **could only
ever pass**. It asserted that firing the size slider set `orbSize` to the slider's midpoint — and the
midpoint of 36…76 is 56, which is the shipped default. It passed without the action ever running.

### Verifying the running app from outside it

The orb is deliberately hidden from screen capture, so a screenshot can never show it. Verification
used the window server instead:

- **`CGWindowListCopyWindowInfo`** for position, size, level and alpha. This measured the orb at
  x 1720 = `visible.maxX − size − 24`, level 23, alpha 0.350 — each matching its formula.
- **Watching the window list across a state change** proved the suppress-while-the-wheel-is-open
  wiring end to end: the level-23 window disappeared and a level-101 one appeared.
- **Synthetic mouse events**, twelve steps as a hand would move, drove a real drag to the left edge
  (x → 0), the tuck when the pointer left (x → −35, which is 62% of 56pt), the untuck on returning to
  the sliver, and a right-click whose menu appeared at (29, 494) — at the orb, not at the menu bar.
- **The whole open/dismiss/return cycle in a single process**, so nothing could change between
  observations. An earlier two-process attempt had observed an already-closed wheel and proved
  nothing.

### Two techniques that produced misleading results

Both are recorded because the failure mode is the point:

1. **A locked screen looks exactly like a broken animation.** Twice, tuck checks failed on all eight
   edge assertions while the screen was locked — the window server refuses to reposition a window
   then. The second time, `tail -4` hid half the output and made eight consistent failures look like
   four flaky ones. Diagnosed by `NSWorkspace.frontmostApplication` reporting `loginwindow`. Fixed by
   adding a guard that nudges the orb 7pt before the edge loop and, if the move is refused, fails
   once with *"the window server refused to move the orb … unlock the screen and run again."*
2. **`SMAppService.mainApp` reports on the calling bundle.** A probe written to read Chakra's
   login-item state returned `notFound` — about the probe, not Chakra. Discarded rather than reported.

A third produced *nothing* rather than something false: `CGWindowListCreateImage` returned an image
for both `sharingType` values, but this machine lacks Screen Recording permission, so the test
established neither direction.

### Checking the checkers

Independent review caught real defects, and its reports were themselves checked. Four cases where a
reported result did not survive:

1. **"Some subtle AppKit timing issue"** — twice, for two different defects (the top-edge tuck and the
   modal hang). Both times the honesty was right and the diagnosis was wrong; both had specific,
   findable causes.
2. **"Failing then passing" evidence that was only compile errors.** `'Settings' has no member
   'minOuterApps'` proves the API did not exist, not that any assertion detects wrong behaviour. Three
   real mutations were run instead.
3. **An overstated claim about test coverage.** A re-reviewer said a new assertion *"will fail if
   someone changes the default without updating the fallback."* Only half true: it pins the default,
   so it catches a change there, but nothing asserted on the fallback line, so reverting *that* would
   have kept the suite green. Recorded as half an invariant rather than accepted — and closed later by
   the final review (6.17).
4. **A precision error in a source comment**, found while writing section 14: adjacent outer slot
   centres are 108.2pt apart in a straight line, not the 110.0pt arc the comment quoted. The
   conclusion held, the margin was 2.2pt rather than nearly 4, and the comment was corrected.

### The machinery, with no commits to lean on

The repository has zero commits, so the usual tools were unavailable and had to be replaced:

- **Review packages** came from `diff -ru` against a tar snapshot rather than `git diff`. The first
  attempt used `diff -ruN` against a snapshot containing only sources, which invented every untracked
  file as an addition and buried the real 7-file change; fixed by comparing only paths the snapshot
  contains.
- **Rollback** was `snapshots/pre-task-N.tgz`, one per task, taken before dispatch.
- **Scoped re-review** used a second snapshot taken *after* the reviewed state and *before* the fix,
  so a re-review diff showed only the fix and nothing else.
- **Tasks ran strictly sequentially**, never in parallel, because all three scripts write into the
  same `build/` directory and compile the same sources: *"two agents at once would read each other's
  half-written files and report failures that are not real."* The cost was wall-clock time, spent
  instead on pre-flight scanning of the next task — which is where 16 defects were caught before any
  code was written.

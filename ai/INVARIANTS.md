# Invariants — what must stay true, and what breaks if it does not

`CLAUDE.md` has pointed at this file since the project started; it did not exist until
2026-09-22. Everything here is derived from the code, or measured. Nothing is aspiration.

Each entry says what the rule is, why it exists, and **how it is enforced** — because a rule
enforced only by a comment is a rule that will be broken by someone who did not read it.

---

## 1. Chakra never triggers a macOS permission prompt

**Absolute.** No Accessibility, no Screen Recording, no Automation, no Files-and-Folders.

Three API choices exist only to honour this, and all three are verifiable in the built
binary rather than only in the source:

| Instead of | Chakra uses | Where |
|---|---|---|
| `NSEvent.addGlobalMonitorForEvents` (Accessibility) | Carbon `RegisterEventHotKey` | `Sources/HotKey.swift:47` |
| a global event monitor for the shortcut recorder | `NSEvent.addLocalMonitorForEvents` | `Sources/SettingsWindow.swift:127` |
| an event tap to see app switches | `NSWorkspace.didActivateApplicationNotification` | `Sources/Recents.swift:183` |

**How it is enforced.** By nothing automated. This is the weakest point in the project: the
rule the author cares most about has no test. A 2026-09-22 audit checked it against the
binary rather than the source and found it clean —

- `nm -u build/Chakra.app/Contents/MacOS/Chakra` lists only `_MDItemCreate`,
  `_MDItemCopyAttribute`, `_kMDItemLastUsedDate`, `_RegisterEventHotKey`,
  `_UnregisterEventHotKey` among gated symbols.
- Linked frameworks are AppKit, Carbon, CoreFoundation, CoreGraphics, CoreServices,
  CryptoKit, Foundation, ServiceManagement. No ScreenCaptureKit, AVFoundation, OSAKit or
  IOKit HID.
- `Info.plist` contains **zero** `NS*UsageDescription` keys.
- `addGlobalMonitorForEvents`, `CGWindowList*`, `AXUIElement*` and AppleScript appear only
  inside comments.

**If you add a framework or a gated symbol, re-run that check.** It is the only evidence
this invariant has.

**Re-run 2026-09-22 after Task 8**, because `Sources/Shelf.swift` changed from
`import Foundation` to `import AppKit` and that file's own header recorded the evidence as
stale until the audit was repeated. All four legs pass against a fresh `./build.sh`:

- `nm -u` reports **zero** TCC-gated symbols, and exactly the five expected gated symbols
  above — `_MDItemCreate`, `_MDItemCopyAttribute`, `_kMDItemLastUsedDate`,
  `_RegisterEventHotKey`, `_UnregisterEventHotKey`. Unchanged.
- `otool -L` gained **`CryptoKit`** and nothing else. It is the shelf's SHA-256 for
  cross-volume copy verification, it is not permission-gated, and the list above has been
  corrected to include it. AppKit was already linked by the wheel, so the Task 8 import added
  no framework of its own.
- Zero `NS*UsageDescription` keys.
- The gated APIs appear in two comments only: `Sources/HotKey.swift:6` and
  `Sources/OrbController.swift:109`.

**`NSRunningApplication.terminate()` works, and needs no entitlement.** Measured 2026-09-22
against a real Cocoa victim app (`NSApp.run()`, `.regular` activation policy, ad-hoc signed):
`terminate()` returned `true`, the app exited in **0.11 s**, `applicationWillTerminate` ran,
and there were **no** `com.apple.TCC` log entries and no dialog. An earlier probe claimed the
opposite, but its victim was a process calling `Thread.sleep()` with no `NSApp.run()` — it
could not answer a quit Apple event at all, so the result said nothing about permissions.

Two consequences:

- **`kill(pid, SIGTERM)` must never be substituted.** Measured, the target dies without
  `applicationWillTerminate` running, so unsaved work is lost with no prompt.
- **Under the App Sandbox it fails silently.** Measured: `terminate()` returns `false`, the
  target survives, `kill(pid, 0)` returns `EPERM`, and there is no dialog and no TCC entry.
  That is why the Mac App Store build flags the feature off.

**One hole that is open and unverified**, recorded so nobody assumes it is closed:

- Nothing stops a user pinning an app that lives in `~/Desktop`, `~/Documents` or
  `~/Downloads`. `isPlausibleAppPath` blocks `/volumes/` and the temp trees, not those.
  On the next launch Chakra stats and renders that app's icon. Whether a bare `stat` alone
  prompts was not established.

**Safe by measurement:** `~/Library/Application Support/` is not TCC-protected and needs no
admin — a write probe succeeded with no prompt, and 62 other apps already use it. That is
why the shelf lives there and not in `~/Documents`.

**A symlink planted at the shelf folder's own path made `ensureExists()` widen permissions
on a directory Chakra does not own.** Measured directly on 2026-09-22: a victim directory
went `0500` → `0755` while the function returned success. The cause is that
`fileExists(atPath:isDirectory:)` follows a symlink and reports the **target's** type, and
`setAttributes(_:ofItemAtPath:)` is `chmod(2)` rather than `lchmod`, so it follows too. No
race is needed — the link can be planted before Chakra's first run, because `local.chakra/`
does not exist yet. `attributesOfItem(atPath:)[.type]` reports the link itself without
following, which is the fix. This is now guarded in `Sources/Shelf.swift`, but **state
plainly that §1's guarantee is true by convention rather than by construction**: nothing
validates the root path, and this hole existed because nobody asked what happens when the
path is not what it appears to be.

## 2. Zero warnings

All six scripts pass `-warnings-as-errors`. A warning is a build failure, and an unused
`let` in a test will fail the build.

**How it is enforced.** By the compiler, in every script. This one is airtight.

Practical consequence: every discarded result needs an explicit `_ =`. A `try?
fm.removeItem` in a cleanup path, or an ignored out-parameter, is a build failure.

## 3. Never add `.moveToActiveSpace` to the orb's collection behaviour

With `.canJoinAllSpaces` it raises `NSInternalInconsistencyException` and kills the app.

**How it is enforced.** A smoke check asserts its absence, and
`Sources/OrbController.swift:102` carries the warning inline.

## 4. One app occupies one place on the ring

`OuterRing.set` refuses a path that already sits in a different slot; `assign` swaps rather
than duplicating; `decode` turns a duplicate into an empty slot; `Recents.inner` excludes
anything already pinned.

**Why:** the whole value of a fixed ring is that a direction always means the same app. Two
copies of one app makes "flick left" ambiguous.

**How it is enforced.** `Tests/OuterRingTests.swift`.

## 5. The outer ring keeps at least three apps

`Settings.minOuterApps = 3`. Enforced on removal and on lowering the visible count, not as
an invariant of stored data — a fresh ring starts empty and onboarding fills it.

**Why three, not one:** a ring with one app in it is not a ring. The gesture the whole app
is built on stops meaning anything.

**How it is enforced.** `OuterRing.canRemove` / `canSetVisibleCount`, plus tests.

## 6. Counts are read from settings, never written into copy

Any user-facing string that mentions how many slots there are must interpolate
`outer.visibleCount` or `geometry.outerSlotCount`. The ring is settable from 4 to 10.

**Why:** telling a user with a six-slot ring that they have eight is a small lie that is
easy to leave behind. Stated at `Sources/Onboarding.swift` and again in `SettingsWindow`.

**How it is enforced.** By nothing. It was broken in **three** places as of 2026-09-22 —
`SettingsWindow` ("Replace all eight slots?"), `Onboarding` ("All eight slots hold an app"),
`WheelView` ("Drop onto one of the eight outer slots") — while a comment 29 lines from one
of them recorded fixing the same bug. All three are now fixed. **A grep for spelled-out
numbers in string literals is worth running before any release.**

## 7. A bounded setting clamps on the way **out** as well as in

Guarding only the getter still lets a nonsense value reach the plist, where `defaults read`,
a support dump or a future migration will find it.

**How it is enforced.** `Tests/SettingsTests.swift` reads the stored plist directly for
`orbDisplayID`, `outerRotationSteps`, `innerRotationSteps` and `hotkeyLabel`. **Note the
trap:** every *other* clamp assertion in that file reads back through the getter, which
clamps independently — so those checks pass whether or not the setter clamps. Three setters
were unguarded until 2026-09-22 for exactly that reason. New bounded settings need a
plist-level assertion, not a getter round trip.

## 8. `RingItem.dominantColor` must return the same colour every time

**Why:** an app's highlight colour changing between launches is a bug the user cannot explain
and cannot report reproducibly.

**How it was broken:** `Dictionary.values.max` returns the first maximal element in iteration
order, and Swift seeds hashing randomly per process. Measured on real icons: 4 of 83
installed apps tie exactly, and `Passwords.app` alternated between `#FFD61F` and `#0C77F3`
across launches while `Safari.app`, which has no tie, never moved.

**How it is enforced.** The tie is broken on the bucket key, and
`Tests/ModelTests.swift` builds a deliberate tie and asserts which colour wins. Note an
in-process test cannot catch this — the seed is per process, so calling twice always agrees.
The test needs a **known tie with a predicted winner**.

## 9. Slot positions never compact

Removing the app in slot 3 leaves slot 3 empty rather than sliding 4 onwards down. Lowering
the visible count hides the tail rather than erasing it.

**How it is enforced.** `Tests/OuterRingTests.swift`.

## 10. Drawing and hit-testing read from one geometry instance

`RingGeometry` is a value type with no view state. `WheelView.geometry` is **computed**, not
stored, so the rotation used to draw cannot differ from the rotation used to hit-test.

**Why:** the failure mode is the wheel launching the app that *used to* be under the pointer.

**How it is enforced.** Structurally, by `geometry` being a computed property, plus
`Tests/GeometryTests.swift`.

# Chakra — session record: icon, audit, and the drag-and-drop shelf

**Session:** 2026-09-17 → 2026-09-22
**What this is:** the complete record of one long working session — what was discussed, every
option considered and why it was rejected, exactly what code changed, and the final plan.
**Who it is for:** any Claude Code session picking this up with zero context.

---

## How to use this file

This is the **narrative and the decision history**. The specifications are separate, and where
they disagree with this file, **they win**:

| Document | Holds |
|---|---|
| `docs/superpowers/specs/2026-09-22-chakra-shelf-design.md` | The approved shelf design. 18 decisions with measurements. |
| `docs/superpowers/plans/2026-09-22-chakra-shelf.md` | The implementation plan. 11 tasks, 82 steps, real code. |
| `ai/INVARIANTS.md` | What must stay true. §1 is absolute. |
| `ai/GOTCHAS.md` | 20 traps, each with evidence. |
| `ai/PENDING.md` | Current state and every open blocker. |
| `~/Claude/docs/2026-09-22-chakra-ship-readiness.md` | The GitHub publishing audit. Separate job. |

**The unique value of *this* file** is the rejected options and the corrections log. Those exist
nowhere else, and without them a future session will re-litigate settled questions or
re-introduce a belief that was already disproved.

**Verify before trusting.** Every `file:line` here was true on 2026-09-22. Several claims in
this project's own documentation turned out to be false during this session; assume the same
risk applies here.

---

## Starting state, and where it ended

| | 2026-09-17 | 2026-09-22 |
|---|---|---|
| Unit checks | 1712 | **1728** |
| Smoke checks | 422 | **422** |
| Known defects | unknown | **0 open** (11 found, 11 fixed, 1 refuted) |
| `ai/` docs `CLAUDE.md` references | 2 of 5 existed | **5 of 5** |
| Shelf | an idea | **specified and planned, no code** |
| Commits in either repo | **0** | **0** — still blocked |

---

# Part 1 — The app icon

## What was asked

"Chakra app icon color is not great."

## What was found

The icon is **drawn by code**, not shipped as a binary: `Tools/MakeIcon.swift` renders it and
`make-icon.sh` bakes `Resources/Chakra.icns`. So a colour change is a two-line diff, and every
size from 16 to 1024 points redraws sharp.

Measured the shipped icon's pixels rather than eyeballing it. The original was a violet→indigo
gradient (`#783DD1` → `#261F6B`) with white dots and two white bands at 22% and 20% opacity.

**The real problem was not the hue.** The two white bands measurably drained the colour —
chroma spread fell from 128 at the top edge to 89 inside the band — and the outer band's stroke
is 15% of the icon's width, so it read as a grey smudge rather than a ring. **The band's
*width* was the defect, not its colour.**

## Options put up, and what happened to each

Eleven variants were rendered by a throwaway Swift program using the real drawing geometry, then
shown in a browser at true Dock sizes (16/32/128/512 pt) over four different backdrops.

| # | Option | Outcome |
|---|---|---|
| 0 | Current violet (baseline) | shown for reference |
| 1 | Violet, "cleaned up" with tinted bands | **rejected — and my fix did not work.** Pale lavender at 30% behaves almost identically to white at 22%, because pale lavender already *is* mostly white. Visually indistinguishable from the baseline |
| 2 | Electric indigo | rejected |
| 3 | Deep teal | rejected |
| 4 | Amber to ember | rejected |
| 5 | Coral to plum | rejected |
| 6 | Graphite with a violet accent ring | rejected — but it proved the point: at 55% opacity the wide band stops being haze and becomes a deliberate shape |
| 7 | Sunrise (magenta→orange) | rejected |
| 8 | Emerald | rejected |
| **9** | **Chakra spectrum — dark base, 8 outer dots sweeping the hue circle** | **CHOSEN** |
| 10 | Monochrome | rejected |

## What shipped

`Tools/MakeIcon.swift`:
- gradient `#2A2140` → `#0C0817`, written as `0x2A / 255` etc. **so the render is byte-identical
  to the approved mock-up** — rounding to two decimals would have lost that proof
- bands dropped from 0.22/0.20 to **0.140/0.126**
- rim raised 0.22 → **0.26**
- outer 8 dots: `NSColor(hue: index/8, saturation: 0.85, brightness: 1)`
- inner 5 dots: white at 0.66

**Verified byte-identical** to the approved mock-up at 512, 128, 32 and 16 points. Also proven
**idempotent** — two runs of `make-icon.sh` produce the same sha, so the icon is a pure function
of its source.

## The cost that was accepted, with numbers

At 32 pt, **four of eight dots fall below the 3:1 WCAG non-text threshold** — violet 2.22:1,
blue 2.47:1, red 2.76:1, magenta 3.28:1. At 16 pt **all eight** fall below 2:1, where the old
white dots held 2.34–3.71:1. The eight relative luminances span 0.148 to 0.792, a **5.35×
spread**; the white dots they replaced were all exactly 1.0.

No dot disappears — each still perturbs its four pixels at 16×16 — but the ring reads as a
bright arc and a dark arc rather than eight equal slots. Two adjacent pairs also merge under
deuteranopia (ΔE 4.3 and 5.4).

**Accepted deliberately.** An app icon is found by silhouette and colour mass, not by resolving
eight dots at 16 pt. Supporting evidence found later: the running app's wheel is *already*
per-slot colourful by default (`WheelView.swift:450`, `Defaults.swift:370`), so coloured dots
are **more** faithful to the app than white ones.

## Where it was installed — 12 files

| # | File | How |
|---|---|---|
| 1–2 | `Tools/MakeIcon.swift` in both trees | hand-edited |
| 3–8 | `Resources/Chakra.icns`, `build/Chakra.iconset/*` (10 files), `build/Chakra.app/.../Chakra.icns` in both trees | `./build.sh` |
| 9–11 | `GIT_Chakra/assets/icon.png`, `Build_Chakra/build/assets/icon.png`, `projects/Chakra/brag-output/.../icon.png` | hand copy |
| 12 | `/Applications/Chakra.app/.../Chakra.icns` | **needed `sudo`** |

Final state verified by sha: all five `.icns` identical at `56618f35…`, all three marketing PNGs
at `5cb8165c…`.

## Three false comments this work introduced, then fixed

The `validate-verify` loop caught these. All three were **comment-only** fixes, proven to change
**zero pixels** — the icns sha did not move.

1. Claimed the rim was brightened "because a near-black body needs more help to separate from a
   dark wallpaper". **Measured: rim vs pure black went 5.28:1 → 3.21:1 — 39% worse.** The body
   lost 84% of its luminance; an 18% alpha rise cannot offset that.
2. Claimed "brightness is full so two-pixel dots still carry at 16 points". **Conflates HSB
   brightness with luminance.** See the spread above.
3. Claimed keeping band alpha at 0.22 "would read as a grey disc" against near-black.
   **Never measured.** What *is* measured: the drop to 0.140 exactly cancels the darkening —
   1.259:1 vs 1.255:1 at 16 pt.

**Icon loop verdict: HOLD · gates 7/8.** The failing gate was 4 — no test was added, because
`MakeIcon.swift` carries `@main` and cannot link into the test binary. A script-level pixel
assertion is possible and still unwritten.

---

# Part 2 — Is the GitHub ship ready?

Four agents ran in parallel: a clean-clone build test, Gatekeeper reality, a CI/release workflow
audit, and a hygiene/secrets sweep.

## Answer: No. Seven blockers, none of them a code problem.

**The build is genuinely sound.** Tested on a machine with **no Xcode installed** — exactly a
stranger's condition: `./build.sh` 17.2 s, `./run-tests.sh` 1712 checks, `./make-icon.sh`,
`./make-dmg.sh` — all exit 0. Deleting `Resources/` entirely and rebuilding also worked, because
`build.sh:65` regenerates the icon when missing.

## The blockers

1. **Only 5 of 127 files are tracked in git**, and **16 of 17 `Sources/*.swift` are untracked.**
   Pushing as-is gives strangers a repo that **does not compile**.
2. **`RudraMind` is a placeholder, not an account** — 27 occurrences across 12 files. The
   project's own runbook warns about it. It is why `README.md`'s clone URL returns **HTTP 404**.
3. `LICENSE:3` reads `Copyright (c) 2026 <YOUR_NAME>`.
4. `CODE_OF_CONDUCT.md:62` reads `maintainer at <MAINTAINER_EMAIL>`.
5. **A live token is in the publish set** — `.superpowers/brainstorm/.last-token`, 64 hex
   characters, not gitignored, echoed again in `state/server.log`. Loopback-only and the server
   is stopped, so real risk is low, but it is a cleartext secret in a public repo.
6. `release/RELEASE-NOTES.md:5` **says "delete before publishing"** and is still in the set.
7. **The install instructions are wrong on every supported macOS except 14.**

## The Gatekeeper finding, with citation

**macOS 15 Sequoia removed Control-click → Open.** Apple stated it in a developer news post,
2024-08-06 — https://developer.apple.com/news/?id=saqachfa. Corroborated by Apple's own user
guide article `mh40616`, which contains the Control-click step at `/14.0/` and has it **deleted**
at `/26/`.

The dialog users actually see now, verified two independent ways (Apple support page 102445 and
this machine's `CoreServicesUIAgent` string tables):

- Title: `"Chakra" Not Opened`
- Body: `Apple could not verify "Chakra" is free of malware that may harm your Mac…`
- Buttons: **`Done`** and **`Move to Trash`** — **there is no Open button**

The string the project quotes in four places has **zero hits** in macOS 26.5.1's system
resources. It no longer exists.

The real path is four steps, and **`Open Anyway` expires after about an hour** — which nothing
on screen explains. Apple's own sentence is the cleanest statement of the whole situation:

> "There isn't a specific identity requirement for this signature: a simple ad-hoc signature is
> sufficient. However, given that these signatures do not bear any valid identity, binaries
> signed this way cannot pass through Gatekeeper."

## Good news confirmed

- **The workflows are sound.** All four actions verified live, `macos-15` is valid and free on
  public repos, both YAMLs parse, permissions are minimal and complete.
- **The attestation promise in `VERIFYING.md` is genuinely honoured** — `actions/attest@v4` with
  `subject-path` does auto-generate SLSA provenance, and the permissions block has all three
  required keys.
- **Version consistency is perfect** — 12 locations all agree on `1.0`.
- **`VERIFYING.md` is right that `gh auth login` is required**, even for a public repo.
- **No shipped file recommends `xattr -d com.apple.quarantine`** — assessed as the project's
  strongest existing decision.

---

# Part 3 — Full codebase audit

## Method

All 18 source files read — 6,346 lines. Nine candidate findings produced, then handed to an
independent agent with an explicit instruction to **distrust them**. It confirmed 11, refuted 1,
and found four more the first pass missed entirely.

## The structural reason defects survived

**`run-tests.sh` compiles 10 of the 18 source files, by design** — "the files with no UI in
them". `run-smoke.sh` compiles 17. So **seven of the eleven defects were unreachable by the unit
checks no matter what anyone wrote in `Tests/`.**

And the headline number is softer than it looks: **it is a runtime counter, not a count of
assertions.** There are ~658 assertion sites, and one loop in `Tests/GeometryTests.swift`
iterating outer 4…10 × inner 0…7 contributes **588 checks on its own** — about a third.
Widening the slot-count range inflates the number without adding one idea.

## The twelve fixes

| # | Defect | Where | Fix |
|---|---|---|---|
| **C1** | The slot-count refusal reported the **wrong numbers**. The slider was snapped back *before* the message read it, so dragging 8→4 produced *"Turning it down to **8** would leave you with **3** apps. The ring keeps at least 3"* — the wrong count, and a comparison that reads as no violation | `SettingsWindow.swift` | pass the refused value in explicitly |
| **C2** | Three user-visible strings hardcoded **"eight"** while the ring is settable 4–10 | `SettingsWindow.swift:632`, `Onboarding.swift:310`, `WheelView.swift:1047` | interpolate the real count |
| **C3** | `StatusDropView` had no `draggingEnded`, so a cancelled drag could leave the accent wash **painted on the menu bar** | `StatusItem.swift` | add the override `OrbView` already had |
| **C4** | Three setters wrote to the plist **unclamped** while their getters clamped — and a neighbouring comment claimed "every other bounded setting" clamps both ways | `Defaults.swift` | clamp on write; add `maxRotationSteps` so getter and setter cannot drift |
| **C5** | **`dominantColor` was nondeterministic.** `Dictionary.values.max` returns the first maximal element in iteration order, and Swift seeds hashing **per process** | `Models.swift` | tie-break on the bucket key |
| **C6** | `colorCache` was never invalidated, so an updated app kept its **old halo colour for the whole app process** | `WheelView.swift` | clear it in `resetTransientState()` |
| **C7** | Case-sensitivity hole: the `.app` suffix test was case-insensitive, the prefix test was not. **Five prefixes leaked** | `Models.swift` | lower-case once, used for both; prefixes moved to lower case |
| **C8** | The orange slot-count warning **never cleared** — not on a later success, not on `refreshEverything`, not on closing the window | `SettingsWindow.swift` | add `clearSlotCountNote()` |
| **M1** | **Right-click during a wheel drag silently rewrote `openLocation` permanently**, and flashed a toast on an invisible window | `WheelView.swift` | guard `rightMouseDown`; clear `rightPressTarget` in `mouseDown` |
| **M3** | `applyingOwnChange` was not re-entrancy-safe by construction | `SettingsWindow.swift` | save and restore instead of set/clear |
| **M4** | `applyIdleState`'s `?? .zero` fallback **teleported the orb to x = −34.72** — 62% off the left edge, where `constrainFrameRect` will not pull it back | `OrbController.swift` | `guard let` and bail instead |
| **M5** | `.app` suffix checks were case-sensitive in two more places | `Recents.swift`, `Proposal.swift` | lower-case them |

## The C5 measurement, because it is the most instructive

Reverting the fix and running the test in **8 separate processes: 3 passed, 5 failed.** On real
icons the auditor measured **4 of 83 installed apps tie exactly**, and:

```
Passwords.app   17 × #FFD61F   13 × #0C77F3    ← yellow or blue, depending on the launch
TV.app          16 × #FF99AB   14 × #C2E5FF    ← pink or pale blue
Safari.app      30 × #0B89FF                   ← no tie, never moved (the control)
```

An in-process test **cannot** catch this: the seed is per process, so calling twice always
agrees. The regression test therefore builds a **deliberate tie with a predicted winner**.

## One finding refuted

**C9 — the orb recomputing dominant colours — is not a performance defect.** Measured **0.34 ms
for ten icons**, about 2% of a 60 Hz frame. The auditor did find the *frequent* trigger the
first pass missed: the orb's **opacity** slider recomputes all ten ~60×/second, for a setting
with nothing to do with colour. Still 2% of a frame. Worth a cache for tidiness, not speed.

## Three regression tests, each proven red-green

| Test | Reverted the fix → |
|---|---|
| case-sensitivity | **5 checks failed**, exactly the new ones |
| setter clamping | `got 999999999, want 1000` |
| colour determinism | **5 of 8 separate runs failed** with `got blue 0.0`. Restored → 5 of 5 pass |

Eight of the twelve fixes have **no test**, because they live in the view layer. Smoke never
constructs `StatusDropView`, never calls `draggingEnded`, **never touches right-click**, and its
fixture makes the slot-count refusal path unreachable — so `flashSlotCountNote` had **never
executed** in 422 checks.

**Audit verdict: HOLD · gates 7/8.** Gate 8 (stability) stays open because no independent
reviewer has seen the twelve fixes — and that is not theoretical, see the corrections log.

---

# Part 4 — The shelf: every option and why it lost

## What was asked

> "inside the 2nd circle we have space which is not used much… instead I want to use it as a
> Drag-and-Drop Shelf space… it stores the files up to 1 GB… for a long time… as copy… when
> Chakra is not touched, while it's small, no. of files let's say 3 in drag and drop, in Chakra
> it will show 3 so it's known… option similar to Dropover."

## The first thing found — it kills the literal request

`WheelWindow.swift:133` calls losing key focus **"the whole dismissal mechanism"**. So: the
wheel is open → you click a file in Finder → Finder becomes frontmost → **the wheel is gone
before your drag arrives.**

The codebase already said so, in **three** separate comments — `Onboarding.swift:172`,
`WheelView.swift:141`, and the `emptyOuterSlotHint` string. Independent confirmation that the
diagnosis was right.

**Resolution:** the **orb** is the intake. It is a `.nonactivatingPanel` that never takes key
focus and floats above everything, so it is reachable mid-drag — and it already registers
`.fileURL` at `OrbView.swift:65`.

## Hub readout — four options

The hole is **144 pt across**; a square inscribed in it is about **100 × 100 pt**. That is the
entire budget — smaller than a Dock icon.

| Option | Verdict |
|---|---|
| **A** — big number + kind word ("6 / images / 12.7 MB") | **rejected.** A mixed shelf has no single noun. The only honest word is "items", which spends the one spare line saying nothing |
| **B** — card stack, the files fanned as little cards | **rejected on measurement.** It caps at three visible cards, so on a 6-item shelf it **draws 3 and cannot report a count at all**. At the 0.7× minimum wheel scale the cards are ~24 pt tall |
| **C** — number and size only | superseded by D. Dropping the kind word buys a **62 pt** number instead of 46 pt, which is what keeps it legible at 0.7× |
| **D** — "Add to shelf" + the total | **CHOSEN by the owner** |

**Then overruled, partially, on design grounds.** Option D as a *permanent* resting label is
wrong: a great Mac app does not label its content with an imperative forever — the Dock does not
say "add apps here". Once six files are on the shelf it is noise that never goes away.

**Final:** the **content is the resting state**; the "Add to shelf" invitation appears on hover,
mid-drag, or when empty. The empty state is the one place an instruction belongs, and it is the
most important screen.

## Orb count placement — three options

| Option | Verdict |
|---|---|
| Corner badge outside the disc | **rejected by the owner** — "instead of the notification on outside of outer ring" |
| Inside, at the top | **rejected on measurement.** Twelve o'clock is the **lead dot**, which gives the orb its orientation. Fitting a digit there forces the lead dot to shrink, and even then they crowd — visible in the 3× render |
| Inside, replacing the centre dot | **asked for by the owner** |

**Then overruled.** The orb is a miniature of the user's own ring — eight dots that are their
apps. A digit in the middle turns it into a notification widget and costs it that identity.

**Final:** **presence at rest, precision on demand.** The centre dot grows and takes the accent
colour when loaded; the exact count appears on hover and in the hub. "Is there something on my
shelf?" is the at-rest question; "how many exactly?" is answered when asked. Also: three digits
do not fit ~24 pt of clear width, so `99+`.

## The gesture conflict — three options

Both of these are a press-and-drag on the hub: **moving the wheel** (what it does today,
`WheelView.swift:740-745`) and **dragging files out** (required).

| Option | Verdict |
|---|---|
| **Glass bands move the wheel** | **CHOSEN.** The bands are large and a press on them currently does **nothing** in the code, so the gesture was free |
| Hold ⌥ to move | rejected — undiscoverable, nobody finds it |
| No drag-out; clicking the hub opens Finder | rejected — removes the half of the feature the owner asked for |

`.center` also stops dismissing. Dismissal becomes Esc and click-outside.

## Storage location — five options

| Option | Verdict |
|---|---|
| `~/Documents` or `~/Desktop` | **rejected, and this is the most important finding in the whole design.** On this machine they are **symlinks into `~/Library/CloudStorage/OneDrive-<organisation>/`** — a shelf there would silently upload every dropped file to the user's employer. They are also TCC-protected |
| `/Library/Application Support` | **rejected** — `root:admin`, `touch` returned `Permission denied`. Would make installing require a password |
| Ask the user at install | **rejected** — a question at the worst possible moment, before they know what a shelf is; and Chakra's pitch is zero setup |
| Fixed default + a "Change…" button | **rejected**, see below |
| **`~/Library/Application Support/local.chakra/Shelf/`** | **CHOSEN** |

Verified: `~/Library/Application Support` has **no TCC service and no Info.plist usage key** —
checked against Apple's protected-resources list *and* this machine's `tccd` binary. A write
probe succeeded with no prompt and no admin, and 62 other apps already use it. The **bundle
identifier** rather than `Chakra`, because macOS 14+ `SystemPolicyAppData` prompts for access to
*another* app's container.

## Why the "Change shelf folder…" button was dropped

A user picking a folder in a panel really is safe in principle — Apple documents implicit consent
on the **non-sandbox** page, and WWDC 2019 session 701 says access is granted "without the need
for a consent prompt". Three findings killed it anyway:

1. **Security-scoped bookmarks are worse than useless here.** Measured in a non-sandboxed
   process: plain `[]` produces an 852-byte bookmark **with** a token; `.withSecurityScope`
   produces 644 bytes with **none**. Asking for security scope **strips** the thing you wanted.
   And `startAccessingSecurityScopedResource()` still returns `true` — **it lies.**
2. **Chakra is ad-hoc signed, so it has no stable identity.** Measured: two builds of
   `local.chakra` produced two different designated requirements, each only a cdhash. Apple's
   TN3127: *"macOS can't reliably track the identity of the code."* Apple DTS recommends a stable
   identity to *"radically cut down on the amount of TCC thrash"*. Any grant may be forgotten at
   the next rebuild, and that cannot be proven either way.
3. **A veto denylist rots.** Apple adds protected locations; the guard silently stops covering
   them. And on a machine where `~/Documents` is a cloud symlink, a wrong grant likely lands in
   `kTCCServiceFileProviderDomain`, which has **no revocation UI** — a mistake there is permanent.

**Also decided: do not add `NS*FolderUsageDescription` keys.** Declaring that Chakra wants
Documents access, in an app that never touches it, is a lie in the one file a curious user reads.

## Paste format — three options

The owner asked: "if I copy an image and paste into the shelf, will a new file be stored?"

Measured the real clipboard from a real screenshot copy:

| Type | Bytes |
|---|---|
| `public.tiff` | 3,524,960 (**3.44 MB**) |
| `public.png` | 908,509 (**887 KB**) |

Same pixels — 1118 × 788 — and **TIFF is 3.9× bigger**.

| Option | Verdict |
|---|---|
| Always PNG | **rejected.** A real photo re-encoded from JPEG measured **6.7× larger**. 1 GB would hold ~50 photos instead of ~340 |
| Always JPEG | **rejected.** On a text-heavy screenshot JPEG q0.9 is only **6% smaller** than PNG while being lossy. Taking lossy damage for a rounding error |
| **Pass through verbatim** | **CHOSEN.** Optimal in both directions and re-compresses nothing |

**Final rule:** write `public.png` or `public.jpeg` bytes **verbatim**; convert to PNG only if
`public.tiff` is all that is offered; **never write TIFF**.

**The lookup order is the whole feature.** Measured: after PNG is placed on a board,
`data(forType: .tiff)` returns **14,749,968 synthesised bytes** for a 12,112,483-byte PNG.
**AppKit invents TIFF on demand** — so a TIFF-first lookup, or anything using
`NSImage(pasteboard:)`, inflates the file **22×**.

And measured: **`writeObjects([NSImage])` puts *only* TIFF on the board.** So the conversion path
is the **common** case for app-sourced images, not the fallback.

## Caps — re-decided after measurement

The owner said 1 GB. Then a measurement invalidated the premise:

**`FileManager.copyItem` on the same APFS volume is `clonefile(2)`, not a byte copy.** 100 MB
"copied" in **0.120 ms**, consuming **4,096 bytes**. A 5 GiB file in 0.12 ms. The copy is
genuinely independent — distinct inode, `st_nlink = 1`, and truncating the source left it intact.

So a user can put 1 GB on the shelf and free **zero bytes** by emptying it. Meanwhile a 4 GB
**sparse** file occupying 0 bytes gets refused.

| Option | Verdict |
|---|---|
| Warn at 500 MB | **dropped.** Bytes are not the scarce resource. Attention is |
| Copy what fits when a drop is too big | **rejected.** A partial copy is unverifiable by the user — they cannot tell which files landed without comparing by hand — and every "what fits" rule is arbitrary |
| **Refuse the whole drop past 1 GB; note at 10 items; never auto-delete** | **CHOSEN.** The cap is a backstop against unboundedness expressed in a number the hub can honestly display |

The refusal must do the arithmetic and offer an exit, or the cap becomes a trap whose only escape
is Finder. Hence also: **an in-Chakra remove via `trashItem`** is required, not optional.

## Five more decisions taken

| Decision | Reason |
|---|---|
| **`.app` bundles refused** on intake | A copied bundle breaks its signature's path assumptions and may not launch. The wheel already exists for apps, so refusing teaches it |
| **Promise drags supported** | Dragging an image out of Safari, Mail or Photos yields **zero file URLs** — measured. It is the archetypal shelf gesture, and without support it fails **silently** |
| **Leading dots stripped** | A shelf item the user cannot see is worse than a renamed one |
| **Local time in pasted names** | Matches Apple's screenshot convention |
| **Excluded from Time Machine, not Spotlight** | The originals still exist elsewhere, so it is not backup-worthy. Finding a shelved file by search *is* useful |

## Name rules, all measured

- **Finder's drop convention is `report 2.pdf`**, not `report copy 2.pdf`. Read from Finder's own
  string table: template `N1` is the drop-collision form; `N4` (`copy`) is ⌘D, a different
  gesture. There is no `copy 1`.
- **The length limit is 255 UTF-16 code units, not bytes.** 255 × `é` is 510 UTF-8 bytes and
  succeeds; 256 fails `ENAMETOOLONG`. 127 × 😀 succeeds, 128 fails.
- **`/` in a name is a path-traversal hazard.** `appendingPathComponent("with/slash.txt")` yields
  `lastPathComponent == "slash.txt"` — the file lands in a subdirectory.
- **APFS stores Unicode decomposed.** Swift `String ==` is safe; byte comparison is not.
- **`Icon\r` is not hidden** and survives `.skipsHiddenFiles`. It must be excluded by name — and
  this matters because the hub's own click action opens the folder in Finder, which creates it.

## Verified copy — why the design has a temporary name

**A failed *folder* copy leaves a partial tree behind.** Measured: `copyItem` on a folder with
one unreadable child threw and left four of five entries in place. Single-file failures do clean
up after themselves — disk-full and a mid-copy volume yank both left nothing.

So: copy to `.chakra-incoming-<uuid>` → verify → atomic `moveItem`. Verification is a **size
comparison** on the same volume (a clone is identical by construction, ~0.03 ms) and **SHA-256**
across volumes (41 ms per 100 MB streaming 1 MB chunks). `FileManager.contentsEqual` was measured
**12.3× slower** than hashing and is not used.

## Counting — live scan, no index

| Items | Scan cost |
|---|---|
| 10 | **0.035 ms** |
| 100 | 0.204 ms |
| 1000 | **1.905 ms** |

At the 10-item threshold that is 0.002% of a 60 Hz frame. An index would buy nothing measurable
and would introduce a second source of truth that can be wrong — the only way this feature can
lie to the user.

The directory watch uses `open(O_EVTONLY)` + `DispatchSource`, which needs **no entitlement and
raises no permission prompt** — unlike `FSEventStream` on an arbitrary path. That is what keeps
it compatible with the never-prompt invariant.

---

# Part 5 — Corrections log

**Read this before trusting anything else in this file.** Ten claims made during this session
were wrong and were caught. The pattern in every case: a measurement beat a piece of reasoning.

## My own errors

1. **"The drawn colour differs from the source hex."** Wrong — my probe's
   `usingColorSpace(.sRGB)` conversion caused the shift. The file was bit-exact.
   *Lesson: a measurement tool is part of the system under test.*
2. **"`/Applications` is writable, no sudo needed."** Wrong — `touch /Applications/.probe` proved
   only that a *new file* could be created, not that root-owned files *inside* a subdirectory
   could be deleted. The install then failed.
   *Lesson: test the actual operation, not a cousin of it.*
3. **"The publish set is 7.0 MB across 127 files."** Wrong — a hand-rolled `find` counted paths
   git ignores. Real figure: **5.46 MB across 89 files**, from `git ls-files -co
   --exclude-standard`. *Lesson: ask the tool that owns the answer.*
4. **A verification loop that compared empty strings.** A shell loop printed "MATCHES" four times
   while `shasum` was erroring on malformed arguments, so both sides were empty and equal.
   *Lesson: a check that cannot fail is not a check.*
5. **Relayed `build.sh`'s login-item claim as a firm cost.** It was a code comment, not evidence —
   and Apple's `SMAppService` docs never mention cdhash, while an Apple engineer says BTM approval
   is sticky. *Lesson: a comment is a claim.*
6. **Predicted C1's symptom wrongly.** Predicted *"leave you with 8 apps"*; the real string is
   *"leave you with 3 apps. The ring keeps at least 3"* — worse, because it reads as no violation.
7. **Understated C5's severity** as MEDIUM-LOW. It is the most severe finding in the audit.
8. **Claimed the orb colour recompute was a performance defect.** Refuted — 0.34 ms for ten icons.
9. **My own `M1` fix had a regression hole.** The guard included `!isDraggingOut`, but that flag is
   *documented as outliving its gesture*, so a stale `true` would have made the **next** right-click
   silently do nothing. Found by checking whether smoke covers right-click — it does not, at all.
   *Lesson: green tests prove you did not break what is tested.*
10. **Recommended adding `WheelView` to `run-tests.sh`.** Wrong — verification showed
    `run-smoke.sh` already compiles 17 of 18 files. The boundary is deliberate, not an accident.

## False claims found in the project's own files

| Claim | Where | Reality |
|---|---|---|
| `.superpowers/` "is not gitignored" | `CLAUDE.md:93` | `sdd/` **is** ignored by a nested `.gitignore`; `brainstorm/` is the part that leaks |
| cdhash "changes on every recompile" | `build.sh:70-78` | Recompiling identical source leaves it **unchanged**. It changes when content changes |
| Login-item approval drops after a rebuild | `build.sh:70-78` | Unsupported by any Apple source; Apple-staff commentary argues against it |
| `Resources/Chakra.icns` "is committed" | `README.md:91` | Nothing is committed, and `build.sh:62-63` says the opposite |
| 21 user-adjustable settings | `README.md:295`, `SECURITY.md:88-89` | **19.** `CHANGELOG.md:43` says "Thirty" — three docs, three numbers |
| `wheel-light.png` shows "Light glass" | `README.md:126` | Same image as `hero.png` — 0.71% of pixels differ. It is a **code bug**: `Preview.swift:107-114` hardcodes the backdrop, so the `.aqua`/`.darkAqua` loop cannot produce a light image |
| 396 smoke checks | four internal docs | **422** |
| Bands are "what keeps the icon reading as a ring" | `MakeIcon.swift` | At **1.26:1** in both versions, they are a faint hint at best |

---

# Part 6 — Who decided what

Recorded because it matters for reversing anything.

| Decision | Whose |
|---|---|
| Icon option 9 (spectrum) | **owner** |
| Hub readout = "Add to shelf" + total | **owner** |
| Count moves inside the orb | **owner** |
| 1 GB cap | **owner** |
| PNG, never TIFF; JPEG passed through | **owner** |
| Storage location | **mine** — on a constraint the owner could not have seen (OneDrive symlinks) |
| Warn thresholds, and refuse-vs-evict | **mine** |
| Badge = centre, not top | **mine**, on measurement |
| Glass bands move the wheel | **mine** |
| Content at rest, not a permanent "Add to shelf" | **mine** — reverses part of the owner's pick |
| Presence not precision on the idle orb | **mine** — reverses part of the owner's pick |
| 500 MB warning dropped | **mine**, after the clone measurement |
| No "Change shelf folder…" button | **mine** |
| `.app` refused; promise drags supported; dots stripped; local time; Time Machine excluded, Spotlight not; in-app remove | **mine**, delegated explicitly |

The owner approved the spec containing all of the above on 2026-09-22.

---

# Part 7 — The final plan

**`docs/superpowers/plans/2026-09-22-chakra-shelf.md`** — 2,755 lines, **11 tasks**, **82
checkbox steps**, **60 Swift code blocks**, zero placeholders. Nine tasks include an explicit
red-green proof that names the exact failure to expect.

| Task | Deliverable |
|---|---|
| 1 | Wire new files into all three scripts; scratch-directory test helper |
| 2 | `ShelfName` — sanitising, collision numbering, UTF-16 truncation |
| 3 | Folder creation, self-healing, and the one case that must **not** self-heal |
| 4 | `ShelfItem`, live listing, totals, early-bail sizing |
| 5 | Verified copy — link resolution, `.app` refusal, atomic cap |
| 6 | Cross-volume hash verification |
| 7 | Trash-based removal, launch sweep, backup exclusion |
| 8 | Pasteboard intake — verbatim PNG/JPEG, pasted names |
| 9 | Directory watch with no permission prompt |
| 10 | Orb intake and the presence dot *(first view-layer task)* |
| 11 | Hub readout, gesture rework, drag-out |
| **12** | **NOT WRITTEN — `NSFilePromiseReceiver`. Must not be dropped.** |

**Tasks 1–9 are UI-free** and go in `run-tests.sh` where the project's boundary says logic
belongs. Only 10–11 touch the view layer, where checks must live in `Tools/Smoke.swift`.

**Two caveats about the plan.** Its check counts (1729 → 1840) are **predictions to verify**, not
measurements — no code has been run. And **every "Commit" step will fail** until a git identity
exists; the plan says so rather than pretending otherwise.

**Task 12 is a real, deliberate gap.** Without it, a promise-only drag returns `false` — a
**silent** failure, the worst outcome available. If deferred, Task 10 must show
`"Chakra can't take that kind of drag yet"` instead.

---

# Part 8 — Blocked on the owner

Nothing in Part 7 can be committed, and nothing in Part 2 can proceed, without these four:

1. **A git `user.name` and `user.email`.** Neither repo has a single commit. No identity has ever
   been invented for this project, deliberately.
2. **The real GitHub owner handle**, to replace `RudraMind` in 27 places.
3. **The copyright holder** for `LICENSE:3`.
4. **The maintainer email** for `CODE_OF_CONDUCT.md:62`.

Also worth one check: **was "Open at login" ever enabled?** The 2026-09-17 reinstall changed the
bundle's cdhash. If it was on, System Settings would settle the disputed claim in `GOTCHAS.md`
#19 with a single observation.

---

# Part 9 — How to resume

```bash
cd ~/Claude/projects/Chakra && claude --add-dir ~/Claude/docs/GIT/GIT_Chakra
```

The `--add-dir` matters: **two source trees** must stay byte-identical
(`~/Claude/projects/Chakra` and `~/Claude/docs/GIT/GIT_Chakra`) and nothing enforces it. Without
the flag, every sync write to the second tree needs a permission prompt.

**Verify the starting point. All three must hold:**

```
./run-tests.sh   → 1728 checks passed
./run-smoke.sh   → 422 smoke checks passed    (needs an unlocked screen; it hard-fails on a locked one)
./build.sh       → exit 0
```

If any number differs, the tree has drifted since 2026-09-22 and the plan's expected counts are
wrong. Say so rather than proceeding.

**Do not run `./build.sh --install`** — it needs `sudo` on this machine and fails partway,
leaving the installed app untouched but the run aborted.

**Read in this order:** `ai/INVARIANTS.md` → `ai/GOTCHAS.md` → `ai/PENDING.md` → the spec → the
plan. Then use `superpowers:subagent-driven-development`, one fresh subagent per task, with review
between tasks — a fresh reviewer per task is exactly what caught the defect in correction #9.

**Things that live only in `/tmp` and die on reboot** — none are needed to build, recorded so
nobody hunts for them:

- `/tmp/chakra-shelf/` — the shelf mock-ups and the renderer
- `/tmp/chakra-icons/` — the eleven icon variants
- `/tmp/chakra-icon-backup-20260917-2338/` — the pre-change icon files. The original values are
  recorded in Part 1 and in the ship-readiness doc, so a revert is possible without them
- `/tmp/chakra-probe/`, `/tmp/chakra_probe/`, `/tmp/proveit/` — measurement probes from the audits

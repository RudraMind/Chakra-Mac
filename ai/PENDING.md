# Pending — what is unfinished, and who can finish it

Last updated **2026-09-23**. `CLAUDE.md` has pointed at this file since the project started;
it did not exist until that date.

Verify any `file:line` before acting on it.

---

## Owner decision — resolved 2026-09-23

The owner supplied the ship-time values: repository `RudraMind/Chakra-Mac`, copyright holder
`RudraMind`, maintainer contact `282997122+RudraMind@users.noreply.github.com`. `LICENSE:3`,
`CODE_OF_CONDUCT.md:62` and every repository URL now carry them.

## Before publishing

**Eight non-owner-blocked items completed 2026-09-22:**

- The 64-hex bearer token in `.superpowers/brainstorm/.last-token` is now **gitignored** —
  verified with `git check-ignore -v`, which reports the rule and its line number. The same rule covers the
  second copy in `state/server.log`. **The file was deliberately not deleted**; ignoring is
  sufficient and deleting user state was judged not ours to do.
- `release/RELEASE-NOTES.md`'s "delete before publishing" block is **gone**.
- `smoke-output.txt` is **deleted**.
- `BUILD-CHAKRA.md:41`'s absolute home path is now **`~`-relative**.
- The settings count is **corrected in four documents** — the agent counted independently from
  `Sources/Defaults.swift` and got **19** user-settable (plus 2 data keys and 9 internal-state
  keys = 30 total), which is where `CHANGELOG.md`'s "Thirty" came from.
- The macOS 15 install instructions are **rewritten in all seven places**, and now state that
  **`Open Anyway` expires after about an hour**.
- `README.md`'s `wheel-light.png` caption **no longer claims to show light glass**.
- `README.md`'s `.icns` claim is now true: `Resources/*.icns` is gitignored, so "generated, not committed" describes what actually happens.

**Resolved 2026-09-23 before the first commit:**

- **Personal app list removed.** The six wheel images, the two HTML mockups and their Python
  generators showed or named the owner's real apps, and two docs named the employer in an
  OneDrive path. The images and mockups were removed; `Tools/Preview.swift` now renders only
  apps that ship with macOS, and the docs were scrubbed. The README images are re-rendered by
  CI (`render-preview.sh`), not captured from a personal Mac.
- **Light render.** `Tools/Preview.swift` hardcoded the glass tint to dark, so the `.aqua` pass
  could not produce a light wheel. The tint now follows the drawing appearance.


## The shelf

**Tasks 1-3 complete, reviewed and integrated.** The plan exists at
`docs/superpowers/plans/2026-09-22-chakra-shelf.md`; the ledger at
`.superpowers/sdd/2026-09-22-chakra-shelf/progress.md` records every decision, ruling and
measurement. Current state (see ledger's last Task N complete line for exact check count):

- `Sources/Shelf.swift`, `Sources/ShelfName.swift`, `Tests/ShelfTests.swift`,
  `Tests/ShelfNameTests.swift` exist and are in all three build scripts.
- `ShelfName.sanitize` and `ShelfName.candidate` are complete, tested, and survived two fix
  rounds after review surfaced an empty-string regression and a symlink security hole.
- `Shelf.ensureExists()` self-heals a read-only folder and refuses to self-heal when it
  cannot. It survived three fix rounds after a race condition (0.4% frequency in 160,000
  concurrent calls) was measured and fixed.
- Storage is `~/Library/Application Support/local.chakra/Shelf/`. The bundle identifier rather
  than `Chakra`, because macOS 14+ `SystemPolicyAppData` prompts for access to *another* app's
  container.

**Owner decisions, 2026-09-22:**

- **Mac App Store** is the target. Ship from one sandboxed codebase, with the ⌥-click-quit
  feature (`Sources/WheelWindow.swift:448`) flagged off when sandboxed — measured,
  `NSRunningApplication.terminate()` returns `false` under the sandbox and the target
  survives.
- **Superseded 2026-09-23 — one tree, not three.** The 2026-09-22 decision was a three-tree
  split: a drag-free tree that ships, a second copy carrying the shelf, and a pre-shelf revert.
  The owner replaced it on 2026-09-23 with a single self-contained folder — this one — carrying
  the shelf and its own `GIT-COMMANDS.md`. Nothing outside this folder is needed to publish it.
  If a drag-free variant is ever wanted, it is a fresh branch off this tree, not a fourth copy.

**Open item for v1:**

- **Spec §6's unreadable-child `FileManagerDelegate` is formally unimplemented**. Adding the
  delegate would make a folder copy's size legitimately differ from its source, which the
  verified-copy size check would then reject as `volumeDisconnected`. `AddOutcome.skipped` is
  being added now so a later fix needs no shape change, but the delegate is not set in Tasks
  4-7.

## Test coverage gaps

- **`main.swift` has no coverage, by construction.** See `GOTCHAS.md` #2.
- **The view layer is only reachable from `Tools/Smoke.swift`**, which needs an unlocked
  screen. `run-tests.sh` compiles 10 of 18 files, by design.
- **`Tools/MakeIcon.swift` has no coverage and cannot have a unit test** — it carries `@main`,
  so it cannot link into the test binary. A script-level pixel assertion is possible and was
  never written. It would have caught three false comments found on 2026-09-17.
- Of eleven defects fixed on 2026-09-22, **three now have regression tests** (case-sensitivity,
  setter clamping, colour determinism). The other eight are fixed but unguarded, because they
  live in the view layer. **Smoke checks for them are the single highest-value test work
  remaining**, in particular:
  - the slot-count refusal path — the smoke fixture fills three slots, so
    `canSetVisibleCount` always succeeds and `flashSlotCountNote` has **never executed** in
    558 checks
  - `StatusDropView` is **never constructed** anywhere in the smoke tool
  - `draggingEnded` / `draggingExited` are never called on any drop target

## Known-fragile, deliberately left alone

- `ci.yml:92` `actions/upload-artifact@v7` has no `overwrite: true`. Whether a re-run collides
  could not be confirmed from GitHub's docs. One-line hedge.
- `build.sh:79` makes ad-hoc signing **non-fatal** and `ci.yml:40` only *prints* the
  signature. So CI can ship an unsigned bundle green while `VERIFYING.md` promises
  `Signature=adhoc`. A `grep -q 'Signature=adhoc'` closes it.
- The CI runner's Swift is **older** than the local toolchain (Xcode 16.4 vs 6.3.3) and every
  script uses `-warnings-as-errors`. Warning-free locally does not guarantee warning-free
  there. Only a real run settles it — push private first.
- `render-preview.sh` calls `NSApplication.shared`, which needs a window-server session, and
  `ci.yml` runs it while describing it as "no window". Usually fine on GitHub's macOS runners;
  undocumented.

## Documentation defects still open

Earlier versions of this file listed five defects here. Four of them were fixed on 2026-09-22
and 2026-09-23 and have been removed rather than left to rot — the settings count (now
**Nineteen** in `README.md`, `SECURITY.md` and `CHANGELOG.md`, with 30 preference keys total),
the `wheel-light.png` caption, the false `.icns` claim, and the stale `smoke-output.txt`. The
smoke figure that four documents once gave as 396 is also corrected. The fifth — two
near-identical README images — was fixed in `Tools/Preview.swift` on 2026-09-23 (see above).

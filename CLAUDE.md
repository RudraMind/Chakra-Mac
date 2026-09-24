# Chakra — notes for Claude Code

Read this first. It is short on purpose; the detail lives in `ai/` and the links are exact.

Chakra is a **radial application launcher for macOS**: a two-ring wheel of app icons, plus a small
always-on-top orb that opens the wheel when clicked. Swift + AppKit, built by `swiftc` alone.

## Orient yourself in one minute

| Question | Answer |
|---|---|
| Build it | `./build.sh` → `build/Chakra.app` |
| Test it | `./run-tests.sh` (2,136 checks, no window server needed) |
| Test the UI | `./run-smoke.sh` (558 checks, **needs an unlocked screen**) |
| Installed at | `/Applications/Chakra.app` |
| Dependencies | **None.** No SwiftPM, no Xcode project, no third-party code. |
| Test framework | Hand-rolled, `Tests/TestMain.swift`. **Not XCTest** — it needs Xcode. |
| Language / target | Swift 5 mode, `macos14.0`, `-warnings-as-errors` in all six scripts |

## The five things that will bite you

Read `ai/GOTCHAS.md` before debugging anything. The short version:

1. **`run-smoke.sh` fails completely on a locked screen.** The window server refuses to move
   windows, so every orb-tuck check fails and it looks exactly like a broken animation. There is now
   a guard that says so, but believe it when it fires.
2. **`Sources/main.swift` cannot be linked into any test binary.** It has top-level code, which Swift
   forbids alongside the `@main` that every test and tool declares. So the app-delegate wiring has no
   automated coverage at all, by construction.
3. **Never add `.moveToActiveSpace` to the orb's collection behaviour.** With `.canJoinAllSpaces` it
   raises `NSInternalInconsistencyException` and kills the app. A smoke check asserts its absence.
4. **`window.animator().setFrameOrigin(_:)` is silently swallowed** on this kind of panel. Use
   `setFrame(_:display:)`. This once made a whole shipped feature dead while 340 checks stayed green.
5. **Find windows in tests by being *new*, not by title.** Windows stay in `NSApp.windows` after
   `orderOut`, with the same title. Matching on title has twice made a test fire a control belonging
   to a *different* controller.

## Rules that must not be broken

`ai/INVARIANTS.md` carries all of them with reasons. All five files under `ai/` exist —
`ARCHITECTURE.md`, `GEOMETRY.md`, `GOTCHAS.md`, `INVARIANTS.md`, `PENDING.md`. An earlier revision
of this document said three of them were unwritten; that stopped being true on 2026-09-22.

The two absolute rules:

- **Chakra never triggers a permission prompt.** No Accessibility, no Screen Recording, no
  Automation. **Two API choices in the app** exist only to honour this — Carbon
  `RegisterEventHotKey` in `Sources/HotKey.swift`, and a *local* event monitor in
  `Sources/SettingsWindow.swift`. If you reach for `NSEvent.addGlobalMonitorForEvents` or
  AppleScript, stop.

  A third avoidance — `pkill -x Chakra` rather than AppleScript — lives in `build.sh --install`
  and is **not app behaviour**. `pkill` appears nowhere in `Sources/`. The app never terminates
  anything; a second launch detects the first over `DistributedNotificationCenter` and exits
  (`Sources/main.swift`). Earlier revisions of this file and of `BUILD-CHAKRA.md` described it
  as one of three app-level choices, which was wrong.
- **Zero warnings.** All six scripts use `-warnings-as-errors`, so a warning is a build failure. An
  unused `let` in a test will fail the build.

## Where to look

| File | For |
|---|---|
| `ai/ARCHITECTURE.md` | What every type owns, and how a click becomes a launched app |
| `ai/GEOMETRY.md` | Diagrams of the wheel and orb, with every real number |
| `ai/INVARIANTS.md` | What must stay true, and what breaks if it does not |
| `ai/GOTCHAS.md` | Traps, with the evidence that each is real |
| `ai/PENDING.md` | What is unfinished, and who can finish it |
| `BUILD-CHAKRA.md` | The full 1,500-line record: every decision, failure and resolution |
| `GIT-COMMANDS.md` | How to publish this folder to GitHub, with every check inlined and measured |

**`BUILD-CHAKRA.md`, `Chakra_drag_brainstroming.md` and `docs/superpowers/` are dated records, not
current state.** Their numbers were true on the day they were written. Do not "correct" them to
match today — that would erase the history of how the project moved. `CLAUDE.md`, `README.md`,
`ai/` and `GIT-COMMANDS.md` are the files that must describe the present.

## How work has been done here, and why to keep doing it

This project's defects were found by **compiling small probe programs and by breaking tests on
purpose**, not by reading code. Sixty such probes survive in `/tmp`. Half were written by independent
reviewers.

Two habits are worth keeping because both caught real bugs that review had missed:

- **Write a probe.** When you are unsure what an AppKit call actually does, compile ten lines and
  measure it. Three confident assumptions in this project turned out to be wrong, and each was a real
  shipped defect.
- **Prove a new check can fail.** Break the code it covers, read the failure text, restore. A check
  whose failure you have never witnessed is not yet a check. One test here could only ever pass — it
  asserted a slider's midpoint value, and the midpoint of 36…76 is 56, exactly the shipped default.

## State of the repository

**No identity is baked into this tree.** `user.name` and `user.email` are deliberately not
configured, and no author was ever invented. If you are asked to commit and `git config user.name`
comes back empty, stop and ask for a name and email — do not guess either from the machine account.

`GIT-COMMANDS.md` is the publishing runbook. It is self-contained: every check it asks for, and the
measured value that check should produce, is written inside it. Follow it rather than improvising.

Ignored and regenerable: `build/` (all binaries and the DMG), `Resources/*.icns` (rebuilt by
`build.sh` from `Tools/MakeIcon.swift`), `.DS_Store`, `probe-*`, `brag-output/`, and
`.superpowers/brainstorm/` — that last one holds a bearer token and must never be committed.

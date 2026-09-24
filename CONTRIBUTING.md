# Contributing to Chakra

Thanks for looking. This project has a few unusual rules. They exist because each one
caught a real shipped defect, and the reasons are given so you can judge them rather than
just obey them.

## Getting set up

There is nothing to install. No package manager, no project file, no third-party code.

```bash
git clone https://github.com/RudraMind/Chakra-Mac.git
cd Chakra
./build.sh          # → build/Chakra.app
./run-tests.sh      # 2,136 checks
```

You need macOS 14 or later and the Xcode command line tools (`xcode-select --install`).
Six shell scripts drive `swiftc` directly.

> **Apple silicon is currently required to run the tests.** `build.sh` builds a universal
> binary, but `run-tests.sh`, `run-smoke.sh`, `render-preview.sh`, `make-icon.sh` and
> `dump-icons.sh` all hardcode `-target arm64-apple-macos14.0`. On an Intel Mac they compile a
> binary that cannot execute. The app itself runs fine on Intel — only the test tooling is
> affected. A patch replacing those five hardcoded targets with the host architecture would be
> a welcome first contribution.

## The four rules that are not negotiable

### 1. Zero warnings

All six build scripts pass `-warnings-as-errors`. A warning is a build failure. An unused
`let` in a test will stop the build. Do not add a suppression flag — fix the warning.

### 2. Chakra never triggers a macOS permission prompt

No Accessibility. No Screen Recording. No Automation. Two API choices in the app exist only
to honour this:

| The obvious call | What Chakra uses | Where |
|---|---|---|
| `NSEvent.addGlobalMonitorForEvents` | Carbon `RegisterEventHotKey` | `Sources/HotKey.swift` |
| A global monitor to record a shortcut | A **local** monitor | `Sources/SettingsWindow.swift` |

A third avoidance lives in `build.sh --install`, which uses `pkill -x Chakra` rather than
AppleScript to replace a running copy. That is a build-script convenience, **not** app
behaviour — the app never quits anything. A second launch notices the first over
`DistributedNotificationCenter` and exits (`Sources/main.swift`). Do not cite it as an app
guarantee.

If a change would introduce a permission prompt, it will be declined regardless of how
useful the feature is. Please raise an issue first so nobody wastes an afternoon.

### 3. No dependencies

No SwiftPM, no CocoaPods, no vendored code. The app icon is **generated** by `make-icon.sh`
from `Tools/MakeIcon.swift` rather than drawn by hand — though the generated
`Resources/Chakra.icns` is committed, so you do not need to build it. Adding a dependency is
a design change, not an implementation detail — open an issue.

### 4. Prove a new check can fail

A test whose failure you have never witnessed is not yet a test. Before you submit one:

1. Break the code it covers
2. Read the failure message
3. Restore the code

This is not ceremony. One test in this project could only ever pass — it asserted a
slider's midpoint value, and the midpoint of 36…76 is 56, which was exactly the shipped
default. It ran green for weeks while testing nothing.

## The habit that found most of the bugs here

**Write a probe.** When you are unsure what an AppKit call actually does, do not read the
documentation and guess. Compile ten lines into `/tmp` and measure it.

Three confident assumptions in this project turned out to be wrong, and each one was a real
shipped defect. The sharpest example: `window.animator().setFrameOrigin(_:)` is *silently
swallowed* on this kind of panel. That one made an entire shipped feature dead while 340
checks stayed green. `setFrame(_:display:)` works.

## Testing

| Command | What it is | Needs a screen? |
|---|---|---|
| `./run-tests.sh` | 2,136 pure-logic checks | No |
| `./run-smoke.sh` | 558 checks that build real windows | **Yes, unlocked** |
| `./render-preview.sh` | Renders the wheel to PNG | No |

**`run-smoke.sh` fails completely on a locked screen.** The window server refuses to move
windows, so every orb-tuck check fails and it looks exactly like a broken animation. There
is a guard that says so. Believe it when it fires.

The test framework is hand-rolled (`Tests/TestMain.swift`), **not XCTest** — XCTest needs
Xcode, and this project deliberately builds with `swiftc` alone.

### Two traps in the test suite

- **`Sources/main.swift` cannot be linked into any test binary.** It has top-level code,
  which Swift forbids alongside the `@main` that every test and tool declares. So the
  app-delegate wiring has no automated coverage at all, by construction. Changes there must
  be checked by hand.
- **Find windows by being *new*, not by title.** Windows stay in `NSApp.windows` after
  `orderOut`, with the same title. Matching on title has twice made a test fire a control
  belonging to a different controller.

## Submitting a change

1. Open an issue first for anything beyond a small fix. It is cheaper to disagree about a
   plan than about a diff.
2. Branch from `main`.
3. `./build.sh && ./run-tests.sh` must both pass. Run `./run-smoke.sh` too if your change
   touches windows, and say in the PR whether you did.
4. Explain **why**, not just what. The rejected alternatives are usually the interesting
   part.
5. Match the surrounding code's comment density and naming. Comments here explain *why* a
   non-obvious choice was made, and several cite the evidence for it.

## Where to read before changing anything

| File | For |
|---|---|
| `CLAUDE.md` | The short orientation. Start here. |
| `ai/ARCHITECTURE.md` | What every type owns, and how a click becomes a launched app |
| `ai/GEOMETRY.md` | Every real number in the wheel and orb, with diagrams |
| `BUILD-CHAKRA.md` | The complete record — every decision, failure and resolution |

## Reporting a bug

Use the issue template. Please include your macOS version and which script failed, with
its actual output. "It does not work" cannot be acted on; a pasted failure can.

# What this changes

<!-- One or two sentences. What behaviour is different after this? -->

# Why

<!--
The interesting part. What problem does this solve, and what did you reject on the way?
If you tried an approach that did not work, say so — that is often more useful than the
approach that did.
-->

# Verification

Paste the real output, not a summary.

```
$ ./build.sh

$ ./run-tests.sh

```

- [ ] `./build.sh` passes with **zero warnings** (all scripts use `-warnings-as-errors`)
- [ ] `./run-tests.sh` passes — **2,136 checks**
- [ ] `./run-smoke.sh` run at an unlocked screen — **558 checks** — or N/A because this
      change does not touch windows
- [ ] If I added a test, I **broke the code it covers, watched it fail, and restored it**.
      A check whose failure has never been witnessed is not yet a check.

# The four rules

- [ ] Introduces **no macOS permission prompt** — no Accessibility, Screen Recording, or
      Automation. In particular, no `NSEvent.addGlobalMonitorForEvents` and no AppleScript.
- [ ] Adds **no dependency** — no SwiftPM, no third-party code
- [ ] Adds **no networking**
- [ ] Comments explain **why**, matching the density and style of the surrounding code

# If this touches windows or the orb

- [ ] I did not add `.moveToActiveSpace` to the orb's collection behaviour. With
      `.canJoinAllSpaces` it raises `NSInternalInconsistencyException` and kills the app;
      a smoke check asserts its absence.
- [ ] I used `setFrame(_:display:)` rather than `window.animator().setFrameOrigin(_:)`,
      which is silently swallowed on this kind of panel.
- [ ] Any test that finds a window does so by the window being **new**, not by its title.
      Windows stay in `NSApp.windows` after `orderOut`, with the same title.

# If this touches geometry

- [ ] New numbers are **derived from existing constants**, not hardcoded, so that changing
      a slot count fails the build instead of shipping overlapping icons
- [ ] `ai/GEOMETRY.md` updated if any constant changed

# Notes for the reviewer

<!-- Anything you are unsure about, or would like a second opinion on. -->

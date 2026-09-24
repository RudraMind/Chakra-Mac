# Changelog

All notable changes to Chakra are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Chakra
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.0] — 2026-09-24

First public release.

### Added

**The wheel**
- A two-ring radial launcher. The outer ring holds 4–10 apps you pin, at fixed positions so
  a slot's place is learnable. The inner ring holds 0–7 recently used apps.
- Indices run clockwise from twelve o'clock. Both rings can be turned by scrolling and stay
  where you leave them; rotation is stored as whole slots, never as an angle.
- Opens at the pointer, at a saved spot, or at the centre of the screen.
- Keyboard control: `1`–`8`, arrow keys, `Return`, `Esc`.
- Click an app to launch it, `⌥`-click to quit it, right-click an outer app to remove it.
- Drag an inner app onto an outer slot to pin it there.
- Drag the hole in the middle to move the whole wheel.

**The orb**
- A 56pt disc that floats above every app, on every Space, and over full-screen apps.
- Drag it anywhere. Leave it near a screen edge and it slides 62% off, leaving a sliver.
- The dots on its face are the dominant colours of the apps on the outer ring, in ring
  order, with slot 0's dot drawn larger so the orb shows which way is up.
- Can be hidden from screen recordings.

**Ways in**
- A configurable global shortcut, `⌥Space` by default.
- Clicking the orb.
- Clicking the menu-bar icon.
- Dragging an app onto the orb or the menu-bar icon adds it to the first free slot.

**Settings**
- Nineteen user-adjustable settings: ring sizes, wheel size, glass opacity and tint, where the
  wheel opens, the shortcut, orb visibility and size and idle dimness, edge tucking, and more.
- Every setting is clamped and type-checked on read, and `isFinite` is checked *before*
  clamping, so a corrupted preferences file cannot produce a broken window.

### Design constraints honoured

- **No macOS permission prompts.** No Accessibility, Screen Recording, or Automation.
  Achieved through two deliberate API choices in the app — Carbon `RegisterEventHotKey`
  instead of a global `NSEvent` monitor, and a local monitor when recording a shortcut. A
  third avoidance, `pkill` instead of AppleScript, is in `build.sh --install` rather than in
  the app.
- **No dependencies and no project file.** Six shell scripts drive `swiftc` directly and
  assemble the `.app` bundle by hand. The app icon is **generated** from Swift source by
  `make-icon.sh` rather than hand-drawn — note that the generated `Resources/Chakra.icns`
  is committed, so a fresh clone does not need to regenerate it.
- **No networking.** No analytics, no crash reporting, no licence check, no update check.
- **Zero warnings.** All six build scripts use `-warnings-as-errors`.
- **The outer ring always keeps at least 3 apps.** A removal that would drop below three is
  refused and the Clear buttons grey out.

### Testing

- 2,136 pure-logic checks (`./run-tests.sh`), no window server required.
- 558 smoke checks that build real windows (`./run-smoke.sh`, needs an unlocked screen).
- The test framework is hand-rolled rather than XCTest, because XCTest requires Xcode.
- CI runs the build, the logic checks, the preview renderer, and the disk-image packaging on
  every push. It deliberately does **not** run the smoke suite: a runner has no unlocked
  screen, so every window check would fail and look like a broken animation.

### Distribution and provenance

- **Downloads as `Chakra.dmg`** — open it and drag the app onto the `Applications` shortcut.
  The file name carries no version so the link never changes; the *volume* name does, so
  mounting an old copy still identifies it.
- **Sigstore build attestation** on every release, produced by `actions/attest`. A downloader
  can prove the disk image was built by this repository from a specific commit:
  `gh attestation verify Chakra.dmg --repo RudraMind/Chakra-Mac`. The release workflow verifies its
  own attestation before publishing, so a mismatched digest fails the build instead of
  reaching a user.
- **Signed commits and signed release tags** where the maintainer has set signing up. This is
  documented and recommended in the ship runbook but not enforced by CI, so do not assume
  every commit carries a signature — check for the Verified badge rather than trusting this
  line.
- [`VERIFYING.md`](VERIFYING.md) documents all of it, including what cannot be proven.

### What deliberately is not offered

- **No notarization, and therefore no verified name in the app bundle.** `codesign` reports
  `Signature=adhoc` and `TeamIdentifier=not set`. macOS blocks the first launch and says it
  cannot check the app — which is accurate. Only a paid Apple Developer ID changes this.
- **No network access of any kind**, so no update checks, no analytics, no licence checks.

### Known limitations

- **Ad-hoc signed, not notarized.** macOS blocks the first launch with a warning that it
  cannot check the app. Because the signature is ad-hoc, macOS treats every rebuild as a
  different program, so an "Open at login" registration needs re-approving after each
  build. A paid Apple Developer ID is the only fix.
- **`Sources/main.swift` has no automated coverage**, by construction — it contains
  top-level code, which Swift forbids alongside the `@main` that every test binary declares.
- **`Sources/StatusItem.swift` has no automated coverage.** Menu-bar behaviour rests on
  manual use.
- **The physical Finder drag is not covered.** Everything the orb decides once a drag
  arrives *is* covered, via a stub `NSDraggingInfo`; the drag leaving Finder is not.
- Four modal actions are skipped in the smoke suite because `runModal` blocks forever with
  nobody to click.

[Unreleased]: https://github.com/RudraMind/Chakra-Mac/compare/v1.0...HEAD
[1.0]: https://github.com/RudraMind/Chakra-Mac/releases/tag/v1.0

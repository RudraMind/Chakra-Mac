# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting instead: go to the **Security** tab → **Report a
vulnerability**. That opens a private channel visible only to the maintainer.

If private reporting is unavailable, open a public issue saying only *"security report,
please provide a contact"* — with no details — and a private channel will be arranged.

Expect an acknowledgement within a week. This is a single-maintainer hobby project, not a
funded one; please be patient and set your disclosure timeline accordingly.

## What Chakra's design guarantees

These are the properties a security reviewer would most want to know. Each is verifiable
from the source in this repository.

### It requests no macOS permissions

Chakra never asks for Accessibility, Screen Recording, Automation, Input Monitoring, or
Full Disk Access. This is an architectural rule, not a current happenstance — **two API
choices in the app** exist only to preserve it:

- Carbon `RegisterEventHotKey` for the global shortcut (`Sources/HotKey.swift`), instead of
  `NSEvent.addGlobalMonitorForEvents`, which would make macOS demand Accessibility.
- A **local** event monitor when recording a shortcut (`Sources/SettingsWindow.swift`),
  because the app is frontmost anyway.

A third avoidance exists in the **build script**, not the app: `build.sh --install` uses
`pkill -x Chakra` to replace a running copy rather than AppleScript. Stated precisely because
it has been described elsewhere as app behaviour and is not — the app never terminates
anything. A second launch detects the first via `DistributedNotificationCenter` and exits
(`Sources/main.swift`).

Verify the absence yourself:

```bash
grep -rn "addGlobalMonitorForEvents\|NSAppleScript\|osascript\|CGEventTap" Sources/
```

The only hit is a comment in `Sources/HotKey.swift` naming the API that is deliberately *not*
used. There is no entitlements file, and `codesign -d --entitlements -` on a built bundle
returns none.

One thing not previously documented, for a privacy-minded reader: `Sources/Recents.swift`
reads `kMDItemLastUsedDate` via `MDItemCreate` for applications in a few fixed directories, to
rank recents. That needs no permission and transmits nothing, but it does read app-usage
timestamps locally.

If you find a code path that could cause a permission prompt, that is a bug worth
reporting.

### It makes no network connections

There is no networking code in this project. No `URLSession`, no sockets, no analytics, no
crash reporting, no licence check, no update check. The only frameworks imported are
`AppKit`, `Carbon`, `CoreGraphics`, `CoreServices`, `Foundation`, `ServiceManagement`, and
`UniformTypeIdentifiers` — all of which ship with macOS.

You can confirm this yourself:

```bash
grep -rniE "URLSession|NSURLConnection|http://|https://|CFSocket" Sources/ Tools/
```

That returns nothing.

### It has no dependencies

No SwiftPM, no CocoaPods, no vendored third-party code. The supply-chain surface is macOS
itself. Everything in `Sources/` is in this repository and readable.

### What it stores, locally, in full

The app writes to `UserDefaults.standard`, whose domain is its bundle identifier
`local.chakra`. (`UserDefaults(suiteName:)` appears in the source only for `--demo` mode and
the smoke-test harness, which use throwaway domains.)

**30 preference keys in total.** The three groups below are subsets of that 30, not additions
to it:

| Group | Count | What |
|---|---|---|
| Your data | 2 | the pinned outer ring (up to 10 app paths) and the recents list (up to 40 app paths) |
| User-adjustable settings | 19 | ring sizes, wheel size, glass opacity and tint, the shortcut, orb options, and so on |
| Internal state | 9 | whether onboarding has run, saved wheel position, ring rotation, and which display the orb sits on |

**No file contents. No documents. Nothing leaves the machine.** Every value is clamped and
type-checked on read, so a hand-edited or corrupted preferences file cannot produce a broken
window or an out-of-range value. One exception, named for accuracy: `orbDisplayName` is read
as an unbounded string with no clamp, because it is only ever used as a label.

### Two local reads worth disclosing

Neither needs a permission and neither transmits anything, but a privacy-minded reader should
know they happen:

- **`Sources/Recents.swift`** reads `kMDItemLastUsedDate` via `MDItemCreate` for applications
  in a few fixed directories, to rank the recents ring. That is app-usage timestamps, read
  locally.
- **`Sources/Proposal.swift`** reads the `com.apple.dock` preference domain on first run, to
  suggest which apps to pin. Reading another application's preferences file requires no
  permission on macOS.

## Code signing and provenance — read this before you install

> **[`VERIFYING.md`](VERIFYING.md) is the practical companion to this section**: four levels
> of checking, in plain terms, with the exact commands.

**Chakra is ad-hoc signed, not notarized.** Notarizing requires a paid Apple Developer
account, which this project does not have. Measured on a real build:

```
$ codesign -dvvv build/Chakra.app 2>&1 | grep -E "Signature|TeamIdentifier|Authority"
Signature=adhoc
TeamIdentifier=not set
```

(`codesign` writes all sixteen lines of its output to **stderr**, so the `2>&1` is required or
the pipe shows nothing. Note there is no `Authority` line in the result at all.)

*Ad-hoc* means signed by nobody. There is no `Authority=` line, because no certificate was
used. Anyone could build a different app, ad-hoc sign it, and name it Chakra.

### What is offered instead

| Mechanism | Proves | Limit |
|---|---|---|
| **SHA-256 on each release** | the file is intact | weak alone — whoever controls the page controls both |
| **Sigstore build attestation** — `gh attestation verify Chakra.dmg --repo RudraMind/Chakra-Mac` | this disk image was built by **this repository's CI from a specific commit**; unforgeable without control of the repository | **macOS does not check it.** Only helps someone who runs the command |
| **Signed commits and signed tags** | the source and the release tag were signed by the maintainer's registered key | says nothing about the downloaded file |
| **Reproducing the build yourself** | nothing to trust at all | requires you to run `./build.sh` |

The attestation is generated by `.github/workflows/release.yml` using `actions/attest`, and
that workflow verifies its own attestation before publishing, so a mismatched digest fails the
build rather than reaching you.

**Two things this project cannot currently give you**, stated plainly rather than glossed:
a signature carrying a verified name, and Apple's own inspection. Both require the paid
Developer ID.

Consequences you should weigh:

- macOS will block the first launch and warn that it cannot check the app for malicious
  software. That warning is accurate: Apple has not checked it. You are trusting this
  repository instead.
- Because the signature is ad-hoc, macOS treats **every rebuild as a different program**.
  An "Open at login" registration therefore needs re-approving after each build.
- If you would rather not extend that trust, **build it yourself**. That is the whole
  reason the build is six readable shell scripts with no dependencies:

  ```bash
  git clone https://github.com/RudraMind/Chakra-Mac.git
  cd Chakra && ./build.sh
  ```

  Verify a downloaded release against its published SHA-256 before opening it.

## Supported versions

Only the latest release receives fixes. There are no long-term support branches.

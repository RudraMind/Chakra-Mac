# GIT-COMMANDS.md — publish Chakra to GitHub

**For a future Claude Code session, or a human.** This folder is self-contained: everything needed
to validate and publish it is inside it. Nothing here points at another directory, another machine,
or a skill that has to be installed. If a path in this file starts with `./`, it is in this folder.

> **Status: published 2026-09-24** as the public repository `RudraMind/Chakra-Mac`. Step 0's
> "commits AND a remote" row now applies — this runbook's first-publish steps are history.
> The figures below were measured on 2026-09-23, before publishing. What shipped differs:
> the six app screenshots, the two HTML mockups and their three Python generators were removed
> (they showed the owner's personal app list), and the README images were re-rendered by CI
> from apps that ship with macOS. The tree is now 83 files, 3,790,884 bytes; the largest file is
> `assets/wheel-empty.png` at 899,110 bytes; `assets/` holds 7 images. CI on `macos-15` runs
> 2136 unit checks, the preview render and the DMG build green. The 558 smoke checks were not
> re-run after publishing, because they need an unlocked Mac screen.

**This runbook is written for a FIRST PUBLISH** — a repository with zero commits and no remote.
Step 0 checks that assumption before anything else, because if someone has already committed and
pushed, several steps below would be wrong.

Every number in this file was **measured on 2026-09-23** on an Apple-silicon Mac running macOS 26
with Swift 6.3.3. Re-measure rather than trust; the commands are given so you can.

---

## Step 0 — confirm which case this is

```bash
git rev-parse --is-inside-work-tree 2>/dev/null || echo "no repo"
git rev-list --count HEAD 2>/dev/null || echo "0 commits"
git remote -v
git branch --show-current
```

Expected on a fresh copy of this folder: `true`, `0 commits`, no remote output, `main`.

| What you saw | What this job is |
|---|---|
| no repo, or 0 commits | **First publish.** Continue with this runbook as written. |
| commits, no remote | Local history exists. Skip Step 5's `git init`; add a remote instead. |
| **commits AND a remote** | **Already published.** This runbook does not apply. Stop and ask the owner whether the work should land as a pull request, a local merge, or a deferred branch. Never `git push --force`. |

---

## Step 1 — STOP and ask for five things

**Do not invent any of these. Do not guess a name from the machine account, an email from the
hostname, or an owner from the folder name.** No identity has ever been configured here, and that
is deliberate, not an oversight.

| # | Needed | Used for |
|---|---|---|
| 1 | `user.name` | every commit |
| 2 | `user.email` | every commit |
| 3 | The real GitHub owner handle | replaces the placeholder `RudraMind`. **Measured 2026-09-23: 29 occurrences across 9 files.** It is why `README.md`'s clone URL 404s today |
| 4 | The copyright holder | `LICENSE:3` reads `Copyright (c) 2026 <YOUR_NAME>`. An MIT licence with an empty holder grants nothing cleanly |
| 5 | The maintainer email | `CODE_OF_CONDUCT.md:62` reads `maintainer at <MAINTAINER_EMAIL>` |

Also ask **public or private**. Recommend private for the first push — see Step 6 for why that is
not just caution.

Then, and only then:

```bash
git config user.name  "<the name they gave>"
git config user.email "<the email they gave>"
```

**Set these per repository, not `--global`.** This machine has no global identity and that is a
reasonable state to leave it in.

---

## Step 2 — fill the placeholders in, then prove they are gone

```bash
export OWNER="<the GitHub handle>"
export HOLDER="<the copyright holder>"
export MAINT="<the maintainer email>"

# Owner handle. Uses | as the delimiter because the value can appear inside URLs.
grep -rlI "RudraMind" . --exclude-dir=.git \
  | while IFS= read -r f; do sed -i '' "s|RudraMind|$OWNER|g" "$f"; done

sed -i '' "s|<YOUR_NAME>|$HOLDER|g" LICENSE
sed -i '' "s|<MAINTAINER_EMAIL>|$MAINT|g" CODE_OF_CONDUCT.md
```

Now verify. **This check passes by finding nothing, so it needs a positive control** — a search for
a string you know is there. Without the control, a broken command reports "clean" and you believe it.

```bash
# THE CHECK — expect 0
/usr/bin/grep -rIE "RudraMind|<YOUR_NAME>|<YOUR_EMAIL>|<GITHUB_USERNAME>|<MAINTAINER_EMAIL>" \
  . --exclude-dir=.git --exclude=GIT-COMMANDS.md | wc -l

# THE CONTROL — must be greater than 0. If this is also 0, the command above is broken.
/usr/bin/grep -rlI "Chakra" . --exclude-dir=.git | wc -l     # measured 2026-09-23: 55 files
```

`GIT-COMMANDS.md` is excluded from the check because this very file *documents* the placeholder
strings, so it will always match a search for them. That is a false positive, not a finding.

> **Why `/usr/bin/grep` and not `grep`?** Inside some agent environments — Claude Code among them —
> `grep` is a shell function routing to `ugrep` with `--ignore-files` and `-I`. Those flags make it
> **silently skip gitignored paths and binary files**, which is exactly wrong for a security sweep.
> Run `type grep`; if it says "shell function", use the absolute path. Every sweep in this file does.

Two files also *describe* the placeholders in prose rather than containing live ones —
`ai/PENDING.md:15-16` and `Chakra_drag_brainstroming.md:166-167`. The `sed` above rewrites them too,
which is harmless, but do not be alarmed when a historical note changes.

---

## Step 3 — prove the tree is green before touching git

Run all three from this folder. **Do not proceed if a number differs** — investigate instead,
because a drifted tree means something changed that nobody recorded.

| Command | Measured 2026-09-23 | Needs an unlocked screen? |
|---|---|---|
| `./run-tests.sh` | **`✓ 2136 checks passed`**, exit 0 | No |
| `./run-smoke.sh` | **`✓ 558 smoke checks passed`**, exit 0 | **Yes** |
| `./build.sh` | `built build/Chakra.app`, exit 0, zero warnings | No |
| `./make-dmg.sh` | `build/Chakra.dmg`, **1,003,444 bytes**, exit 0 | No |

`run-smoke.sh` **hard-fails on a locked screen.** The window server refuses to move windows, so
every orb-tuck check fails and it looks exactly like a broken animation. There is a guard that says
so; believe it when it fires. The suite also takes over the display for about 40 seconds — tell the
human before you start it.

**Do not run `./build.sh --install`.** It needs `sudo` and fails partway, leaving the run aborted.

Every script uses `-warnings-as-errors`, so a warning is a build failure. The CI runner's Swift is
older than a current local toolchain, so warning-free here does not guarantee warning-free there.
That is the main reason Step 6 says push private first.

### What a fresh machine needs

No third-party dependencies. No `Package.swift`, no `.xcodeproj`, no SwiftPM, no CocoaPods. Every
tool is Apple-supplied and arrives with Xcode or the Command Line Tools:

```bash
for t in swiftc lipo iconutil hdiutil codesign sips plutil git; do
  printf '%-10s %s\n' "$t" "$(command -v $t || echo MISSING)"
done
ls /usr/libexec/PlistBuddy
command -v gh || echo "gh MISSING — see Step 5 for the browser fallback"
```

Deployment target is `macos14.0` in Swift 5 language mode. `gh` is the only thing that may be
missing, and Step 5 gives a path that does not need it.

---

## Step 4 — the 27 validation checks, inlined

These are here rather than in a separate file on purpose: a runbook that says "follow the project's
validation list" becomes a dead pointer the moment this folder is copied somewhere else.

**Rule 0: any check that passes by finding nothing gets a positive control.** Every one below has
one. A blank result is an unrun check, not a pass.

### A — what is in the commit

```bash
# A1  baseline: file count and total size.  git add -An is a DRY RUN and mutates nothing.
git add -An | sed "s/^add '//;s/'$//" > /tmp/chakra-files.txt
wc -l < /tmp/chakra-files.txt                       # measured: 88 (89 once this file is counted)
tot=0; while IFS= read -r f; do
  tot=$((tot + $(stat -f%z "$f" 2>/dev/null || echo 0))); done < /tmp/chakra-files.txt
echo "$tot bytes"                                   # measured: 5,800,790 bytes = 5.5 MiB

# A2  nothing over 100 MiB — a hard stop, GitHub refuses such a file outright.  Expect silence.
while IFS= read -r f; do
  sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
  [ "$sz" -gt 104857600 ] && echo "BLOCKED: $f is $sz bytes"
done < /tmp/chakra-files.txt
# CONTROL: same loop at threshold 0 must print every file. If it prints nothing the loop is broken
# and the silence above meant nothing.
while IFS= read -r f; do
  sz=$(stat -f%z "$f" 2>/dev/null || echo 0); [ "$sz" -gt 0 ] && echo "$f"
done < /tmp/chakra-files.txt | wc -l                # must equal A1's count

# A3  anything over 1 MB should be deliberate.  Measured: nothing exceeds 1 MB.
#     Largest four: rotation-demo.html 980,608 · assets/wheel-empty.png 899,110 ·
#     orb-mockup.html 514,523 · BUILD-CHAKRA.md 93,338.  The two HTML files are generated
#     design mockups kept as a record; they are intentional.

# A4  the big regenerable directory is ignored
git check-ignore -v build                           # expect: .gitignore:4:build/
git check-ignore -v build/Chakra.dmg                # expect: same rule — the DMG ships as a
                                                    # release asset, never as a commit

# A5  no rule shadows a file that must ship
grep -c '^assets/' /tmp/chakra-files.txt            # expect 8 — the README images
# .gitignore:2-3 documents why assets/ is deliberately NOT ignored

# A6  no nested repository copied in
find . -name .git -not -path ./.git                 # expect empty
# (.superpowers/sdd/.gitignore is a nested *gitignore*, not a nested repo. That is fine.)
```

### B — what must not be public

```bash
files=(); while IFS= read -r f; do files+=("$f"); done < /tmp/chakra-files.txt

# B1  credentials
/usr/bin/grep -nIE -- "-----BEGIN|password[=:]|secret[=:]|token[=:]|api[_-]?key[=:]|ghp_" "${files[@]}"
# Expected: only .github/workflows/release.yml lines 23 and 29, `id-token: write`. That is a
# GitHub OIDC permission for Sigstore provenance, not a secret. Everything else is a finding.

# B1b  the specific secret this project has had: a 64-hex bearer key
/usr/bin/grep -nIE -- "\b[0-9a-f]{64}\b" "${files[@]}"        # expect ZERO
# CONTROL
/usr/bin/grep -lI "Chakra" "${files[@]}" | wc -l              # measured: 55 files

# B2  absolute home paths
/usr/bin/grep -nI -- "/Users/\|/home/" "${files[@]}"
# Expected: 6 hits, every one a SYNTHETIC test fixture or doc example, not a real path —
#   Tests/ModelTests.swift:252,257 and Tests/RecentsTests.swift:45,56  → /Users/someone
#   Tests/ProposalTests.swift:94                                       → /Users/me
#   VERIFYING.md:63                                                    → /Users/you
# CONTROL
/usr/bin/grep -lI "build/" "${files[@]}" | wc -l              # measured: 25 files

# B3  the author's name, username, hostname or personal email
/usr/bin/grep -nIi -- "<owner real name>\|<machine username>" "${files[@]}" # expect ZERO before Step 2,
                                                              # and only the values the owner
                                                              # supplied after it
# CONTROL
/usr/bin/grep -lI "macOS" "${files[@]}" | wc -l               # measured: 44 files
```

**B4 — the sweep must not match itself.** `GIT-COMMANDS.md` contains every pattern above as literal
text. Exclude it, and say in your report that you did, or the next reader chases a ghost.

**B5 — read the tracked instruction files.** `CLAUDE.md`, `CONTRIBUTING.md` and `ai/PENDING.md` all
ship. Confirm none of them contradicts the act of publishing and none states a figure that is now
wrong. Both faults were real here and are fixed: `CLAUDE.md` used to assert *"Zero commits… nothing
has ever been committed"* (false the instant you commit) and used to claim *1,712 checks* (the real
figure is 2136).

### C — does the repository tell the truth

**C1 — README claims match the code.** Re-verify these three, all previously wrong here:

```bash
# The icon: README says "generated, not committed". That is TRUE only while the ignore rule stands.
git check-ignore -v Resources/Chakra.icns     # expect: .gitignore:32:Resources/*.icns
grep -c 'Chakra.icns' /tmp/chakra-files.txt   # expect 0 — it must NOT be in the commit

# The permission promise, which is the project's first invariant
nm -u build/Chakra.app/Contents/MacOS/Chakra | \
  grep -ciE "AXUIElement|CGWindowListCreateImage|CGRequestScreenCapture|NSAppleScript"
                                              # expect 0
grep -c UsageDescription Info.plist           # expect 0
```

**C2 — versions agree.** `Info.plist` carries `1.0` for both `CFBundleShortVersionString` and
`CFBundleVersion`; `CHANGELOG.md` heads its top section `[1.0] — not yet released`; `make-dmg.sh:46`
reads the version out of `Info.plist` rather than hardcoding one. One source of truth. Bump
`Info.plist` and the CHANGELOG together, never one alone.

**C3 — no unfilled placeholders.** This is Step 2's check. Also sweep `TODO`, `FIXME`, `XXX`:
measured zero in `Sources/` and `Tools/`.

**C4 — every number quoted in a doc is current.** The unit and smoke counts appear in nine
shippable files. After any code change, re-measure and update all nine:

```bash
/usr/bin/grep -rnIE -- "2,136|558 (smoke )?checks" \
  README.md CLAUDE.md CONTRIBUTING.md CHANGELOG.md ai/PENDING.md \
  release/RELEASE-NOTES.md .github/PULL_REQUEST_TEMPLATE.md \
  .github/workflows/ci.yml .github/workflows/release.yml
```

This check has failed twice in this project's history — once at 396-vs-422, once at 1,712-vs-2136.
It fails silently, because a stale number looks exactly like a fresh one.

**Six tracked files are deliberately excluded from C4 and from C5, and must stay excluded:**
`BUILD-CHAKRA.md`, `Chakra_drag_brainstroming.md`, and the four files under `docs/superpowers/`.
They are **dated engineering records** — a log of what was measured, decided and got wrong on a
given day. `BUILD-CHAKRA.md` quotes 1,712 because 1,712 was the true figure when that entry was
written. Rewriting a historical log to match today's numbers would destroy the only record of how
the project actually moved, and would make every one of its "this turned out to be wrong" entries
incoherent. Treat a stale number in them as **correct history**, not as a defect. C4 applies only
to documents that describe the *present* state.

**C5 — status claims are current.** `ai/PENDING.md` once listed five documentation defects as "still
open" ninety lines below the section that recorded four of them as fixed. If you fix something,
delete the open item; do not leave both.

### D — does it survive leaving this machine

```bash
ls -l *.sh                                    # D1  all 7 must be -rwxr-xr-x
find . -type l -not -path './.git/*'          # D2  expect empty; nothing to preserve
tr 'A-Z' 'a-z' < /tmp/chakra-files.txt | sort | uniq -d   # D3  expect empty
# D3 matters because macOS is case-insensitive and a Linux or CI checkout is not.
cnt=0; while IFS= read -r f; do
  case "$f" in *.png|*.html|*.icns) continue;; esac
  /usr/bin/grep -qI $'\r' "$f" 2>/dev/null && { echo "CRLF: $f"; cnt=$((cnt+1)); }
done < /tmp/chakra-files.txt; echo "crlf=$cnt"            # D4  expect 0
grep ' ' /tmp/chakra-files.txt                            # D5  expect empty
```

### E — can it actually be published

- **E1** Identity decided and set `--local` — Step 1.
- **E2** Remote empty, or the owner has chosen how to reconcile. On a first publish, create the
  repository with **no** README, **no** .gitignore and **no** licence, so there is nothing to
  reconcile. If GitHub rejects the push, **stop and ask.** Never `--force`.
- **E3** `gh` present, or use the browser fallback in Step 5. Both are written down.
- **E4** A release has something to attach: `./make-dmg.sh` produces `build/Chakra.dmg`. Rebuild it
  from the exact commit you tag — a stale DMG is worse than none, because it looks current.
- **E5** CI targets macOS: `ci.yml:19` and `release.yml:35` are both `runs-on: macos-15`, valid and
  free on public repositories.
- **E6** Signing friction stated, not hidden. Measured:
  ```
  codesign -dv build/Chakra.app   →  Identifier=local.chakra
                                     Signature=adhoc
                                     TeamIdentifier=not set
  spctl --assess --type execute   →  rejected  (exit 3)
  ```
  **This is expected and documented, not a defect.** Ad-hoc signing is valid but not notarized, so
  Gatekeeper blocks first launch. `README.md:187-200`, `VERIFYING.md` and
  `release/RELEASE-NOTES.md` all describe the real dialog — titled `"Chakra" Not Opened`, with only
  **Done** and **Move to Trash**, no Open button — and the `Open Anyway` route in System Settings,
  which **expires after about an hour**. Apple removed the old Control-click bypass in macOS 15, so
  do not reintroduce that advice.

### Verdict format

State it in one of these forms and nothing looser. Do not write "looks good" or "mostly ready".

```
READY TO PUBLISH — 27/27 passed
NOT READY — failing: C1, E4
NOT READY — failing: C1; unverified: E2
```

Four states, not interchangeable: **passed** (ran it, came back good), **failed** (ran it, came back
bad), **unverified** (could not run it, or the answer is the owner's), **n/a** (does not apply, with
a one-clause reason). **Any unverified check blocks `READY TO PUBLISH`.**

---

## Step 5 — create the repository and make the first commit

Create an **empty** repository named `Chakra`. No README, no .gitignore, no licence — every box
unchecked, so the first push has nothing to reconcile.

```bash
gh repo create "$OWNER/Chakra" --private --source=. --remote=origin
```

If `gh` is missing: `brew install gh && gh auth login`, or open `https://github.com/new` in a
browser, create it empty, then:

```bash
git remote add origin "https://github.com/$OWNER/Chakra.git"
```

Then commit. **Read `git status` twice.** There is no second chance on a secret: once committed, it
stays in history even if the file is deleted in a later commit.

```bash
git init                 # skip if Step 0 said the repo already exists
git branch -M main
git status               # read it properly
git add -A
git status               # read it AGAIN — confirm no token, no build/, no .icns, no .DS_Store
git commit -m "Initial commit: Chakra, a radial application launcher for macOS

A two-ring wheel of application icons plus an always-on-top orb, in Swift and
AppKit with no third-party dependencies. The app triggers no macOS permission
prompt by design; three API choices exist only to honour that.

Verified at this commit: 2136 unit checks, 558 smoke checks, a zero-warning
universal build, and no gated symbols in the linked binary."
```

Because there is no prior commit, the first one is the whole tree. Expect **88 files** and about
5.5 MiB.

---

## Step 6 — push, private first

```bash
git push -u origin main
```

**Push to a private repository and watch the CI run before making anything public.** This is not
generic caution. The GitHub runner's Swift is older than a current local toolchain and all seven
scripts use `-warnings-as-errors`, so a construct that is warning-free here can be a hard build
failure there. Finding that out on a public repository means a red badge on a first impression.

Two known-fragile spots, deliberately left as they are:

- `build.sh:79` makes ad-hoc signing **non-fatal**, and `ci.yml:40` only *prints* the signature. CI
  can therefore go green on an unsigned bundle while `VERIFYING.md` promises `Signature=adhoc`. A
  `grep -q 'Signature=adhoc'` in the workflow closes it.
- `ci.yml:92` `actions/upload-artifact@v7` has no `overwrite: true`. Whether a re-run collides could
  not be confirmed from GitHub's documentation.

When CI is green and the owner is happy, flip visibility:

```bash
gh repo edit "$OWNER/Chakra" --visibility public --accept-visibility-change-consequences
```

---

## Step 7 — the release

`release/RELEASE-NOTES.md` is the body. It tells people to download `Chakra.dmg`, so the DMG must
actually be attached, and it must be built from the tagged commit.

```bash
./build.sh && ./make-dmg.sh
shasum -a 256 build/Chakra.dmg     # put this in the release notes so downloads are checkable
git tag -a v1.0 -m "Chakra 1.0"
git push origin v1.0
gh release create v1.0 build/Chakra.dmg \
  --title "Chakra 1.0" --notes-file release/RELEASE-NOTES.md
```

Measured 2026-09-23: `build/Chakra.dmg` is **1,003,444 bytes**, sha256
`46038d74ad00feebfc4d1d05c443e51e5504b434364827bc95f784efc661fddc`. That hash is for the build made
on this machine on that date — recompute yours, do not copy this one into release notes.

`.github/workflows/release.yml` also produces SLSA provenance through `actions/attest@v4` with
`subject-path`, so `VERIFYING.md`'s provenance promise is genuinely honoured. `gh auth login` is
required for verification even on a public repository.

---

## The one rule that outranks everything in this file

`ai/INVARIANTS.md` §1: **Chakra never triggers a macOS permission prompt.** No Accessibility, no
Screen Recording, no Automation, no Files-and-Folders. Two API choices in the app exist only to
honour it — Carbon `RegisterEventHotKey` in `Sources/HotKey.swift`, and a *local* event monitor in
`Sources/SettingsWindow.swift` — and `Info.plist` contains **zero** `NS*UsageDescription` keys.

If a publishing step ever seems to need a prompt, that step is wrong. Re-run the evidence:

```bash
nm -u   build/Chakra.app/Contents/MacOS/Chakra    # gated symbols — expect none
otool -L build/Chakra.app/Contents/MacOS/Chakra   # linked frameworks
```

---

## Measured baseline, 2026-09-23

Everything a later run should compare against. A figure that has drifted is a signal, not a nuisance.

| Thing | Value |
|---|---|
| Files in the first commit | 88 (89 counting this file) |
| Total committed size | 5,800,790 bytes — 5.5 MiB |
| Largest committed file | `rotation-demo.html`, 980,608 bytes |
| `./run-tests.sh` | 2136 checks, exit 0 |
| `./run-smoke.sh` | 558 checks, exit 0, **unlocked screen required** |
| `./build.sh` | exit 0, zero warnings, universal binary |
| `./make-dmg.sh` | `build/Chakra.dmg`, 1,003,444 bytes |
| Signature | `Signature=adhoc`, `TeamIdentifier=not set` |
| `spctl --assess` | **rejected**, exit 3 — expected, and documented in README |
| Gated symbols in the binary | 0 |
| `NS*UsageDescription` keys | 0 |
| `RudraMind` placeholder | 29 occurrences, 9 files |
| Validation verdict at this date | `NOT READY — failing: C3; unverified: E1, E2` — all three are the owner's five answers from Step 1, and nothing else |

## What was deliberately not done, and why

- **Notarization.** Needs a paid Apple Developer ID. Ad-hoc signing is the honest alternative and
  the friction it causes is documented rather than hidden.
- **A drag-free variant.** An earlier plan called for a second copy of the tree without the shelf
  feature. Superseded on 2026-09-23 in favour of one folder; if it is ever wanted, it is a branch.
- **`FileManagerDelegate` for unreadable children** — `ai/PENDING.md` explains why adding it would
  make a folder copy's size legitimately differ from its source and trip the verified-copy check.
- **The owner's app list and the HTML mockups were removed before the first commit** (2026-09-23).
  README images are rendered by CI from apps that ship with macOS. See `ai/PENDING.md`.

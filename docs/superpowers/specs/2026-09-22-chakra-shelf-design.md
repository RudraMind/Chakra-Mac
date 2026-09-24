# Chakra Shelf — design

**Date:** 2026-09-22
**Status:** design approved, **and implemented**. Tasks 1-9 of the plan are merged and green at
1938 unit checks and 422 smoke checks; Tasks 10 and 11 (the view layer) remain. Task 12
(`NSFilePromiseReceiver`) was **deleted for v1** by owner decision — see the ledger.

Live state lives in `.superpowers/sdd/2026-09-22-chakra-shelf/progress.md`, not here. This file is
the design authority and outranks the plan; where implementation diverged from it, the divergence is
recorded in that ledger with its reason.
**Scope:** one feature. Everything here is inside it or explicitly out.

---

## 0. Vocabulary, fixed once

| Term | Means |
|---|---|
| **orb** | The 56 pt always-on-top floating disc. Already exists (`Sources/OrbView.swift`). |
| **wheel** | The two-ring launcher that opens when the orb is clicked. Already exists. |
| **hub** | The see-through hole in the middle of the wheel, radius 72 pt at scale 1. |
| **shelf** | The feature. A folder of copied files, shown in the hub, filled via the orb. |
| **item** | One entry on the shelf. A bundle or folder counts as **one** item. |

Use these words in code, comments and UI. The hub is not "the centre", the shelf is not
"the tray".

---

## 1. What this is, and what it is not

**Is:** a place to park files for minutes or hours while moving them between folders and
apps. Drag files onto the orb; they are copied into a real folder. Open the wheel to see how
many are there and how big. Drag them out to anywhere. Click the hub to open the folder in
Finder.

**Is not:** a file manager, a clipboard history, a sync service, an archive, or a place the
user is expected to keep anything permanently. It never deletes anything on its own.

**Why it earns its place in Chakra specifically:** the orb is already an always-visible,
always-on-top drop target that needs no permission and no focus. Nothing else on the Mac has
that shape. The shelf is what that shape is *for* beyond launching apps.

---

## 2. Decisions, with the reason each one was made

Every entry here was decided deliberately. Do not reverse one without reading its reason.

### 2.1 Files are copied, never referenced

The shelf owns its own copy. A reference would break the moment the source moved, and the
whole point is that the user can reorganise freely once a file is on the shelf.

**This requires active work to be true.** Measured: `FileManager.copyItem` on a symlink
**copies the link**, and on a Finder alias copies the 804-byte bookmark — and the copy still
resolves to the original. So a naive copy silently produces a reference.

**Required:** before copying, test `.isSymbolicLinkKey` then `.isAliasFileKey` (note alias is
also true for symlinks, so test symlink first) and resolve to the real target. If the target
is unreachable, refuse with the missing-file message.

### 2.2 Storage is `~/Library/Application Support/local.chakra/Shelf/`

Resolve via `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
appropriateFor: nil, create: true)` and append `local.chakra/Shelf`. **Never** string-concatenate
`NSHomeDirectory()` — that path differs under a sandbox, and Chakra is one plist key away from
that.

Measured facts behind this choice:

- `~/Library/Application Support` has **no TCC service and no Info.plist usage key** —
  confirmed against Apple's protected-resources list *and* this machine's `tccd` binary. Zero
  permission surface, which is the only way to keep `INVARIANTS.md` §1 provably intact.
- A write probe there succeeded with **no prompt and no admin**, and 62 other apps already
  use it.
- `/Library/Application Support` is `root:admin` and **not** writable without admin —
  `touch` returned `Permission denied`. Ruled out.
- On at least one target machine `~/Documents` and `~/Desktop` are **symlinks into
  `~/Library/CloudStorage/OneDrive-<organisation>/`**. A shelf there would upload every dropped
  file to the user's employer. Ruled out on privacy grounds independent of TCC.
- The bundle identifier is used rather than `Chakra` because macOS 14+ `SystemPolicyAppData`
  prompts for access to *another app's* container; being unambiguously inside our own matters.

**The API returns the parent only.** Measured: `create: false` returns paths that do not
exist (`~/Developer` came back `exists=NO`) and can throw. The per-app subfolder is never
auto-created.

### 2.3 There is no "Change shelf folder…" in v1

A user-chosen folder would be safe *in principle* — Apple documents that selecting a file in
an Open panel is implicit consent even without the App Sandbox, and WWDC 2019 session 701
states access is granted "without the need for a consent prompt".

It is rejected anyway, for three reasons:

1. **Chakra is ad-hoc signed, so it has no stable identity.** Measured: two ad-hoc builds of
   `local.chakra` produced two different designated requirements, each only a cdhash. Apple's
   TN3127: *"macOS can't reliably track the identity of the code."* Any grant earned may be
   forgotten at the next rebuild, and that cannot be proven either way.
2. **A veto denylist rots.** Guarding the picker means enumerating protected roots. Apple adds
   locations; the guard silently stops covering them.
3. **On a machine where `~/Documents` is a cloud symlink, a wrong grant is permanent** — it
   likely lands in `kTCCServiceFileProviderDomain`, which has no revocation UI in System
   Settings.

A fixed location inside our own container means there is nothing to get wrong. **Revisit only
after Chakra has a Developer ID.**

Consequence: **do not add `NS*FolderUsageDescription` keys.** Declaring that Chakra wants
Documents access, in an app that never touches it, is a lie in the one file a curious user
reads.

### 2.4 The orb is the intake. The wheel cannot be.

Dragging a file from Finder requires clicking in Finder, which makes Finder frontmost — and
`Sources/WheelWindow.swift` calls losing key focus *"the whole dismissal mechanism"*. The
wheel is gone before the drag arrives. The codebase already says so in two comments
(`Onboarding.swift`, `WheelView.swift`).

The orb is a `.nonactivatingPanel` that never takes key focus and floats above everything, so
it is reachable mid-drag. It already registers `.fileURL` (`OrbView.swift:65`).

### 2.5 The hub shows content at rest, not an instruction

The hub's resting state is the **count and the total size**. The words "Add to shelf" and the
drop-target styling appear only while a drag is over it, on hover, or when the shelf is empty.

**Why:** a permanent imperative is noise that never goes away and teaches nothing after the
first day. The Dock does not say "add apps here".

**Empty state** is the exception and the most important screen: a dashed ring, a down arrow,
"Shelf empty", "drop files on the orb".

### 2.6 The readout is a count and a size. No kind word.

One number, large, with the total size beneath it. No "files", "folders" or "items".

**Why:** a mixed shelf — one file, two folders, three images — has no single noun, and
"items" spends the only spare line saying nothing. Dropping the word buys a 62 pt number
instead of 46 pt, which is what keeps it legible at the 0.7× minimum wheel scale.

**Budget:** the hub is 144 pt across; a square inscribed in it is about **100 × 100 pt**.
Nothing richer fits. A card-stack alternative was rejected because it caps at three visible
cards and therefore cannot report a count above three at all.

**Three digits do not fit.** Show `99+` above 99.

### 2.7 The orb shows presence at rest, precision on demand

At rest with a loaded shelf, the orb's small white centre dot **grows and takes the accent
colour**. It does not show a number.

On hover, and in the hub when open, the exact count appears.

**Why:** the orb is a miniature of the user's own ring — eight dots that are their apps. A
digit in the middle turns it into a notification widget and costs it its identity. "Is there
something on my shelf?" is the at-rest question; "how many exactly?" is on demand.

A corner badge outside the disc was rejected by the owner. A number at twelve o'clock was
rejected on measurement: that position is the lead dot, which gives the orb its orientation,
and the two crowd each other.

### 2.8 The hub is shelf-only. The wheel moves by its glass bands.

Two gestures wanted the same press-and-drag on the hub: moving the wheel (what it does today,
`WheelView.swift`) and dragging files out (required). The hub keeps drag-out.

**Why the bands:** they are large, and a press on them currently does **nothing** in the code,
so the gesture is free. Hold-⌥ was rejected as undiscoverable. Removing drag-out was rejected
because it removes the feature's other half.

`.center` must also stop dismissing the wheel. Dismissal remains Esc and click-outside.

### 2.9 Paste writes the clipboard's own bytes

| Clipboard offers | Write | Extension |
|---|---|---|
| `public.png` | those bytes **verbatim** | `.png` |
| `public.jpeg` | those bytes **verbatim** | `.jpg` |
| only `public.tiff` | convert to PNG | `.png` |

**Never write TIFF.** The lookup order is load-bearing, not stylistic:

- Measured: after PNG is placed on a board, `data(forType: .tiff)` returns **14,749,968
  synthesised bytes** for a 12,112,483-byte PNG. **AppKit invents TIFF on demand**, so a
  TIFF-first lookup — or `NSImage(pasteboard:)` — inflates the file 22×.
- `availableType(from:)` honours array order. `public.jpeg` has no `PasteboardType` constant;
  construct it.
- Measured: `writeObjects([NSImage])` puts **only** TIFF on the board. So the conversion path
  is the **common** case for app-sourced images, not the fallback.
- Why not always PNG: a real photo re-encoded from JPEG to PNG measured **6.7× larger**.
  Why not always JPEG: on a text-heavy screenshot JPEG q0.9 was only **6% smaller** than PNG
  while being lossy. Passing through whatever arrived is optimal in both directions and
  re-compresses nothing.

**Conversion must not run on the main thread.** Measured TIFF→PNG for a full 3456×2234 retina
grab: up to **414 ms** worst case.

**Size from pixels, never points.** Measured `NSImage.size = (4.0, 4.0)` where
`pixelsWide = 8`. Use `NSBitmapImageRep.pixelsWide/pixelsHigh`.

**A paste with no image** — text on the clipboard — must say so: "Nothing on the clipboard
Chakra can save as a file." Never silently do nothing.

### 2.10 Pasted files are named `Pasted <date> at <time>`

`Pasted 2026-09-22 at 08.59.49.png`, and on a same-second collision
`Pasted 2026-09-22 at 08.59.49 (2).png`.

`DateFormatter`, format `yyyy-MM-dd 'at' HH.mm.ss`, **locale `en_US_POSIX`**, timezone
`.current`.

- It is Apple's own screenshot convention, so a user already knows how to read it.
- `.` between time fields is **mandatory, not stylistic**: `:` is legal at the POSIX layer but
  `displayName(atPath:)` renders it as `/`, so `08:59:49` would display as `08/59/49`.
- `yyyy-MM-dd` then `HH.mm.ss` sorts lexicographically into chronological order.
- `en_US_POSIX` is load-bearing. Without it a Thai Buddhist calendar yields `2569-09-22` and a
  12-hour locale yields `08.59.49 AM`, breaking the sort.
- Local time, not UTC: the name exists for a human scanning a folder.
- `Pasted`, not `Screenshot`: a paste may be a copied web image.

Sub-second precision is deliberately **not** added — measured, second resolution collides only
under automation (1,435,877 timestamps in one second produced 2 distinct strings). The
parenthesised counter handles it. The parentheses differ from §2.11's bare number on purpose:
`Pasted … 08.59.49 2.png` reads as a malformed timestamp.

### 2.11 Name collisions use Finder's drop convention

`report.pdf`, `report 2.pdf`, `report 3.pdf`. Counter **before** the extension.

Read from Finder's own string table: template `N1` (`^=1 ^=0`) is what Finder uses for a drop
collision, alongside the "Keep Both" button. `N4` (`^=1 copy ^=0`) is for ⌘D, which is a
different gesture. There is no `copy 1` — Finder's first duplicate is bare `copy`.

**Loop against `copyItem`'s own `EEXIST`, never against `fileExists`** — measured,
`copyItem` never overwrites and throws `NSCocoaErrorDomain 516`. That makes the loop
race-safe. Bound it (999) and fall back to a short UUID; an unbounded loop on a hostile
directory is a hang.

### 2.12 Caps: 1 GB refusal, no byte warning, count is the signal

- **Refuse** a drop that would take the shelf over **1 GB**. Refuse the whole drop; copy
  nothing.
- **No 500 MB warning.** Removed deliberately, see below.
- **Note at 10 items**, informational, not a warning.
- **Never auto-delete.**

**The cap does not protect disk space, and the spec must say so.** Measured:
`FileManager.copyItem` on the same APFS volume is `clonefile(2)` — **100 MB in 0.120 ms,
consuming 4,096 bytes**; a 5 GiB file in 0.12 ms. The copy is genuinely independent (distinct
inode, `st_nlink = 1`, truncating the source left it intact). So a user can put 1 GB on the
shelf and free **zero** bytes by emptying it.

What the cap therefore is: **a backstop against the shelf becoming unbounded**, expressed in a
number the hub can honestly display. Bytes are not the scarce resource; attention is. That is
why the byte *warning* is gone and the item count is the signal the user sees.

**Sizes are logical file sizes.** Use `.totalFileSizeKey`, never `.fileSizeKey` — measured 40
vs 14 bytes on a file with a resource fork. Consequence to document: a 4 GB sparse file
occupying 0 bytes is refused. That is intentional and will be reported as a bug.

**Refuse, not copy-what-fits**, because a partial copy is unverifiable by the user: they
cannot tell which files landed without comparing against the source by hand, and every
ordering rule for "what fits" is arbitrary.

The refusal must do the arithmetic and offer an exit:

> **Can't add these 50 files.**
> They total 900 MB and the shelf already holds 800 MB. The limit is 1 GB.
> Free up 700 MB, or drop fewer files.
> `[Open Shelf in Finder]` `[OK]`

**Pre-flight totalling is affordable.** Measured: 5,000 files in a nested tree totalled in
**18 ms** with the URL-based enumerator (`enumerator(at:includingPropertiesForKeys:)`), versus
103 ms with the path-based one. **Bail out early** the moment the running total exceeds the
headroom — that turns a hostile million-file tree from ~3.6 s into milliseconds. Time-box the
walk at ~500 ms and show a measuring state rather than freezing.

### 2.13 `.app` bundles are refused on intake

> Chakra can't shelve applications — drop it on the wheel to pin it instead.

**Why:** a copied bundle breaks its signature's path assumptions and may not launch, and
quarantine behaviour on a re-parented copy is unspecified. Refusing also teaches the feature
the user actually wants. Detect with `.isApplicationKey` / the `.app` extension before copying.

Other packages (`.rtfd`, `.photoslibrary`) **are** accepted, as one item each, with their
interior included in the size total.

### 2.14 Promise drags are supported

Dragging an image out of Safari, Mail or Photos puts
`com.apple.pasteboard.promised-file-url` on the pasteboard and **no file URL**. Measured:
`readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])` returned
**`[]`**.

This is the archetypal shelf gesture. Without support it fails **silently**, which is the
worst outcome available. Register `NSFilePromiseReceiver.readableDraggedTypes` alongside
`.fileURL` and call `receivePromisedFiles(atDestination:options:operationQueue:reader:)`.

### 2.15 Leading dots are stripped; local names are sanitised

`.zshrc` becomes `zshrc`. A shelf item the user cannot see is worse than a renamed one.

Also required, all measured:

- **`/` in a name is a path-traversal hazard.** `appendingPathComponent("with/slash.txt")`
  yields `lastPathComponent == "slash.txt"` — the file lands in a subdirectory. Replace `/`
  and `\0` **before** appending, then assert the result's parent is the shelf.
- **Length limit is 255 UTF-16 code units, not bytes.** 255 × `é` (510 bytes) succeeds;
  256 fails `ENAMETOOLONG`. Truncate on `utf16.count`, at a `Character` boundary, base name
  only — never the extension. Reserve room for `" 999"`.
- **APFS stores Unicode decomposed.** Swift `String ==` is safe; comparing `Array(name.utf8)`
  or persisting a name and byte-comparing later is not. Normalise both sides with
  `.precomposedStringWithCanonicalMapping` if any name is ever persisted.
- Trim trailing whitespace and dots; replace control characters with `_`.

### 2.16 Excluded from Time Machine, not from Spotlight

Set `URLResourceKey.isExcludedFromBackupKey = true` on the folder. The originals still exist
wherever they came from, so the shelf is not backup-worthy.

Spotlight indexing is **kept**: finding a shelved file by search is useful, not surprising.
(`.metadata_never_index` would opt out if this is ever reversed.)

### 2.17 Removal is explicit, via the Trash

There is an in-Chakra remove, implemented with `trashItem(at:resultingItemURL:)`.

**Why it is required, not optional:** without it, a shelf at the cap refuses every drop and the
only exit is Finder — which converts the feature into a trap. Using the Trash keeps it
recoverable, and a user-initiated removal is not an auto-delete.

### 2.18 Dragging out is copy-only

`draggingSession(_:sourceOperationMaskFor:)` returns `.copy` for **every** context, including
`.outsideApplication`.

This is deliberately the **inverse** of `WheelView`'s existing restriction, which returns `[]`
for `.outsideApplication` to stop Finder duplicating a 400 MB app bundle. For the wheel an
outgoing drag is an accident; for the shelf it is the point. Returning `[]` would make the
shelf write-only.

`.move` is **excluded on purpose**: including it makes move the Finder default for a
same-volume drag, and the source then becomes responsible for deleting its own file — a drag
that silently empties a shelf slot with no undo. `.every`/`.generic` are excluded because they
include `.delete` (drag to Trash) and `.link` (which would hand out a reference, undoing §2.1).

Multi-select drag-out passes several `NSDraggingItem`s. Note `WheelView` currently passes
exactly one.

---

## 3. Architecture

Four units. Each has one purpose, a stated dependency, and can be described without reading
its internals.

### 3.1 `Sources/Shelf.swift` — the store

Owns the folder and every filesystem operation. **No AppKit view code, no window.**

```
ensureExists() throws                  // idempotent, called before every operation
func add(_ urls: [URL]) -> AddOutcome  // resolve, pre-flight, copy, verify, rename
func add(pasteboard: NSPasteboard) -> AddOutcome
func items() -> [ShelfItem]            // live directory scan
func total() -> (count: Int, bytes: Int64)
func remove(_ item: ShelfItem) throws  // trashItem
var onChange: (() -> Void)?            // fired by the directory watch
```

**Why its own file:** `main.swift` cannot be linked into any test binary (`GOTCHAS.md` §2), so
anything placed there is untestable by construction. `Shelf` must be constructible from a test
with an injected root directory, exactly as `OuterRing` and `Recents` take an injected
`UserDefaults`.

**Testability requirement:** the initialiser takes a root URL. Tests pass a scratch directory
under `/tmp` and delete it afterwards, mirroring `registerScratchDomain` in `TestMain.swift`.

### 3.2 `Sources/ShelfIntake.swift` — pasteboard and promise decoding

Pure translation from an `NSDraggingInfo` or `NSPasteboard` into a list of things to copy.
Separated from `Shelf` because it is the part with the most surprising rules (§2.9, §2.14) and
it can be tested with a synthetic pasteboard and no filesystem at all.

### 3.3 `OrbView` / `OrbController` changes — intake and presence

- Accept multi-URL drops. **Do not reuse `WheelView.droppedPath`** — it returns `urls.first`,
  so a five-file drop would shelve one and silently discard four.
- Register promise types.
- Draw the presence state (§2.7).
- **Always return `.copy` from `draggingUpdated`, then explain any refusal in
  `performDragOperation`.** Returning `[]` means AppKit never calls `performDragOperation` and
  a refused drop becomes indistinguishable from a missed one — `WheelView` already learned
  this and the comment survives.

### 3.4 `WheelView` changes — the hub

- Draw the readout (§2.5, §2.6).
- Become a drag source for shelf items, copy-only (§2.18).
- Stop dismissing on `.center`; move the wheel from the glass bands instead (§2.8).

---

## 4. Data flow

**Intake.** Drop on orb → `ShelfIntake` decodes to URLs or promises → `Shelf.add` → resolve
symlinks/aliases → refuse `.app` → pre-flight total with early bail → copy each to
`.chakra-incoming-<uuid>` → verify → atomic `moveItem` to the final name → fire `onChange`.

**Readout.** Wheel opens → `Shelf.total()` → hub draws. Directory watch fires → recompute →
redraw if the wheel is open, update orb presence either way.

**Outtake.** Drag from hub → `NSDraggingItem` per item with the real file URL → `.copy` only →
shelf keeps its copy.

### 4.1 Verified copy — the mechanism

A copy must not become visible under its final name until it is verified, because **a failed
folder copy leaves a partial tree behind**. Measured: `copyItem` on a folder with one
unreadable child threw and left four of five entries in place. Single-file failures do clean
up after themselves — disk-full and a mid-copy volume yank both left nothing.

1. Copy to `Shelf/.chakra-incoming-<uuid>`. The leading dot means a crash mid-copy leaves
   invisible litter, not a fake shelf entry.
2. Verify. **Choose the check by cost:**
   - same volume and cloning supported → compare `.totalFileSizeKey`. A clone is identical by
     construction; there is no path where `clonefile` succeeds with different bytes.
   - otherwise → SHA-256 both sides. Measured **41 ms per 100 MB** streaming 1 MB chunks
     (2.43 GB/s). Do **not** use `FileManager.contentsEqual` — measured **12.3× slower**.
     Do not use `mappedIfSafe` on untrusted input for a 16% gain.
3. `moveItem` to the final name. This is `rename(2)`, atomic within the volume, and measured
   to throw `516` rather than clobber — so §2.11's naming loop cannot be defeated by a race.
4. On any failure, `removeItem` the temp path. On launch, sweep `.chakra-incoming-*` older
   than one minute.

### 4.2 Counting — live scan, no index

Measured cost of the exact call the hub makes
(`contentsOfDirectory(at:includingPropertiesForKeys:options:[.skipsHiddenFiles])` plus cached
resource values):

| Items | Scan |
|---|---|
| 10 | **0.035 ms** |
| 100 | 0.204 ms |
| 1000 | **1.905 ms** |

At the 10-item threshold that is 0.002% of a 60 Hz frame. A persisted index buys nothing
measurable and introduces a second source of truth that can be wrong — the only way this
feature can lie.

**Never `attributesOfItem` in a loop** — measured 7.7× slower at 1000 files.

**`Icon\r` is not hidden** (`isHidden = false`) and survives `.skipsHiddenFiles`. Exclude it,
`._*` and `.chakra-incoming-*` by name. This matters because the hub's own click action opens
the folder in Finder, which creates exactly this litter.

### 4.3 Staying in step with Finder

Watch the folder with `open(dir, O_EVTONLY)` plus
`DispatchSource.makeFileSystemObjectSource(eventMask: [.write, .delete, .rename, .revoke])`.
Measured: deleting a child fires `.write` on the parent, and this needs **no entitlement and
no permission prompt** — unlike `FSEventStream` on arbitrary paths. That is what makes it
compatible with `INVARIANTS.md` §1.

Debounce ~200 ms.

**On `.delete` or `.revoke`:** measured, the fd stays valid but stale. `cancel()` the source,
`close()` the fd, recreate the folder on next intake, re-arm. A watcher that outlives its
directory never fires again.

---

## 5. First run and self-healing

Mirror `build.sh`'s philosophy: cheap check, unconditional repair, no cost when healthy.

Measured: `createDirectory(at:withIntermediateDirectories: true)` on an existing directory
**succeeds**. It is idempotent on an existing directory, which is why repeated calls are free.
A `fileExists` guard is nonetheless present to distinguish a *file* blocking the path from a
directory, so Chakra can throw `blockedByFile` rather than let `createDirectory` throw an
error whose text names the wrong file. The directory/directory race is benign for the
idempotency reason; the file/directory race is caught and mapped rather than leaked.

**Create lazily, on first intake — not at launch.** A launcher never used as a shelf should
leave no trace in `Application Support`. Chakra owns no on-disk state today; this is the first.

| Situation | Handling |
|---|---|
| Folder missing | Create it. No message. |
| User deletes it while Chakra runs | Hub drops to 0. **No alert** — the user deleted it, they know. Re-arm the watch. |
| Replaced by a **file** of the same name | **The one case that must not self-heal.** Measured: `createDirectory` throws `516`/`EEXIST`, and `fileExists(atPath:isDirectory:)` returns `exists=true, isDirectory=false` — use that to distinguish it. Alert once: "Chakra can't use the Shelf folder because a file named *Shelf* is in its place." `[Reveal in Finder]`. Deleting it would violate never-auto-delete. |
| Made read-only | **Self-heal.** Chakra owns this folder: `setAttributes([.posixPermissions: 0o755])`, then **verify writability** and report if still unwritable. Measured: `setAttributes` can succeed while the folder remains unwritable (e.g. with `chflags uchg`), so checking the call's result is insufficient — verification is required. |
| Two Chakra instances race | Benign. Idempotent create, plus `copyItem`/`moveItem` both refusing to clobber. **Do not add a lock file.** |

---

## 6. Error messages

`NSError.localizedDescription` from `FileManager` is **unusable** — measured, for an unreadable
*source* it says *"…you don't have permission to access **'dst'**"*, naming the destination.
Switch on the code and write Chakra's own text.

| Code | POSIX | Message |
|---|---|---|
| 640 | `ENOSPC` | "Not enough space to add *name*." |
| 512 | `EIO` | "The disk holding *name* was disconnected. Nothing was added." |
| 513 | `EACCES` | "Chakra can't read *name*." Read `userInfo[NSSourceFilePathErrorKey]` for the name. |
| 260 | `ENOENT` (specifically `NSFileReadNoSuchFileError`) | "*name* is no longer there." Measured: `NSFileNoSuchFileError` is 4; 260 is `NSFileReadNoSuchFileError`, and a missing source throws this from both `attributesOfItem` and `copyItem`. |
| 516 | `EEXIST` | Never surfaced; drives the naming loop. |
| `shelfNotWritable(URL)` | folder-level | "Chakra can't write to its Shelf folder" with `[Reveal in Finder]` action. The folder exists, is a directory, and could not be made writable. |
| `shelfUnusable(URL, code: Int)` | folder-level | "Chakra can't set up its Shelf folder" with `[Reveal in Finder]` action. The folder could not be created for some other reason. Measured codes: 513 `EACCES`, 512 `EIO`, 514 `ENAMETOOLONG`, 518 unsupported scheme, 640 `ENOSPC`. **The `code` is carried for a bug report and must never be shown to the user** — it is what makes this case exist rather than rethrowing `FileManager`'s own misleading text. |

For a folder with unreadable children, set a `FileManagerDelegate` returning `true` from
`shouldProceedAfterError` — measured, the copy then succeeds and skips only the unreadable
child. Report "Added *src* but skipped 1 item Chakra can't read." **Use a fresh
`FileManager()`**: `FileManager.default.delegate` is process-global and would change behaviour
app-wide.

---

## 7. Testing

Constrained by `GOTCHAS.md` §6: `run-tests.sh` compiles 10 of 18 files by design;
`run-smoke.sh` compiles 17 and needs an unlocked screen.

**In `run-tests.sh`** — add `Sources/Shelf.swift` and `Sources/ShelfIntake.swift`. Both are
UI-free, so they belong there and the existing boundary is respected. Cover: name collisions
including case and Unicode, length truncation, `/` sanitising, leading-dot stripping, the
pasteboard type-order rule with a synthetic board, `.app` refusal, cap arithmetic and early
bail, verified-copy success and each failure code, self-healing including the file-in-the-way
case.

**In `Tools/Smoke.swift`** — the orb drop path, the hub readout, presence state, drag-out
operation mask, and the refusal message. Note the smoke tool currently **never constructs
`StatusDropView`**, **never calls `draggingEnded`**, and **never touches right-click**; the
shelf should not inherit those gaps.

**`-warnings-as-errors` will reject the obvious code.** Every discarded result needs an
explicit `_ =` — a bare `try? fm.removeItem` in a cleanup path is a build failure.

---

## 8. Invariants this feature must not break

1. **No permission prompt, ever** (`INVARIANTS.md` §1). The storage location and the vnode
   watch were both chosen for this. Any change to either needs the `nm -u` check re-run.
2. **Zero warnings.**
3. **Copies, never references** — §2.1, and it requires active symlink/alias resolution.
4. **Never auto-delete** — the cap refuses, it does not evict.
5. **Counts are read, never written into copy** (`INVARIANTS.md` §6).
6. **Drawing and hit-testing read one geometry instance** — the hub's new hit region included.

---

## 9. Out of scope for v1

- A shelf folder the user chooses (§2.3).
- Thumbnails or previews of shelf contents.
- Reordering, tagging, or naming shelf items.
- Any automatic expiry. But **record an intake date** — `.creationDateKey` is free — so a
  future "older than 30 days" view needs no migration.
- Non-APFS volumes. Every measurement here is APFS. HFS+ normalises differently and cannot
  clone; SMB rejects characters APFS accepts.
- Intel performance. All numbers are Apple M5 Pro. The shapes of the conclusions hold; the
  414 ms worst-case PNG encode could exceed a second.

---

## 10. Still undecided, and who decides

| Question | Why it is open |
|---|---|
| Does `com.apple.macl` implicit consent survive an ad-hoc rebuild? | Unverified. Needs a human to pick a folder, quit, rebuild, relaunch and watch `log stream --predicate 'subsystem == "com.apple.TCC"'`. Only matters if §2.3 is ever reversed. |
| Which TCC service a symlinked `~/Documents` lands in | Unverified. Evidence leans toward the resolved target, i.e. FileProvider, which has no revocation UI. Only matters if §2.3 is reversed. |
| Whether `NSRunningApplication.terminate()` can prompt for Automation | Pre-existing, unrelated to the shelf, recorded in `INVARIANTS.md` §1. |

# Gotchas — traps, with the evidence that each is real

`CLAUDE.md` says to read this before debugging anything. It did not exist until 2026-09-22.

Each entry is something that cost real time, with the evidence. Nothing here is theoretical.

---

## The original five

### 1. `run-smoke.sh` fails completely on a locked screen

The window server refuses to move windows, so every orb-tuck check fails and it looks exactly
like a broken animation. There is a guard at `Tools/Smoke.swift` that says so — believe it
when it fires.

### 2. `Sources/main.swift` cannot be linked into any test binary

It has top-level code, which Swift forbids alongside the `@main` that every test and tool
declares. So the app-delegate wiring has **no automated coverage at all, by construction**.

Corollary for new work: anything that must be testable cannot live in `main.swift`. Put it in
its own type and have `main.swift` do nothing but call it.

You will hit the same wall writing a throwaway probe: linking several `Sources/*.swift` files
plus top-level probe code fails with `expressions are not allowed at the top level`. Wrap the
probe in `@main struct` and compile with `-parse-as-library`.

### 3. Never add `.moveToActiveSpace` to the orb's collection behaviour

With `.canJoinAllSpaces` it raises `NSInternalInconsistencyException` and kills the app.

### 4. `window.animator().setFrameOrigin(_:)` is silently swallowed

On this kind of panel it does nothing. Use `setFrame(_:display:)`. This once made a whole
shipped feature dead while 340 checks stayed green.

### 5. Find windows in tests by being *new*, not by title

Windows stay in `NSApp.windows` after `orderOut`, with the same title. Matching on title has
twice made a test fire a control belonging to a *different* controller.

---

## Found 2026-09-22, during a full-codebase audit

### 6. `run-tests.sh` compiles 10 of the 18 source files

By design — "the files with no UI in them". `WheelView`, `OrbView`, `OrbController`,
`WheelWindow`, `StatusItem`, `SettingsWindow` and `Onboarding` are **not** in it.

`run-smoke.sh` compiles 17 of 18 (all but `main.swift`). So the view layer *is* testable —
via smoke, which needs an unlocked screen.

**Consequence:** seven of the eleven defects found in that audit were unreachable by the
1,728 unit checks no matter what you write in `Tests/`. If a defect is in the view layer, the
check belongs in `Tools/Smoke.swift`.

### 7. The check count is a runtime counter, not a count of assertions

There are ~658 assertion call sites. One loop in `Tests/GeometryTests.swift` iterating outer
4…10 × inner 0…7 contributes **588 checks** on its own — about a third of the headline.

**So the number is sensitive to `minOuterSlots`/`maxOuterSlots`.** Widening the slider range
inflates it without adding a single new idea. Do not read a rising count as rising coverage.

Also: `suite(_:_:)` has no must-run assertion, so a suite accidentally dropped from `main()`
fails nothing.

### 8. `Dictionary.values.max` is nondeterministic on a tie

Swift seeds hashing randomly **per process**, and `max` returns the first maximal element in
iteration order. So two equally populous buckets resolve differently on every launch — and
calling twice inside one process always agrees, which is why it hides.

Measured: 4 of 83 installed apps tie exactly in `dominantColor`. Reverting the fix and running
the test in 8 separate processes gave **3 passes and 5 failures**.

**Any `max`/`min`/`first` over a `Dictionary` or `Set` needs an explicit tie-break.**

### 9. `NSError.localizedDescription` from `FileManager` blames the wrong file

For a source file Chakra cannot read, `copyItem` produces *"'noread.txt' couldn't be copied
because you don't have permission to access **'dst'**"* — it names the **destination**.

Never surface it. Switch on `NSError.code` (640 `ENOSPC`, 512 `EIO`, 513 `EACCES`,
516 `EEXIST`, 260 `ENOENT`) and read `userInfo[NSSourceFilePathErrorKey]`.

### 10. `FileManager.copyItem` on the same APFS volume is `clonefile(2)`, not a byte copy

Measured: 100 MB "copied" in **0.120 ms**, consuming **4,096 bytes**. A 5 GiB file in 0.12 ms.
The copy is genuinely independent — distinct inode, `st_nlink = 1`, and truncating the source
left the copy intact.

**Consequence:** any size cap measures a *logical* number, not disk consumption. And a sparse
4 GB file occupying 0 bytes counts as 4 GB. Use `.totalFileSizeKey`, never `.fileSizeKey` —
measured 40 vs 14 bytes on a file with a resource fork.

### 11. A failed *folder* copy leaves a partial tree behind

Single-file failures clean up after themselves — disk-full and volume-yank both left no file.
But `copyItem` on a folder with one unreadable child threw and left four of five entries in
place.

So a copy must land on a temporary name and be renamed only after verification.
`FileManager.default.delegate` can be used to skip unreadable children — but it is
**process-global**, so use a fresh `FileManager()` instance, never `.default`.

### 12. `pasteboard.writeObjects([NSImage])` puts only `public.tiff` on the board

No PNG. So for any app that puts an `NSImage` on the clipboard — which is most of them — TIFF
is the *only* type offered.

Worse: after `setData(pngData, forType: .png)`, asking `data(forType: .tiff)` returns
**14,749,968 synthesised bytes** for a 12,112,483-byte PNG. **AppKit invents TIFF on demand.**
So `NSImage(pasteboard:)` or a TIFF-first lookup silently inflates the file 22×.

Ask in order: `public.png`, then `public.jpeg`, then `public.tiff`.
`availableType(from:)` honours array order. `public.jpeg` has no
`NSPasteboard.PasteboardType` constant — construct it.

### 13. `NSImage.size` is in points; a retina grab has twice the pixels

Measured `rep.size = (4.0, 4.0)` with `pixelsWide = 8`. Sizing an export from `NSImage.size`
loses 75% of a retina screenshot. Always use `NSBitmapImageRep.pixelsWide/pixelsHigh`.

### 14. The filename length limit is 255 UTF-16 code units, not 255 bytes

Measured: 255 × `é` is 510 UTF-8 bytes and **succeeds**; 256 × `é` fails `ENAMETOOLONG`.
127 × 😀 succeeds, 128 fails. Truncate on `utf16.count`, at a `Character` boundary, and never
truncate the extension.

### 15. APFS stores Unicode **decomposed**

Writing `café.txt` with a precomposed `U+00E9` and reading `d_name` back at the `readdir(2)`
level returns `e` + `U+0301`. The two forms are the same file (`O_EXCL` fails `EEXIST`).

Swift `String ==` is safe because it compares canonically. Comparing `Array(name.utf8)`, using
`Data` as a dictionary key, or persisting a name and byte-comparing it later **will break**.

### 16. `Icon\r` is not hidden and survives `.skipsHiddenFiles`

`.DS_Store` and `._*` have `isHidden = true` and are filtered. `Icon\r` has
`isHidden = false`. Any directory listing that must ignore Finder litter has to exclude it
**by name**.

### 17. A file panel is not the only thing that can refuse a drop silently

`WheelView` learned this the hard way and the comment survives: returning `[]` from
`draggingUpdated` means AppKit **never calls `performDragOperation`**, so a refused drop is
indistinguishable from a missed one.

Always accept the drag, then explain the refusal in `performDragOperation`.

### 18. `.withSecurityScope` in a non-sandboxed app **strips** the token, and then lies

Security-scoped bookmarks are an App Sandbox feature. Apple's own docs say *"For use in an
app that adopts App Sandbox"*, and the SDK header says the flag lets *"the same **sandboxed**
process"* regain access.

Measured in a non-sandboxed process:

| Options | Bookmark size | Embeds a sandbox extension token |
|---|---|---|
| `[]` | 852 bytes | **yes** |
| `.withoutImplicitSecurityScope` | 644 bytes | no |
| `.withSecurityScope` | **644 bytes** | **no** |

So asking for security scope **removes** the thing you were trying to keep. Worse,
`startAccessingSecurityScopedResource()` still returns `true`, so the mistake is invisible.

**Chakra has no sandbox entitlement.** Store a plain path, or `bookmarkData(options: [])`.
Never pass `.withSecurityScope`.

### 19. Ad-hoc signing means Chakra has no stable identity, and TCC notices

`codesign -dvvv` on the shipped app: `Identifier=local.chakra`, `flags=0x2(adhoc)`,
`TeamIdentifier=not set`, `Internal requirements count=0`, and a designated requirement that
is **only** a cdhash.

Measured: two ad-hoc builds of the same identifier produced two different designated
requirements (`cdhash H"b23cc85f…"` then `cdhash H"ea209835…"`). A real app's DR names its
team OU and never changes.

Apple, TN3127: *"Ad hoc signed code … has a DR but it's tied to that specific version of the
code. … macOS can't reliably track the identity of the code."* Apple DTS advises a stable
signing identity to *"radically cut down on the amount of TCC thrash"*.

**Consequence:** any permission or implicit-consent grant Chakra earns may be forgotten on the
next rebuild, and that cannot be proven either way without a stable identity. This is the
reason the shelf lives somewhere with **no** permission surface rather than somewhere the user
picks. Revisit only after Chakra has a Developer ID.

Related: on a machine where `~/Documents` is a symlink into a cloud provider — which is the
case on at least one target Mac — a grant there is likely a `kTCCServiceFileProviderDomain`
grant, and that one has **no revocation UI** in System Settings. A mistake there is permanent.

### 20. A permission probe must test the actual operation

`touch /Applications/.probe` succeeded, which was read as "`/Applications` is writable". It is
not: the root-owned files *inside* `Chakra.app` cannot be deleted, so `./build.sh --install`
failed. Creating a file in a directory and deleting a file in a subdirectory are different
permissions. Test the operation you intend to perform.

### 21. `setAttributes` and `fileExists(atPath:isDirectory:)` both follow symlinks

`setAttributes(_:ofItemAtPath:)` is `chmod(2)`, not `lchmod`. Only
`attributesOfItem(atPath:)[.type]` reports the link itself. Measured 2026-09-22: a victim
directory went `0500` → `0755` through a symlink planted at the target path.
`fileExists(atPath:isDirectory:)` likewise follows the link and reports the **target's**
type. This was a real security hole — a symlink at `~/Library/Application
Support/local.chakra/Shelf` made `ensureExists()` widen permissions on a directory Chakra
does not own.

### 22. `/bin/chmod` is not `setAttributes`

BSD `chmod` **skips the syscall entirely when the mode is unchanged**, so it exits 0 where
the API throws. A comment in this project asserted that `setAttributes` succeeds under
`chflags uchg`; measured, it throws **513**. The shell tool succeeded, the API did not. This
is #20's own lesson — test the operation you intend to perform — committed inside a comment
that was fixing a different instance of it. **The real reproducer for "succeeds but stays
unwritable" is an ACL `deny add_file`**, not `uchg`.

### 23. `.totalFileSizeKey` is nil for a directory

Including a package. So a package's size must come from a recursive walk, never from that
key. Measured 2026-09-22: an `.rtfd` holding 5,000 bytes reported 0.

### 24. `copyItem` preserves the source's creation date

So `.creationDateKey` on a shelf item is the *original* file's date, not the intake date —
measured, a source stamped 2001-09-09 landed with that same creation date while
`addedToDirectoryDate` was `now`. Use `.addedToDirectoryDateKey` for "when did this arrive".

### 25. `displayIfNeeded()` draws nothing on a view with no window

And neither does `display()`, even inside an unordered window. Measured 2026-09-22: `drew:
0`. A smoke check that calls it and asserts "did not crash while drawing" exercises no
drawing at all. The working idiom in this repository is `renderOffscreen(_:label:)`.

Also: **`RunLoop.current.run(mode:before:)` is a single pass** — it returns after the first
input source rather than waiting out the interval — so a test that uses one call to "wait"
for a debounced callback does not wait at all.

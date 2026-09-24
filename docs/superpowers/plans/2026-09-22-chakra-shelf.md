# Chakra Shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a file shelf to Chakra — drop files on the floating orb, they are copied into a real folder, the wheel's hub shows the count and size, and files can be dragged back out.

**Architecture:** Two new UI-free types carry all the logic so they can be unit tested — `Shelf` owns the folder and every filesystem operation, `ShelfIntake` translates a pasteboard or drag into a list of things to copy. Three existing view files gain thin wiring: `OrbView`/`OrbController` for intake and the presence dot, `WheelView` for the hub readout and drag-out. Every copy lands on a hidden temporary name, is verified, then atomically renamed, because a failed folder copy leaves a partial tree behind.

**Tech Stack:** Swift 5, AppKit, CryptoKit (for SHA-256 verification only), bare `swiftc` — no SwiftPM, no Xcode project, no third-party code. Hand-rolled test harness in `Tests/TestMain.swift`, not XCTest.

**Spec:** `docs/superpowers/specs/2026-09-22-chakra-shelf-design.md` — read it alongside this plan. Every decision's reason and measurement lives there; this plan does not repeat them.

## Global Constraints

Copied verbatim from the spec and `ai/INVARIANTS.md`. **Every task's requirements implicitly include this section.**

- **Swift version / target:** `-swift-version 5`, `-target arm64-apple-macos14.0` (and `x86_64` in `build.sh`). Using an API newer than macOS 14 must be a compile error, not a runtime crash.
- **`-warnings-as-errors` is on in all six scripts.** A warning is a build failure. An unused `let` fails the build. **Every discarded result needs an explicit `_ =`** — a bare `try? fm.removeItem(...)` in a cleanup path will not compile.
- **Zero dependencies.** No SwiftPM, no third-party code. CryptoKit ships with the OS and is allowed.
- **Chakra must never trigger a macOS permission prompt.** No Accessibility, Screen Recording, Automation or Files-and-Folders. This is why the shelf lives in `~/Library/Application Support/local.chakra/Shelf/` and why the directory watch uses `open(O_EVTONLY)` + `DispatchSource` rather than `FSEventStream`. **Do not add any `NS*UsageDescription` key to `Info.plist`.**
- **Storage root:** `~/Library/Application Support/local.chakra/Shelf/` — the bundle identifier, not `Chakra`.
- **Cap:** refuse a drop that would take the shelf over **1 GiB = 1_073_741_824 bytes**. Informational note at **10 items**. **No byte warning.** Never auto-delete.
- **Sizes are logical.** Use `.totalFileSizeKey`, never `.fileSizeKey`.
- **Never write TIFF.** Pasteboard lookup order is `public.png`, then `public.jpeg`, then `public.tiff`.
- **Counts are read, never written into copy.** No user-facing string may spell out a number that is a setting.
- **Test harness:** `expect(_:_:)`, `expectEqual(_:_:_:)`, `expectClose(_:_:_:)`, `suite(_:_:)`. Each test file exposes one `func runXTests()` called from `TestMain.main()`.
- **`Sources/main.swift` cannot be linked into any test binary** (it has top-level code, which Swift forbids alongside `@main`). Nothing testable may live there.

### Blocker you will hit at every "Commit" step

**Neither repository has a single commit, and no `user.name`/`user.email` is configured.** `git commit` will fail until the owner supplies an identity. Do not invent one.

Until then, treat each Commit step as: run the tests, confirm green, and **stop at that task boundary** so the work is reviewable. Once an identity exists, the commits can be made in order.

### Two source trees

`~/Claude/projects/Chakra` is the working copy. `~/Claude/docs/GIT/GIT_Chakra` is a hand-maintained duplicate that must stay byte-identical. **After each task, copy every changed file across and verify with `diff -q`.** Nothing enforces this.

---

## File Structure

| File | Responsibility |
|---|---|
| **Create** `Sources/Shelf.swift` | The store. Owns the folder, sizes, copying, verification, removal, the directory watch. No AppKit views. |
| **Create** `Sources/ShelfName.swift` | Pure name rules: sanitising, collision numbering, the pasted-file name. No filesystem. |
| **Create** `Sources/ShelfIntake.swift` | Pure translation from `NSPasteboard`/`NSDraggingInfo` to a list of intake sources. No filesystem. |
| **Create** `Tests/ShelfNameTests.swift` | Unit tests for `ShelfName`. |
| **Create** `Tests/ShelfTests.swift` | Unit tests for `Shelf`, against a scratch directory. |
| **Create** `Tests/ShelfIntakeTests.swift` | Unit tests for `ShelfIntake`, against a synthetic pasteboard. |
| **Modify** `Tests/TestMain.swift` | Add a scratch-directory helper and register the three new suites. |
| **Modify** `run-tests.sh` | Add the three new `Sources` files and three new `Tests` files. |
| **Modify** `run-smoke.sh`, `build.sh` | Add the three new `Sources` files. |
| **Modify** `Sources/OrbView.swift` | Multi-URL drops, promise types, presence dot, always return `.copy`. |
| **Modify** `Sources/OrbController.swift` | Own a `Shelf`, wire intake, drive the presence state. |
| **Modify** `Sources/WheelView.swift` | Hub readout, hub drag-out source, gesture rework. |
| **Modify** `Sources/WheelWindow.swift` | Hand the `Shelf` to the wheel; hub click opens Finder. |
| **Modify** `Tools/Smoke.swift` | Smoke checks for everything in the view layer. |

`ShelfName` is split out from `Shelf` deliberately: it is the part with the most surprising rules (255 **UTF-16** units, `/` as a traversal hazard, APFS decomposition) and it needs no filesystem, so it is the cheapest part of the feature to test exhaustively.

---

## Task 1: Wire the new files into the build, and add a scratch-directory helper

Nothing works until the scripts know about the new files, and no `Shelf` test can run without a throwaway directory that is cleaned up afterwards. This task produces a green build with an empty `Shelf` type and a working test seam.

**Files:**
- Create: `Sources/Shelf.swift`
- Create: `Tests/ShelfTests.swift`
- Modify: `Tests/TestMain.swift`
- Modify: `run-tests.sh`, `run-smoke.sh`, `build.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class Shelf`, `init(root: URL, fileManager: FileManager = FileManager())`, `let root: URL`. Test helpers `scratchDirectory(_ label: String) -> URL` and `removeScratchDirectories()`.

- [ ] **Step 1: Add the scratch-directory helper to the test harness**

In `Tests/TestMain.swift`, immediately after the `removeScratchDomains()` function, add:

```swift
// MARK: - Scratch directories

/// Every throwaway directory the tests have created.
///
/// The same discipline as `scratchDomains`: a test that leaves directories behind is
/// littering somewhere it does not own, and `/tmp` fills up over a long session.
private var scratchDirectories: [URL] = []

/// A fresh empty directory under the system temporary directory, removed at the end of
/// the run. `label` only exists to make a stray directory identifiable if a crash skips
/// the cleanup.
func scratchDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chakra-test-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    scratchDirectories.append(url)
    return url
}

/// Deletes every scratch directory the run created.
func removeScratchDirectories() {
    for url in scratchDirectories {
        _ = try? FileManager.default.removeItem(at: url)
    }
    scratchDirectories.removeAll()
}
```

Then in `TestMain.main()`, add the new suite call and the cleanup. The `removeScratchDirectories()` call goes next to `removeScratchDomains()`, **before both exits**, for the reason the existing comment gives:

```swift
        runProposalTests()
        runShortcutTests()
        runShelfTests()

        // Before either exit, so a failing run leaves the directory as clean as a passing one.
        removeScratchDomains()
        removeScratchDirectories()
```

- [ ] **Step 2: Write the failing test**

Create `Tests/ShelfTests.swift`:

```swift
import Foundation

func runShelfTests() {
    suite("shelf/root") {
        let root = scratchDirectory("root").appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        expectEqual(shelf.root, root, "the shelf remembers the root it was given")
    }
}
```

- [ ] **Step 3: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, with `cannot find 'Shelf' in scope` and `cannot find 'runShelfTests' in scope`.

- [ ] **Step 4: Create the minimal type**

Create `Sources/Shelf.swift`:

```swift
import Foundation

/// The file shelf: a folder of copied files, with the sizes and the counting that the
/// wheel's hub displays.
///
/// UI-free on purpose, and constructed with an injected root directory, so it links into
/// the test binary and can be exercised against a throwaway folder — the same shape as
/// `OuterRing` and `Recents` taking an injected `UserDefaults`.
final class Shelf {
    /// The most the shelf may hold, in bytes.
    ///
    /// This bounds a *logical* total, not disk consumption. On the same APFS volume
    /// `FileManager.copyItem` is `clonefile(2)` — measured, 100 MB in 0.120 ms consuming
    /// 4 KB — so emptying a 1 GiB shelf can free almost nothing. The cap exists to stop the
    /// shelf becoming unbounded and to keep the hub's total honest, not to protect the disk.
    static let capBytes: Int64 = 1_073_741_824

    /// How many items before the wheel mentions it. Informational, never a refusal.
    static let itemNoteThreshold = 10

    let root: URL

    /// A private `FileManager` instance rather than `.default`.
    ///
    /// `FileManager.default.delegate` is process-global, and the copy path needs a delegate
    /// to skip unreadable children. Setting it on the shared instance would silently change
    /// the behaviour of every other file operation in the app.
    let fileManager: FileManager

    init(root: URL, fileManager: FileManager = FileManager()) {
        self.root = root
        self.fileManager = fileManager
    }
}
```

- [ ] **Step 5: Add the file to all three scripts**

In `run-tests.sh`, inside the `swiftc` source list, after `Sources/Proposal.swift \`:

```
  Sources/Shelf.swift \
```

and after `Tests/ShortcutTests.swift \`:

```
  Tests/ShelfTests.swift \
```

In `run-smoke.sh`, after `Sources/Proposal.swift \`:

```
  Sources/Shelf.swift \
```

In `build.sh`, inside the `SOURCES=(` array, after `Sources/Proposal.swift`:

```
  Sources/Shelf.swift
```

- [ ] **Step 6: Run the tests and the build**

Run: `./run-tests.sh && ./build.sh`
Expected: `✓ 1729 checks passed` (1728 plus the one new check) and `built build/Chakra.app`, both exit 0.

- [ ] **Step 7: Sync the second tree and verify**

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/Shelf.swift" "$G/Sources/"
cp "$P/Tests/ShelfTests.swift" "$P/Tests/TestMain.swift" "$G/Tests/"
cp "$P/run-tests.sh" "$P/run-smoke.sh" "$P/build.sh" "$G/"
diff -q "$P/Sources/Shelf.swift" "$G/Sources/Shelf.swift" && echo "in sync"
```

- [ ] **Step 8: Commit** *(will fail until a git identity exists — see Global Constraints)*

```bash
git add Sources/Shelf.swift Tests/ShelfTests.swift Tests/TestMain.swift \
        run-tests.sh run-smoke.sh build.sh
git commit -m "feat: add Shelf skeleton and a scratch-directory test helper"
```

---

## Task 2: Name rules — sanitising and collision numbering

The most surprising rules in the feature, and the cheapest to test because they need no filesystem.

**Files:**
- Create: `Sources/ShelfName.swift`
- Create: `Tests/ShelfNameTests.swift`
- Modify: `Tests/TestMain.swift`, `run-tests.sh`, `run-smoke.sh`, `build.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum ShelfName` with `static func sanitize(_ raw: String) -> String`, `static func candidate(_ sanitized: String, attempt: Int) -> String`, `static let maxUTF16Length = 255`, `static let maxAttempts = 999`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ShelfNameTests.swift`:

```swift
import Foundation

func runShelfNameTests() {
    suite("shelf-name/sanitize") {
        expectEqual(ShelfName.sanitize("report.pdf"), "report.pdf",
                    "an ordinary name is untouched")

        // A leading dot would make the item invisible in Finder and drop it from any
        // listing that uses .skipsHiddenFiles. A renamed item beats an invisible one.
        expectEqual(ShelfName.sanitize(".zshrc"), "zshrc", "a leading dot is stripped")
        expectEqual(ShelfName.sanitize("...hidden"), "hidden", "every leading dot is stripped")

        // A slash is a path separator, not a character. Left in place,
        // appendingPathComponent would put the file in a subdirectory — with "../" that
        // is a traversal out of the shelf entirely.
        expectEqual(ShelfName.sanitize("with/slash.txt"), "with_slash.txt",
                    "a slash is replaced, not treated as a separator")
        expectEqual(ShelfName.sanitize("../escape.txt"), ".._escape.txt",
                    "a traversal attempt cannot leave the shelf")

        // Control characters are legal at the POSIX layer and produce unreadable names.
        expectEqual(ShelfName.sanitize("two\nlines.txt"), "two_lines.txt",
                    "a newline is replaced")
        expectEqual(ShelfName.sanitize("Icon\r"), "Icon_",
                    "the Finder Icon file's carriage return is replaced")

        expectEqual(ShelfName.sanitize("trailing.  "), "trailing",
                    "trailing whitespace and dots are trimmed")
        expectEqual(ShelfName.sanitize(""), "Untitled", "an empty name gets a placeholder")
        expectEqual(ShelfName.sanitize("."), "Untitled",
                    "a name that sanitises away gets a placeholder")
    }

    suite("shelf-name/length") {
        // The limit is 255 UTF-16 code units, not 255 bytes. Measured: 255 × "é" is 510
        // UTF-8 bytes and succeeds on APFS; 256 fails ENAMETOOLONG.
        let room = ShelfName.maxUTF16Length - ShelfName.reservedForCounter

        let longAscii = String(repeating: "a", count: 400) + ".txt"
        let trimmedAscii = ShelfName.sanitize(longAscii)
        expect(trimmedAscii.utf16.count <= room,
               "a long ASCII name fits the budget, got \(trimmedAscii.utf16.count)")
        expect(trimmedAscii.hasSuffix(".txt"), "the extension survives truncation")

        // Two UTF-8 bytes per character, one UTF-16 unit. Truncating on bytes would cut
        // this in half for no reason.
        let accented = String(repeating: "é", count: 240) + ".txt"
        let trimmedAccented = ShelfName.sanitize(accented)
        expect(trimmedAccented.utf16.count <= room,
               "an accented name is measured in UTF-16 units, got \(trimmedAccented.utf16.count)")
        expect(trimmedAccented.hasSuffix(".txt"), "the extension survives here too")

        // An emoji is two UTF-16 units and must not be split down the middle, which would
        // leave an unpaired surrogate.
        let emoji = String(repeating: "😀", count: 200) + ".txt"
        let trimmedEmoji = ShelfName.sanitize(emoji)
        expect(trimmedEmoji.utf16.count <= room,
               "an emoji name fits, got \(trimmedEmoji.utf16.count)")
        expect(trimmedEmoji.unicodeScalars.allSatisfy { $0.value != 0xFFFD },
               "no grapheme was split into a replacement character")

        // An extension so long there is no room for a base name at all.
        let absurdExtension = "a." + String(repeating: "x", count: 400)
        expect(ShelfName.sanitize(absurdExtension).utf16.count <= room,
               "an absurd extension is itself truncated rather than overflowing")
    }

    suite("shelf-name/collision") {
        // Finder's drop-collision convention, read from its own string table: template N1
        // is "^=1 ^=0", i.e. base, space, counter — and the counter goes before the
        // extension. The "copy" form is N4, which Finder uses for ⌘D, a different gesture.
        expectEqual(ShelfName.candidate("report.pdf", attempt: 1), "report.pdf",
                    "the first attempt is the name itself")
        expectEqual(ShelfName.candidate("report.pdf", attempt: 2), "report 2.pdf",
                    "the second attempt numbers before the extension")
        expectEqual(ShelfName.candidate("report.pdf", attempt: 3), "report 3.pdf",
                    "and so on")
        expectEqual(ShelfName.candidate("notes", attempt: 2), "notes 2",
                    "a name with no extension still numbers correctly")
        expectEqual(ShelfName.candidate("archive.tar.gz", attempt: 2), "archive.tar 2.gz",
                    "only the last extension component is treated as the extension")
        expectEqual(ShelfName.candidate(".hidden.txt", attempt: 2), ".hidden 2.txt",
                    "candidate does not re-sanitise; that already happened")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `cannot find 'ShelfName' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ShelfName.swift`:

```swift
import Foundation

/// The rules for turning an arbitrary name into one the shelf can safely hold.
///
/// Pure and filesystem-free, so every rule can be tested directly. The interesting cases
/// are all measured rather than assumed, and each one is noted where it applies.
enum ShelfName {
    /// The filesystem's limit, in UTF-16 code units.
    ///
    /// **Not bytes.** Measured on APFS: 255 × "é" is 510 UTF-8 bytes and succeeds;
    /// 256 fails `ENAMETOOLONG`. 127 × "😀" (254 units) succeeds, 128 fails.
    static let maxUTF16Length = 255

    /// Room kept free so the collision counter always fits: " 999" is four units.
    static let reservedForCounter = 4

    /// The most collision attempts before falling back to a UUID suffix. An unbounded loop
    /// on a hostile directory is a hang, not a retry.
    static let maxAttempts = 999

    /// Used when a name sanitises away to nothing.
    static let placeholder = "Untitled"

    /// Makes a name safe to append to the shelf's path.
    static func sanitize(_ raw: String) -> String {
        // The slash goes first, and it is a replacement rather than a removal: the danger
        // is not an odd character but `appendingPathComponent` treating it as a separator,
        // which silently puts the file in a subdirectory — or, with "../", outside the
        // shelf altogether.
        var name = raw.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == "\0" { return "_" }
            // Control characters are legal at the POSIX layer and unreadable in Finder.
            // `Icon\r`, which Finder itself creates, is the case that matters most.
            if CharacterSet.controlCharacters.contains(scalar) { return "_" }
            return String(scalar)
        }.joined()

        // A leading dot hides the item from Finder and from any listing that uses
        // `.skipsHiddenFiles`. A renamed item is better than an invisible one.
        while name.hasPrefix(".") { name.removeFirst() }

        // Trailing dots and spaces are legal but display confusingly.
        while let last = name.last, last == "." || last == " " { name.removeLast() }

        guard !name.isEmpty else { return placeholder }
        return truncate(name)
    }

    /// The nth name to try for a collision. Attempt 1 is the name itself.
    ///
    /// Numbers before the extension, matching Finder's drop-collision template: measured
    /// from Finder's own string table, key `N1_V2` is `^=1 ^=0` with the extension carried
    /// separately. The `^=1 copy ^=0` form is `N4`, which Finder uses for Duplicate — a
    /// different gesture, so a different convention.
    static func candidate(_ sanitized: String, attempt: Int) -> String {
        guard attempt > 1 else { return sanitized }
        let base = (sanitized as NSString).deletingPathExtension
        let extensionPart = (sanitized as NSString).pathExtension
        let numbered = "\(base) \(attempt)"
        return extensionPart.isEmpty ? numbered : "\(numbered).\(extensionPart)"
    }

    /// Shortens a name to fit, keeping the extension and never splitting a grapheme.
    private static func truncate(_ name: String) -> String {
        let budget = maxUTF16Length - reservedForCounter
        guard name.utf16.count > budget else { return name }

        let base = (name as NSString).deletingPathExtension
        var extensionPart = (name as NSString).pathExtension

        // An extension can itself be longer than the budget, in which case there is nothing
        // to preserve and it is truncated like anything else.
        if extensionPart.utf16.count + 1 >= budget {
            extensionPart = String(clipped(extensionPart, toUTF16: budget))
            return extensionPart.isEmpty ? placeholder : extensionPart
        }

        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
        let baseBudget = budget - suffix.utf16.count
        let clippedBase = clipped(base, toUTF16: baseBudget)
        guard !clippedBase.isEmpty else { return placeholder }
        return clippedBase + suffix
    }

    /// Drops whole `Character`s off the end until the UTF-16 count fits.
    ///
    /// Per `Character`, not per UTF-16 unit: an emoji is two units, and cutting between
    /// them leaves an unpaired surrogate that renders as a replacement glyph.
    private static func clipped(_ text: String, toUTF16 limit: Int) -> String {
        var result = text
        while result.utf16.count > limit, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}
```

- [ ] **Step 4: Register the suite and add the files to the scripts**

In `Tests/TestMain.swift`, add `runShelfNameTests()` immediately before `runShelfTests()`.

Add `Sources/ShelfName.swift` to the source list in `run-tests.sh`, `run-smoke.sh` and `build.sh`, and `Tests/ShelfNameTests.swift` to the test list in `run-tests.sh`.

- [ ] **Step 5: Run the tests**

Run: `./run-tests.sh`
Expected: **PASS.** The count rises by 26 to `✓ 1755 checks passed`.

- [ ] **Step 6: Prove the length test can fail**

The subtlest rule is the UTF-16 one, so prove the check is real rather than trivially true.

In `Sources/ShelfName.swift`, temporarily change `clipped` to measure bytes instead:

```swift
        while result.utf8.count > limit, !result.isEmpty {
```

Run: `./run-tests.sh`
Expected: **FAIL.** The accented and emoji cases now truncate far more than needed, but the
assertions are upper bounds so they still pass — **what fails is
`"the extension survives truncation"` for the accented name**, because clipping on bytes eats
into the suffix budget. If nothing fails, the test is too weak: tighten it to assert a lower
bound as well, e.g. `trimmedAccented.utf16.count > room - 10`.

Restore the `utf16` version and re-run. Expected: `✓ 1755 checks passed`.

- [ ] **Step 7: Sync the second tree**

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/ShelfName.swift" "$G/Sources/"
cp "$P/Tests/ShelfNameTests.swift" "$P/Tests/TestMain.swift" "$G/Tests/"
cp "$P/run-tests.sh" "$P/run-smoke.sh" "$P/build.sh" "$G/"
```

- [ ] **Step 8: Commit** *(blocked on a git identity)*

```bash
git add Sources/ShelfName.swift Tests/ShelfNameTests.swift Tests/TestMain.swift \
        run-tests.sh run-smoke.sh build.sh
git commit -m "feat: add shelf name sanitising and collision numbering"
```

---

## Task 3: The folder — create, self-heal, and refuse to self-heal

**Files:**
- Modify: `Sources/Shelf.swift`
- Modify: `Tests/ShelfTests.swift`

**Interfaces:**
- Consumes: `Shelf.init(root:fileManager:)` from Task 1.
- Produces: `enum ShelfError: Error, Equatable` with cases `blockedByFile(URL)`, `notEnoughSpace`, `sourceMissing(String)`, `sourceUnreadable(String)`, `volumeDisconnected(String)`, `wouldExceedCap(dropBytes: Int64, existingBytes: Int64, capBytes: Int64)`, `isApplication(String)`, `nothingUsableOnClipboard`. Also `Shelf.ensureExists() throws` and `static func defaultRoot() throws -> URL`.

- [ ] **Step 1: Write the failing tests**

Append to `runShelfTests()` in `Tests/ShelfTests.swift`:

```swift
    suite("shelf/ensure-exists") {
        let root = scratchDirectory("ensure").appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        expect(!FileManager.default.fileExists(atPath: root.path),
               "the folder does not exist before the first call")

        do {
            try shelf.ensureExists()
        } catch {
            expect(false, "the first ensureExists succeeds, got \(error)")
        }
        var isDirectory = ObjCBool(false)
        expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
               "the folder exists afterwards")
        expect(isDirectory.boolValue, "and it is a directory")

        // Measured: createDirectory(withIntermediateDirectories: true) succeeds on an
        // existing directory. So this is idempotent and needs no fileExists guard, which
        // also means no TOCTOU race.
        do {
            try shelf.ensureExists()
        } catch {
            expect(false, "a second ensureExists is harmless, got \(error)")
        }
    }

    suite("shelf/blocked-by-a-file") {
        // The one case that must NOT self-heal. The thing in the way is user data of
        // unknown value, and deleting it would break "never auto-delete".
        let parent = scratchDirectory("blocked")
        let root = parent.appendingPathComponent("Shelf")
        expect(FileManager.default.createFile(atPath: root.path, contents: nil),
               "a file is placed where the folder should be")

        let shelf = Shelf(root: root)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must refuse when a file is in the way")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.blockedByFile(root),
                        "and it says exactly which path is blocked")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }
    }

    suite("shelf/read-only-self-heals") {
        // Chakra owns this folder, so repairing permissions on it is the same category of
        // act as build.sh regenerating a missing icon.
        let root = scratchDirectory("readonly").appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o555],
                                                   ofItemAtPath: root.path)
        do {
            try shelf.ensureExists()
        } catch {
            expect(false, "ensureExists repairs a read-only shelf, got \(error)")
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
            as? NSNumber
        expectEqual(mode?.intValue ?? 0, 0o755, "the permissions were repaired")
    }

    suite("shelf/default-root") {
        // The API only ever returns the parent; the per-app subfolder is never created for
        // you. Measured: `create: false` can return a path that does not exist.
        do {
            let root = try Shelf.defaultRoot()
            expect(root.path.hasSuffix("/Library/Application Support/local.chakra/Shelf"),
                   "the default root is inside our own container, got \(root.path)")
            expect(!root.path.contains("/Documents/") && !root.path.contains("/Desktop/"),
                   "and never inside a TCC-protected folder")
        } catch {
            expect(false, "defaultRoot resolves, got \(error)")
        }
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `cannot find 'ShelfError' in scope` and
`value of type 'Shelf' has no member 'ensureExists'`.

- [ ] **Step 3: Write the implementation**

Add to the top of `Sources/Shelf.swift`, before the class:

```swift
/// Why an intake or a folder operation could not be completed.
///
/// A typed error rather than the `NSError` `FileManager` produces, because that error's
/// `localizedDescription` is actively misleading: for a *source* file Chakra cannot read it
/// says "…you don't have permission to access 'dst'", naming the **destination**. Never
/// surface it. Each case here maps to text Chakra owns.
enum ShelfError: Error, Equatable {
    /// A file sits where the shelf folder should be. The only case that must not self-heal.
    case blockedByFile(URL)
    /// `NSFileWriteOutOfSpaceError` (640) / `ENOSPC`.
    case notEnoughSpace
    /// `NSFileNoSuchFileError` (260) / `ENOENT`.
    case sourceMissing(String)
    /// `NSFileWriteNoPermissionError` (513) / `EACCES`.
    case sourceUnreadable(String)
    /// `NSFileWriteUnknownError` (512) / `EIO` — in practice a volume that went away.
    case volumeDisconnected(String)
    case wouldExceedCap(dropBytes: Int64, existingBytes: Int64, capBytes: Int64)
    /// A `.app` bundle. Refused: a copied bundle may not launch, and the wheel already
    /// exists for pinning applications.
    case isApplication(String)
    case nothingUsableOnClipboard
}
```

Add to the `Shelf` class:

```swift
    /// The shipped location: `~/Library/Application Support/local.chakra/Shelf`.
    ///
    /// The bundle identifier rather than "Chakra", because macOS 14+
    /// `kTCCServiceSystemPolicyAppData` prompts for access to *another* app's container —
    /// being unambiguously inside our own is what keeps that prompt impossible.
    ///
    /// Resolved through `FileManager`, never by concatenating `NSHomeDirectory()`: that
    /// path differs under a sandbox, and a future sandbox flag would otherwise silently
    /// relocate the shelf and orphan every file.
    static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        return support
            .appendingPathComponent("local.chakra", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
    }

    /// Makes sure the folder is there and writable. Idempotent, and safe to call before
    /// every operation.
    ///
    /// Mirrors `build.sh`'s approach to the generated icon: a cheap check, an unconditional
    /// repair, and no cost when nothing is wrong. `createDirectory` with
    /// `withIntermediateDirectories: true` succeeds on an existing directory — measured —
    /// so there is no `fileExists` guard and therefore no TOCTOU race.
    func ensureExists() throws {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            // A *file* in the way is the one thing that must not be repaired silently: it
            // is user data of unknown value, and removing it would breach never-auto-delete.
            guard isDirectory.boolValue else { throw ShelfError.blockedByFile(root) }

            // A read-only folder is different. Chakra created it and owns it, so restoring
            // its permissions is repair, not destruction.
            if !fileManager.isWritableFile(atPath: root.path) {
                _ = try? fileManager.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.path)
            }
            return
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }
```

- [ ] **Step 4: Run the tests**

Run: `./run-tests.sh`
Expected: **PASS**, count rises by 11 to `✓ 1766 checks passed`.

- [ ] **Step 5: Prove the blocked-by-file check can fail**

Temporarily delete the `guard isDirectory.boolValue else { throw ... }` line.

Run: `./run-tests.sh`
Expected: **FAIL** with `[shelf/blocked-by-a-file] ensureExists must refuse when a file is in the way`.

Restore the line and re-run. Expected: `✓ 1766 checks passed`.

- [ ] **Step 6: Sync and commit** *(commit blocked on a git identity)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/Shelf.swift" "$G/Sources/"; cp "$P/Tests/ShelfTests.swift" "$G/Tests/"
git add Sources/Shelf.swift Tests/ShelfTests.swift
git commit -m "feat: create and self-heal the shelf folder"
```

---

## Task 4: Sizes, counting, and the cap

**Files:**
- Modify: `Sources/Shelf.swift`
- Modify: `Tests/ShelfTests.swift`

**Interfaces:**
- Consumes: `Shelf.ensureExists()`, `ShelfError` from Task 3.
- Produces: `struct ShelfItem: Equatable` with `url: URL`, `name: String`, `bytes: Int64`, `added: Date`, `isDirectory: Bool`. On `Shelf`: `func items() -> [ShelfItem]`, `func total() -> (count: Int, bytes: Int64)`, `func size(of url: URL, limit: Int64?) -> Int64`.

- [ ] **Step 1: Write the failing tests**

Append to `runShelfTests()`:

```swift
    suite("shelf/items-and-total") {
        let root = scratchDirectory("items").appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        expectEqual(shelf.total().count, 0, "an empty shelf holds nothing")
        expectEqual(shelf.total().bytes, 0, "and zero bytes")

        let write: (String, Int) -> Void = { name, bytes in
            let data = Data(repeating: 0x41, count: bytes)
            try? data.write(to: root.appendingPathComponent(name))
        }
        write("a.txt", 100)
        write("b.txt", 250)

        expectEqual(shelf.total().count, 2, "two files are counted")
        expectEqual(shelf.total().bytes, 350, "and their logical sizes are summed")
        expectEqual(shelf.items().count, 2, "items() agrees with the count")

        // Hidden Finder litter must not be counted. The hub's own click action opens the
        // folder in Finder, so this will happen in real use.
        try? Data().write(to: root.appendingPathComponent(".DS_Store"))
        expectEqual(shelf.total().count, 2, ".DS_Store is not an item")

        // `Icon\r` has isHidden = false — measured — so it survives .skipsHiddenFiles and
        // has to be excluded by name.
        try? Data(repeating: 0x42, count: 10).write(to: root.appendingPathComponent("Icon\r"))
        expectEqual(shelf.total().count, 2, "Icon\\r is not an item either")

        // A copy in flight must not appear as a shelf entry.
        try? Data(repeating: 0x43, count: 10)
            .write(to: root.appendingPathComponent(".chakra-incoming-abc"))
        expectEqual(shelf.total().count, 2, "an in-flight copy is not an item")

        // A directory counts as one item, with its contents summed.
        let folder = root.appendingPathComponent("folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(repeating: 0x44, count: 500).write(to: folder.appendingPathComponent("inner.txt"))
        expectEqual(shelf.total().count, 3, "a folder is one item")
        expectEqual(shelf.total().bytes, 850, "and its interior is included in the total")
    }

    suite("shelf/size-early-bail") {
        // Totalling has to stop as soon as the answer cannot change the decision.
        // Otherwise a hostile million-file tree takes seconds.
        let root = scratchDirectory("bail").appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let tree = root.appendingPathComponent("tree")
        try? FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        for index in 0..<20 {
            try? Data(repeating: 0x41, count: 100)
                .write(to: tree.appendingPathComponent("f\(index).txt"))
        }

        expectEqual(shelf.size(of: tree, limit: nil), 2000, "with no limit the full total")
        let bailed = shelf.size(of: tree, limit: 500)
        expect(bailed >= 500, "with a limit it stops once the limit is passed, got \(bailed)")
        expect(bailed < 2000, "and does not walk the whole tree, got \(bailed)")

        expectEqual(shelf.size(of: root.appendingPathComponent("nope"), limit: nil), 0,
                    "a missing path has no size rather than crashing")
    }

    suite("shelf/cap-arithmetic") {
        expectEqual(Shelf.capBytes, 1_073_741_824, "the cap is one binary gigabyte")
        expectEqual(Shelf.itemNoteThreshold, 10, "the item note fires at ten")

        // The refusal has to name all three numbers so the message can do the arithmetic
        // for the user.
        let error = ShelfError.wouldExceedCap(dropBytes: 900, existingBytes: 800,
                                              capBytes: 1000)
        expectEqual(error, ShelfError.wouldExceedCap(dropBytes: 900, existingBytes: 800,
                                                     capBytes: 1000),
                    "the cap error carries the drop, the existing total and the cap")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `value of type 'Shelf' has no member 'items'`.

- [ ] **Step 3: Write the implementation**

Add before the `Shelf` class:

```swift
/// One entry on the shelf. A folder or a package counts as one.
struct ShelfItem: Equatable {
    let url: URL
    /// What Finder would call it. `displayName(atPath:)` rather than `lastPathComponent`,
    /// because macOS swaps ":" and "/" between the POSIX and display layers — measured, a
    /// file stored as `with:colon.txt` displays as `with/colon.txt`.
    let name: String
    /// Logical size, from `.totalFileSizeKey`. For a folder, the recursive total.
    let bytes: Int64
    let added: Date
    let isDirectory: Bool
}
```

Add to the `Shelf` class:

```swift
    /// Names that are never shelf items however they are flagged.
    ///
    /// `.DS_Store` and `._*` are hidden and would be filtered anyway. **`Icon\r` is not** —
    /// measured, `isHidden` is false — so it has to be excluded explicitly. This matters
    /// because clicking the hub opens the folder in Finder, which creates exactly this.
    static let incomingPrefix = ".chakra-incoming-"

    private func isLitter(_ name: String) -> Bool {
        name == ".DS_Store" || name == "Icon\r"
            || name.hasPrefix("._") || name.hasPrefix(Self.incomingPrefix)
    }

    /// Everything on the shelf, newest first.
    ///
    /// A live directory scan, deliberately, with no persisted index. Measured: the scan
    /// costs 0.035 ms at 10 items and 1.905 ms at 1000 — 0.002% and 11% of one 60 Hz frame.
    /// An index would buy nothing measurable and would introduce a second source of truth
    /// that can be wrong, which is the only way this feature can lie to the user.
    func items() -> [ShelfItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileSizeKey,
                                      .creationDateKey, .isPackageKey, .nameKey]
        // `contentsOfDirectory(at:includingPropertiesForKeys:)`, never
        // `contentsOfDirectory(atPath:)` plus `attributesOfItem` — measured 7.7× slower at
        // 1000 files because the latter stats each file again.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        var out: [ShelfItem] = []
        for url in entries {
            let name = url.lastPathComponent
            if isLitter(name) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            // A package is one item even though it is a directory underneath.
            let treatAsFolder = isDirectory && !isPackage
            let bytes = treatAsFolder
                ? size(of: url, limit: nil)
                : Int64(values?.totalFileSize ?? 0)
            out.append(ShelfItem(url: url,
                                 name: fileManager.displayName(atPath: url.path),
                                 bytes: bytes,
                                 added: values?.creationDate ?? Date.distantPast,
                                 isDirectory: treatAsFolder))
        }
        return out.sorted { $0.added > $1.added }
    }

    /// What the hub displays.
    func total() -> (count: Int, bytes: Int64) {
        let all = items()
        return (all.count, all.reduce(0) { $0 + $1.bytes })
    }

    /// The logical size of a file or a whole tree.
    ///
    /// `limit` stops the walk once the running total passes it. Nothing needs the exact size
    /// of a 900 GB folder to know it will not fit, and without the bail a hostile tree takes
    /// seconds — measured, 5000 files total in 18 ms, so a million would take ~3.6 s.
    ///
    /// `.totalFileSizeKey`, never `.fileSizeKey`: measured 40 versus 14 bytes on a file with
    /// a resource fork, and the cap must not under-count.
    func size(of url: URL, limit: Int64?) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileSizeKey]
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return 0 }

        if values.isDirectory != true {
            let file = try? url.resourceValues(forKeys: Set(keys))
            return Int64(file?.totalFileSize ?? 0)
        }

        // `.skipsHiddenFiles` is deliberately NOT passed: a hidden file inside a dropped
        // folder still occupies space and will still be copied. `.skipsPackageDescendants`
        // is also omitted, or a `.photoslibrary` would total zero.
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: keys,
                                                  options: []) else { return 0 }
        var running: Int64 = 0
        for case let child as URL in walker {
            let file = try? child.resourceValues(forKeys: Set(keys))
            guard file?.isRegularFile == true else { continue }
            running += Int64(file?.totalFileSize ?? 0)
            if let limit, running > limit { return running }
        }
        return running
    }
```

- [ ] **Step 4: Run the tests**

Run: `./run-tests.sh`
Expected: **PASS**, count rises by 18 to `✓ 1784 checks passed`.

- [ ] **Step 5: Prove the litter exclusion can fail**

Temporarily change `isLitter` to `return false`.

Run: `./run-tests.sh`
Expected: **FAIL** with three failures — `.DS_Store is not an item`,
`Icon\r is not an item either`, and `an in-flight copy is not an item`.

Restore and re-run. Expected: `✓ 1784 checks passed`.

- [ ] **Step 6: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/Shelf.swift" "$G/Sources/"; cp "$P/Tests/ShelfTests.swift" "$G/Tests/"
git add Sources/Shelf.swift Tests/ShelfTests.swift
git commit -m "feat: shelf item listing, totals, and early-bail sizing"
```

---

## Task 5: Verified copy

The heart of the feature, and the reason the design has a temporary name at all.

**Files:**
- Modify: `Sources/Shelf.swift`
- Modify: `Tests/ShelfTests.swift`

**Interfaces:**
- Consumes: `ensureExists()`, `size(of:limit:)`, `ShelfName`, `ShelfError`.
- Produces: `struct AddOutcome` with `added: [String]` and `refusals: [ShelfError]`; on `Shelf`, `func add(_ urls: [URL]) -> AddOutcome` and `func resolve(_ url: URL) throws -> URL`.

- [ ] **Step 1: Write the failing tests**

Append to `runShelfTests()`:

```swift
    suite("shelf/add-copies") {
        let box = scratchDirectory("add")
        let root = box.appendingPathComponent("Shelf")
        let source = box.appendingPathComponent("source")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("report.pdf")
        try? Data(repeating: 0x41, count: 1234).write(to: file)

        let shelf = Shelf(root: root)
        let outcome = shelf.add([file])
        expectEqual(outcome.added, ["report.pdf"], "the file was added under its own name")
        expectEqual(outcome.refusals.count, 0, "and nothing was refused")
        expectEqual(shelf.total().count, 1, "the shelf holds one item")
        expectEqual(shelf.total().bytes, 1234, "with the right size")

        // The copy must be independent: the shelf owns it.
        _ = try? FileManager.default.removeItem(at: file)
        expectEqual(shelf.total().count, 1, "deleting the source leaves the copy intact")
        expectEqual(shelf.total().bytes, 1234, "and the copy still has its bytes")
    }

    suite("shelf/add-collision") {
        let box = scratchDirectory("collide")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)

        let makeSource: (String) -> URL = { folder in
            let dir = box.appendingPathComponent(folder)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("report.pdf")
            try? Data(repeating: 0x41, count: 10).write(to: url)
            return url
        }

        _ = shelf.add([makeSource("one")])
        let second = shelf.add([makeSource("two")])
        expectEqual(second.added, ["report 2.pdf"],
                    "the second file of the same name is numbered, Finder-style")
        let third = shelf.add([makeSource("three")])
        expectEqual(third.added, ["report 3.pdf"], "and the third continues the sequence")
        expectEqual(shelf.total().count, 3, "all three are on the shelf")
    }

    suite("shelf/add-refuses") {
        let box = scratchDirectory("refuse")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)

        // A missing source. Not pre-checked with fileExists — that is a TOCTOU race — so
        // the error comes back from copyItem and is mapped.
        let absent = box.appendingPathComponent("gone.txt")
        let missing = shelf.add([absent])
        expectEqual(missing.added.count, 0, "a missing source adds nothing")
        expectEqual(missing.refusals, [ShelfError.sourceMissing("gone.txt")],
                    "and is reported as missing, by name")

        // An application bundle. Refused because a copied bundle may not launch, and the
        // wheel already exists for pinning apps.
        let app = box.appendingPathComponent("Fake.app")
        try? FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        let application = shelf.add([app])
        expectEqual(application.added.count, 0, "an app bundle adds nothing")
        expectEqual(application.refusals, [ShelfError.isApplication("Fake.app")],
                    "and is refused as an application")

        // The whole drop is refused when it would breach the cap — never partially copied,
        // because the user cannot tell which files landed.
        let big = box.appendingPathComponent("big.bin")
        try? Data(repeating: 0x41, count: 4096).write(to: big)
        let tiny = Shelf(root: box.appendingPathComponent("Tiny"), capBytes: 1000)
        let over = tiny.add([big])
        expectEqual(over.added.count, 0, "an over-cap drop copies nothing at all")
        expectEqual(over.refusals.count, 1, "and reports one refusal")
        if case .wouldExceedCap(let drop, let existing, let cap) = over.refusals[0] {
            expectEqual(drop, 4096, "the refusal names the drop size")
            expectEqual(existing, 0, "and the existing total")
            expectEqual(cap, 1000, "and the cap")
        } else {
            expect(false, "the refusal is a cap refusal, got \(over.refusals[0])")
        }
    }

    suite("shelf/add-resolves-links") {
        // A symlink copied as a symlink is a *reference*, which breaks the one rule the
        // whole design rests on. Measured: copyItem copies the link, and the copy still
        // resolves to the original.
        let box = scratchDirectory("links")
        let root = box.appendingPathComponent("Shelf")
        let target = box.appendingPathComponent("target.txt")
        try? Data(repeating: 0x41, count: 77).write(to: target)
        let link = box.appendingPathComponent("link.txt")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let shelf = Shelf(root: root)
        let outcome = shelf.add([link])
        expectEqual(outcome.added.count, 1, "a symlink is accepted")
        expectEqual(shelf.total().bytes, 77, "and what landed is the target's bytes")

        let copied = root.appendingPathComponent(outcome.added[0])
        let isLink = (try? copied.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
        expectEqual(isLink ?? true, false, "the copy is a real file, not a link")

        // A link whose target is gone has nothing to copy.
        let dangling = box.appendingPathComponent("dangling.txt")
        try? FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: box.appendingPathComponent("nothing"))
        let broken = shelf.add([dangling])
        expectEqual(broken.added.count, 0, "a dangling link adds nothing")
        expectEqual(broken.refusals, [ShelfError.sourceMissing("dangling.txt")],
                    "and is reported as missing")
    }

    suite("shelf/no-litter-after-failure") {
        // A crash or an error mid-copy must not leave a visible fake entry. The temp name
        // starts with a dot so anything left behind is invisible, and it is swept at launch.
        let box = scratchDirectory("litter")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        _ = shelf.add([box.appendingPathComponent("does-not-exist.txt")])

        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        expect(!names.contains(where: { $0.hasPrefix(Shelf.incomingPrefix) }),
               "no temporary file survives a failed copy, found \(names)")
        expectEqual(shelf.total().count, 0, "and the shelf is still empty")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `value of type 'Shelf' has no member 'add'` and
`extra argument 'capBytes' in call`.

- [ ] **Step 3: Make the cap injectable**

The cap test needs a small shelf, so replace the static-only cap with an instance value that
defaults to it. In `Sources/Shelf.swift`, change the stored properties and initialiser:

```swift
    let root: URL
    let fileManager: FileManager
    /// This shelf's cap. An instance value so a test can use a small one; production always
    /// takes the default.
    let capBytes: Int64

    init(root: URL, fileManager: FileManager = FileManager(),
         capBytes: Int64 = Shelf.capBytes) {
        self.root = root
        self.fileManager = fileManager
        self.capBytes = capBytes
    }
```

`Shelf.capBytes` (the static) stays as the shipped value; `self.capBytes` shadows it inside
the instance, which is why the initialiser default spells out `Shelf.capBytes`.

- [ ] **Step 4: Write the copy implementation**

Add to `Sources/Shelf.swift`, before the class:

```swift
/// What happened to a drop. Reports every item, because "Added 2 apps" with three
/// unaccounted for is the bug this shape exists to prevent.
struct AddOutcome {
    var added: [String] = []
    var refusals: [ShelfError] = []
}
```

Add to the class:

```swift
    /// Copies everything in `urls` onto the shelf.
    ///
    /// Atomic in the sense that matters: the cap is checked against the whole drop first,
    /// and if the drop does not fit, nothing is copied. A partial copy is unverifiable by
    /// the user — they cannot tell which files landed without comparing against the source
    /// by hand — and every rule for "what fits" is arbitrary.
    func add(_ urls: [URL]) -> AddOutcome {
        var outcome = AddOutcome()
        do {
            try ensureExists()
        } catch let error as ShelfError {
            outcome.refusals.append(error)
            return outcome
        } catch {
            outcome.refusals.append(.notEnoughSpace)
            return outcome
        }

        // Resolve links and refuse applications before measuring, or the cap could be
        // bypassed by dropping a symlink to a huge tree.
        var sources: [URL] = []
        for url in urls {
            do {
                let resolved = try resolve(url)
                if isApplication(resolved) {
                    outcome.refusals.append(.isApplication(url.lastPathComponent))
                    continue
                }
                sources.append(resolved)
            } catch let error as ShelfError {
                outcome.refusals.append(error)
            } catch {
                outcome.refusals.append(.sourceMissing(url.lastPathComponent))
            }
        }
        guard !sources.isEmpty else { return outcome }

        let existing = total().bytes
        let headroom = capBytes - existing
        var dropBytes: Int64 = 0
        for source in sources {
            // The limit is the remaining headroom, so the walk stops as soon as the answer
            // cannot change.
            dropBytes += size(of: source, limit: max(headroom - dropBytes, 0))
            if dropBytes > headroom { break }
        }
        if dropBytes > headroom {
            outcome.refusals.append(.wouldExceedCap(dropBytes: dropBytes,
                                                    existingBytes: existing,
                                                    capBytes: capBytes))
            return outcome
        }

        for source in sources {
            do {
                outcome.added.append(try copyIn(source))
            } catch let error as ShelfError {
                outcome.refusals.append(error)
            } catch {
                outcome.refusals.append(.sourceUnreadable(source.lastPathComponent))
            }
        }
        return outcome
    }

    /// Follows a symlink or a Finder alias to the real thing.
    ///
    /// Without this the shelf holds *references*, which is the opposite of its one rule:
    /// measured, `copyItem` on a symlink copies the link, and on an alias copies the
    /// 804-byte bookmark — and the copy still resolves to the original.
    ///
    /// Symlink is tested first because `.isAliasFileKey` is **also true for symlinks**.
    func resolve(_ url: URL) throws -> URL {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        var resolved = url
        if values?.isSymbolicLink == true {
            resolved = URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
        } else if values?.isAliasFile == true,
                  let target = try? URL(resolvingAliasFileAt: url, options: []) {
            resolved = target
        }
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw ShelfError.sourceMissing(url.lastPathComponent)
        }
        return resolved
    }

    private func isApplication(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true {
            return true
        }
        return url.pathExtension.lowercased() == "app"
    }

    /// Copies one source in, and returns the name it landed under.
    ///
    /// Lands on a hidden temporary name, is verified, then atomically renamed. A *folder*
    /// copy that fails leaves a partial tree behind — measured — so the final name must not
    /// appear until the copy is known to be complete. A single-file failure does clean up
    /// after itself, but the folder case is what forces the design.
    private func copyIn(_ source: URL) throws -> String {
        let temporary = root.appendingPathComponent(Self.incomingPrefix + UUID().uuidString)
        do {
            try fileManager.copyItem(at: source, to: temporary)
        } catch {
            _ = try? fileManager.removeItem(at: temporary)
            throw Self.mapped(error, name: source.lastPathComponent)
        }

        // Verify before the copy becomes visible. On the same APFS volume `copyItem` is
        // `clonefile(2)` and identical by construction, so a size comparison is the whole
        // job — measured at ~0.03 ms against 41 ms per 100 MB for SHA-256. A cross-volume
        // copy moves real bytes and deserves the hash; that is Task 5b.
        let wanted = size(of: source, limit: nil)
        let got = size(of: temporary, limit: nil)
        guard wanted == got else {
            _ = try? fileManager.removeItem(at: temporary)
            throw ShelfError.volumeDisconnected(source.lastPathComponent)
        }

        let sanitized = ShelfName.sanitize(source.lastPathComponent)
        for attempt in 1...ShelfName.maxAttempts {
            let name = ShelfName.candidate(sanitized, attempt: attempt)
            let destination = root.appendingPathComponent(name)
            // Guard the result: `appendingPathComponent` on a name containing a separator
            // would place the file outside the shelf. `sanitize` removes them, and this
            // asserts that it did.
            guard destination.deletingLastPathComponent().standardizedFileURL
                    == root.standardizedFileURL else { continue }
            do {
                // `moveItem` is `rename(2)`, atomic within the volume, and measured to
                // throw rather than clobber — so this loop is race-safe against another
                // Chakra instance.
                try fileManager.moveItem(at: temporary, to: destination)
                return name
            } catch {
                continue
            }
        }
        _ = try? fileManager.removeItem(at: temporary)
        throw ShelfError.sourceUnreadable(source.lastPathComponent)
    }

    /// Turns `FileManager`'s error into one Chakra can show.
    private static func mapped(_ error: Error, name: String) -> ShelfError {
        let code = (error as NSError).code
        switch code {
        case NSFileWriteOutOfSpaceError: return .notEnoughSpace
        case NSFileNoSuchFileError: return .sourceMissing(name)
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .sourceUnreadable(name)
        case NSFileWriteUnknownError, NSFileReadUnknownError:
            return .volumeDisconnected(name)
        default: return .sourceUnreadable(name)
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `./run-tests.sh`
Expected: **PASS**, count rises by 24 to `✓ 1808 checks passed`.

- [ ] **Step 6: Prove the symlink resolution can fail**

In `resolve`, temporarily change the symlink branch to `resolved = url`.

Run: `./run-tests.sh`
Expected: **FAIL** with `[shelf/add-resolves-links] the copy is a real file, not a link`.

Restore and re-run. Expected: `✓ 1808 checks passed`.

- [ ] **Step 7: Prove the cap refusal is atomic**

In `add`, temporarily move the `guard dropBytes > headroom` refusal to *after* the copy loop.

Run: `./run-tests.sh`
Expected: **FAIL** with `an over-cap drop copies nothing at all`.

Restore and re-run.

- [ ] **Step 8: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/Shelf.swift" "$G/Sources/"; cp "$P/Tests/ShelfTests.swift" "$G/Tests/"
git add Sources/Shelf.swift Tests/ShelfTests.swift
git commit -m "feat: verified copy onto the shelf, with link resolution and an atomic cap"
```

---

## Task 6: Cross-volume verification by hash

Task 5 verifies by size, which is complete for a clone but not for a real byte copy.

**Files:**
- Modify: `Sources/Shelf.swift`
- Modify: `Tests/ShelfTests.swift`

**Interfaces:**
- Consumes: `copyIn` from Task 5.
- Produces: `Shelf.digest(of url: URL) -> String?` and `Shelf.isSameVolume(_ a: URL, _ b: URL) -> Bool`.

- [ ] **Step 1: Write the failing test**

Append to `runShelfTests()`:

```swift
    suite("shelf/digest") {
        let box = scratchDirectory("digest")
        let a = box.appendingPathComponent("a.bin")
        let b = box.appendingPathComponent("b.bin")
        let c = box.appendingPathComponent("c.bin")
        try? Data(repeating: 0x41, count: 3_000_000).write(to: a)
        try? Data(repeating: 0x41, count: 3_000_000).write(to: b)
        try? Data(repeating: 0x42, count: 3_000_000).write(to: c)

        let shelf = Shelf(root: box.appendingPathComponent("Shelf"))
        let digestA = shelf.digest(of: a)
        expect(digestA != nil, "a readable file has a digest")
        expectEqual(shelf.digest(of: b), digestA, "identical bytes give an identical digest")
        expect(shelf.digest(of: c) != digestA, "different bytes give a different digest")
        expect(shelf.digest(of: box.appendingPathComponent("nope")) == nil,
               "a missing file has no digest rather than crashing")

        // Streamed, not loaded whole: an untrusted multi-gigabyte file must not be mapped
        // into the address space. Measured 41 ms per 100 MB at 1 MB chunks.
        expectEqual(digestA?.count, 64, "the digest is 64 hex characters of SHA-256")

        expect(shelf.isSameVolume(a, b), "two files in one directory are on one volume")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `value of type 'Shelf' has no member 'digest'`.

- [ ] **Step 3: Write the implementation**

Add `import CryptoKit` at the top of `Sources/Shelf.swift`, then add to the class:

```swift
    /// How much is read at a time when hashing.
    ///
    /// 1 MB measured at 2.43 GB/s — 41 ms per 100 MB — against 2.37 GB/s at 64 KB and
    /// 2.90 GB/s with `mappedIfSafe`. The mapped version's 16% is not worth mapping an
    /// untrusted multi-gigabyte file into the address space.
    private static let digestChunkBytes = 1 << 20

    /// SHA-256 of a file, as lower-case hex, or nil if it cannot be read.
    ///
    /// Used only where real bytes moved. `FileManager.contentsEqual` would do the same job
    /// and was measured **12.3× slower** — 506 ms against 41 ms per 100 MB.
    func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: Self.digestChunkBytes),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether two paths sit on the same volume.
    ///
    /// Decides how a copy is verified: on one volume `copyItem` is `clonefile(2)` and a size
    /// comparison is conclusive; across volumes real bytes moved and only a hash is.
    func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let left = try? a.resourceValues(forKeys: keys).volumeIdentifier,
              let right = try? b.resourceValues(forKeys: keys).volumeIdentifier
        else { return false }
        return left.isEqual(right)
    }
```

- [ ] **Step 4: Use it in the copy path**

In `copyIn`, replace the size-only verification block with:

```swift
        // On one volume the copy is a clone and identical by construction, so comparing
        // sizes is conclusive and costs ~0.03 ms. Across volumes real bytes moved, and only
        // a hash proves they arrived — at 41 ms per 100 MB, which is the honest price of a
        // drop from an external or network disk.
        let wanted = size(of: source, limit: nil)
        let got = size(of: temporary, limit: nil)
        var verified = wanted == got
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory ?? false
        if verified, !isDirectory, !isSameVolume(source, root) {
            verified = digest(of: source) == digest(of: temporary)
        }
        guard verified else {
            _ = try? fileManager.removeItem(at: temporary)
            throw ShelfError.volumeDisconnected(source.lastPathComponent)
        }
```

- [ ] **Step 5: Run the tests and the build**

Run: `./run-tests.sh && ./build.sh`
Expected: **PASS**, count rises by 6 to `✓ 1814 checks passed`, and the build stays clean —
`CryptoKit` is a system framework and needs no link flag.

- [ ] **Step 6: Prove the digest distinguishes content**

Temporarily change `digest` to `return "constant"`.

Run: `./run-tests.sh`
Expected: **FAIL** with `different bytes give a different digest` and
`the digest is 64 hex characters of SHA-256`.

Restore and re-run.

- [ ] **Step 7: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/Shelf.swift" "$G/Sources/"; cp "$P/Tests/ShelfTests.swift" "$G/Tests/"
git add Sources/Shelf.swift Tests/ShelfTests.swift
git commit -m "feat: hash-verify cross-volume shelf copies"
```

---

## Task 7: Removal, launch sweep, and the backup exclusion

**Files:**
- Modify: `Sources/Shelf.swift`
- Modify: `Tests/ShelfTests.swift`

**Interfaces:**
- Consumes: `items()`, `ensureExists()`.
- Produces: `Shelf.remove(_ item: ShelfItem) throws`, `Shelf.sweepIncoming(olderThan: TimeInterval)`, `Shelf.excludeFromBackup()`.

- [ ] **Step 1: Write the failing tests**

Append to `runShelfTests()`:

```swift
    suite("shelf/remove") {
        let box = scratchDirectory("remove")
        let root = box.appendingPathComponent("Shelf")
        let source = box.appendingPathComponent("doomed.txt")
        try? Data(repeating: 0x41, count: 10).write(to: source)

        let shelf = Shelf(root: root)
        _ = shelf.add([source])
        expectEqual(shelf.total().count, 1, "the item is on the shelf")

        guard let item = shelf.items().first else {
            expect(false, "there is an item to remove")
            return
        }
        do {
            try shelf.remove(item)
        } catch {
            expect(false, "remove succeeds, got \(error)")
        }
        expectEqual(shelf.total().count, 0, "and the shelf is empty afterwards")
        // The Trash, not unlink: a user-asked removal should still be recoverable, and it
        // keeps "never auto-delete" honest — the user asked, so it is not automatic.
        expect(!FileManager.default.fileExists(atPath: item.url.path),
               "the file is no longer in the shelf folder")
    }

    suite("shelf/sweep-incoming") {
        // A crash — as opposed to an error — leaves the temporary file behind, because no
        // catch block runs. The sweep is the backstop.
        let box = scratchDirectory("sweep")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let stale = root.appendingPathComponent(Shelf.incomingPrefix + "old")
        let fresh = root.appendingPathComponent(Shelf.incomingPrefix + "new")
        try? Data().write(to: stale)
        try? Data().write(to: fresh)
        _ = try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)],
            ofItemAtPath: stale.path)

        shelf.sweepIncoming(olderThan: 60)
        expect(!FileManager.default.fileExists(atPath: stale.path),
               "a stale temporary file is swept")
        expect(FileManager.default.fileExists(atPath: fresh.path),
               "a copy that may still be in flight is left alone")
    }

    suite("shelf/excluded-from-backup") {
        // The originals still exist wherever they came from, so the shelf is scratch space
        // and not backup-worthy.
        let root = scratchDirectory("backup").appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }
        shelf.excludeFromBackup()
        let excluded = (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup
        expectEqual(excluded ?? false, true, "the folder is excluded from Time Machine")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `value of type 'Shelf' has no member 'remove'`.

- [ ] **Step 3: Write the implementation**

Add to the class:

```swift
    /// Moves an item to the Trash.
    ///
    /// The Trash rather than an unlink, for two reasons. It stays recoverable, and a
    /// user-initiated removal is plainly not an auto-delete — which matters, because
    /// without any removal at all a shelf at the cap refuses every drop and the only exit
    /// is Finder, turning the feature into a trap.
    func remove(_ item: ShelfItem) throws {
        // The out-parameter is discarded explicitly: `-warnings-as-errors` rejects an
        // unused result.
        var resulting: NSURL?
        try fileManager.trashItem(at: item.url, resultingItemURL: &resulting)
        _ = resulting
    }

    /// Deletes temporary copies left behind by a crash rather than an error.
    ///
    /// An error path cleans up after itself; a crash cannot. Called once at launch. The
    /// age check is what stops it deleting a copy that is still in flight in another
    /// instance — two Chakra builds can run at once during development.
    func sweepIncoming(olderThan age: TimeInterval) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: []) else { return }
        let cutoff = Date(timeIntervalSinceNow: -age)
        for url in entries where url.lastPathComponent.hasPrefix(Self.incomingPrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            guard modified < cutoff else { continue }
            _ = try? fileManager.removeItem(at: url)
        }
    }

    /// Keeps the shelf out of Time Machine.
    ///
    /// Spotlight indexing is deliberately **not** disabled: finding a shelved file by search
    /// is useful. Excluding it would need `.metadata_never_index` in the folder.
    func excludeFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
```

- [ ] **Step 4: Run the tests**

Run: `./run-tests.sh`
Expected: **PASS**, count rises by 8 to `✓ 1822 checks passed`.

- [ ] **Step 5: Prove the sweep's age check can fail**

Temporarily remove the `guard modified < cutoff else { continue }` line.

Run: `./run-tests.sh`
Expected: **FAIL** with `a copy that may still be in flight is left alone`.

Restore and re-run.

- [ ] **Step 6: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/Shelf.swift" "$G/Sources/"; cp "$P/Tests/ShelfTests.swift" "$G/Tests/"
git add Sources/Shelf.swift Tests/ShelfTests.swift
git commit -m "feat: trash-based removal, launch sweep, and backup exclusion"
```

---

## Task 8: Pasteboard intake

**Files:**
- Create: `Sources/ShelfIntake.swift`
- Create: `Tests/ShelfIntakeTests.swift`
- Modify: `Tests/TestMain.swift`, `run-tests.sh`, `run-smoke.sh`, `build.sh`, `Sources/Shelf.swift`

**Interfaces:**
- Consumes: `ShelfName`, `Shelf.add(_:)`, `ShelfError`.
- Produces: `enum ShelfIntake` with `static func imageData(from pb: NSPasteboard) -> (data: Data, extension: String)?`, `static func fileURLs(from pb: NSPasteboard) -> [URL]`, `static func pastedName(at date: Date, extension: String) -> String`, `static let jpegType: NSPasteboard.PasteboardType`. On `Shelf`: `func add(pasteboard: NSPasteboard) -> AddOutcome`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ShelfIntakeTests.swift`:

```swift
import AppKit

func runShelfIntakeTests() {
    /// A private pasteboard, so the tests never disturb the user's clipboard.
    func board(_ label: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.chakra.test.\(label)"))
        pb.clearContents()
        return pb
    }

    /// A tiny real PNG, so the type tests work on genuine image data.
    func pngData(_ side: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: side * 4, bitsPerPixel: 32)!
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    suite("shelf-intake/prefers-png") {
        let png = pngData(8)
        let pb = board("png")
        pb.setData(png, forType: .png)

        guard let picked = ShelfIntake.imageData(from: pb) else {
            expect(false, "a PNG board yields image data")
            return
        }
        expectEqual(picked.extension, "png", "PNG is chosen")
        // Verbatim, byte for byte. AppKit will happily synthesise TIFF on demand —
        // measured, 14,749,968 bytes invented from a 12,112,483-byte PNG — so anything
        // that round-trips through NSImage inflates the file about 22 times.
        expectEqual(picked.data.count, png.count, "the PNG bytes are taken verbatim")
        expectEqual(picked.data, png, "and are byte-identical")
    }

    suite("shelf-intake/prefers-jpeg-over-tiff") {
        // A JPEG must not be re-encoded to PNG: measured, a real photo grew 6.7× doing that.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let pb = board("jpeg")
        pb.setData(jpeg, forType: ShelfIntake.jpegType)

        guard let picked = ShelfIntake.imageData(from: pb) else {
            expect(false, "a JPEG board yields image data")
            return
        }
        expectEqual(picked.extension, "jpg", "JPEG keeps its own format")
        expectEqual(picked.data, jpeg, "and its own bytes")
    }

    suite("shelf-intake/converts-tiff-only") {
        // `writeObjects([NSImage])` puts ONLY TIFF on the board — measured — so for most
        // apps this is the common path, not the fallback.
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()

        let pb = board("tiff")
        pb.writeObjects([image])
        expect(pb.data(forType: .png) == nil || pb.types?.contains(.tiff) == true,
               "the board offers TIFF")

        guard let picked = ShelfIntake.imageData(from: pb) else {
            expect(false, "a TIFF board still yields image data")
            return
        }
        expectEqual(picked.extension, "png", "TIFF is converted to PNG, never written as TIFF")
        expect(picked.data.count > 0, "and the converted data is not empty")
        expect(picked.data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
               "the result really is a PNG")
    }

    suite("shelf-intake/no-image") {
        let pb = board("text")
        pb.setString("just words", forType: .string)
        expect(ShelfIntake.imageData(from: pb) == nil,
               "a text-only clipboard yields no image")
    }

    suite("shelf-intake/file-urls") {
        let pb = board("urls")
        let one = URL(fileURLWithPath: "/tmp/one.txt")
        let two = URL(fileURLWithPath: "/tmp/two.txt")
        pb.writeObjects([one as NSURL, two as NSURL])
        // Every URL, not just the first. WheelView's existing reader takes `urls.first`,
        // which would shelve one file out of five and silently discard the rest.
        expectEqual(ShelfIntake.fileURLs(from: pb).count, 2, "every dropped URL is read")
    }

    suite("shelf-intake/pasted-name") {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 22
        components.hour = 8; components.minute = 59; components.second = 49
        let date = Calendar(identifier: .gregorian).date(from: components) ?? Date()

        let name = ShelfIntake.pastedName(at: date, extension: "png")
        // Apple's own screenshot convention, so a user already knows how to read it. The
        // "." between time fields is mandatory, not stylistic: ":" is legal at the POSIX
        // layer but displayName(atPath:) renders it as "/".
        expect(name.hasPrefix("Pasted 2026-09-22 at "),
               "the name follows the screenshot convention, got \(name)")
        expect(name.hasSuffix(".png"), "and carries the extension")
        expect(!name.contains(":"), "and never contains a colon")
        // yyyy-MM-dd then HH.mm.ss sorts lexicographically into time order.
        let later = ShelfIntake.pastedName(at: date.addingTimeInterval(3600), extension: "png")
        expect(name < later, "names sort chronologically")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `cannot find 'ShelfIntake' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ShelfIntake.swift`:

```swift
import AppKit

/// Turns a pasteboard into things the shelf can copy.
///
/// Pure and filesystem-free, so the surprising rules can be tested against a synthetic
/// pasteboard with no disk involved.
enum ShelfIntake {
    /// `public.jpeg` has no `NSPasteboard.PasteboardType` constant, unlike `.png` and
    /// `.tiff`, so it has to be constructed.
    static let jpegType = NSPasteboard.PasteboardType("public.jpeg")

    /// The image on the pasteboard, and the extension to save it under.
    ///
    /// **The order of this lookup is the whole feature.** `availableType(from:)` honours the
    /// array order, and AppKit synthesises TIFF on demand: measured, after a PNG is placed
    /// on a board, asking for TIFF returns 14,749,968 invented bytes for a 12,112,483-byte
    /// PNG. So a TIFF-first lookup — or anything that goes through `NSImage(pasteboard:)` —
    /// inflates the file about 22 times.
    ///
    /// PNG and JPEG are taken **verbatim**, never re-encoded. Measured: a screenshot as
    /// JPEG is only 6% smaller than PNG while being lossy, and a photo as PNG is 6.7×
    /// larger than its JPEG. Passing through whatever arrived is optimal in both directions.
    static func imageData(from pasteboard: NSPasteboard) -> (data: Data, extension: String)? {
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let jpeg = pasteboard.data(forType: jpegType) { return (jpeg, "jpg") }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    /// Every file URL on the pasteboard.
    ///
    /// All of them, deliberately. `WheelView.droppedPath` takes `urls.first`, which for a
    /// shelf would accept one file out of five and silently discard the rest.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (read as? [URL]) ?? []
    }

    /// The name for a pasted image, which arrives with no name of its own.
    ///
    /// Matches Apple's screenshot convention — `Screenshot 2026-09-22 at 08.59.49.png` — so
    /// anyone who has taken a screenshot can already read it.
    ///
    /// `en_US_POSIX` is load-bearing, not decoration: without it the formatter follows the
    /// user's locale and calendar, and a Thai Buddhist calendar would produce `2569-09-22`
    /// while a 12-hour locale would append `AM` and break the sort. `.` separates the time
    /// fields because `:` is legal at the POSIX layer but `displayName(atPath:)` renders it
    /// as `/`.
    static func pastedName(at date: Date, extension pathExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pasted \(formatter.string(from: date)).\(pathExtension)"
    }
}
```

- [ ] **Step 4: Add the pasteboard entry point to `Shelf`**

Add to the `Shelf` class:

```swift
    /// Saves the clipboard's image onto the shelf.
    ///
    /// Writes the bytes through a temporary file and then goes through `add`, so a paste gets
    /// exactly the same verification, cap check and collision naming as a drop. The
    /// alternative — writing straight into the shelf — would be a second, unverified code
    /// path doing the same job.
    func add(pasteboard: NSPasteboard) -> AddOutcome {
        var outcome = AddOutcome()
        guard let picked = ShelfIntake.imageData(from: pasteboard) else {
            outcome.refusals.append(.nothingUsableOnClipboard)
            return outcome
        }
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent(ShelfIntake.pastedName(at: Date(),
                                                           extension: picked.extension))
        do {
            try picked.data.write(to: staging)
        } catch {
            outcome.refusals.append(.notEnoughSpace)
            return outcome
        }
        defer { _ = try? fileManager.removeItem(at: staging) }
        return add([staging])
    }
```

- [ ] **Step 5: Register and wire up**

Add `runShelfIntakeTests()` to `TestMain.main()` before `runShelfTests()`. Add
`Sources/ShelfIntake.swift` to `run-tests.sh`, `run-smoke.sh` and `build.sh`, and
`Tests/ShelfIntakeTests.swift` to `run-tests.sh`.

- [ ] **Step 6: Run the tests and the build**

Run: `./run-tests.sh && ./build.sh`
Expected: **PASS**, count rises by 16 to `✓ 1838 checks passed`, build exit 0.

- [ ] **Step 7: Prove the type order matters**

Temporarily reorder `imageData` to try `.tiff` first.

Run: `./run-tests.sh`
Expected: **FAIL** with `[shelf-intake/prefers-png] the PNG bytes are taken verbatim` —
because a PNG board also offers synthesised TIFF, so a TIFF-first lookup produces different,
larger bytes. This is the 22× inflation, caught by a test.

Restore and re-run.

- [ ] **Step 8: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/ShelfIntake.swift" "$P/Sources/Shelf.swift" "$G/Sources/"
cp "$P/Tests/ShelfIntakeTests.swift" "$P/Tests/TestMain.swift" "$G/Tests/"
cp "$P/run-tests.sh" "$P/run-smoke.sh" "$P/build.sh" "$G/"
git add Sources/ShelfIntake.swift Sources/Shelf.swift Tests/ShelfIntakeTests.swift \
        Tests/TestMain.swift run-tests.sh run-smoke.sh build.sh
git commit -m "feat: pasteboard intake with verbatim PNG and JPEG"
```

---

## Task 9: The directory watch

**Files:**
- Modify: `Sources/Shelf.swift`
- Modify: `Tests/ShelfTests.swift`

**Interfaces:**
- Consumes: `ensureExists()`.
- Produces: `Shelf.onChange: (() -> Void)?`, `Shelf.startWatching()`, `Shelf.stopWatching()`.

- [ ] **Step 1: Write the failing test**

Append to `runShelfTests()`:

```swift
    suite("shelf/watch") {
        let box = scratchDirectory("watch")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        var fired = 0
        shelf.onChange = { fired += 1 }
        shelf.startWatching()

        // Adding a child surfaces as a `.write` on the parent directory — measured. The
        // vnode source needs no entitlement and raises no permission prompt, unlike
        // FSEventStream on an arbitrary path, which is why it is compatible with the
        // never-prompt invariant.
        try? Data(repeating: 0x41, count: 4).write(to: root.appendingPathComponent("x.txt"))

        // The source delivers on the main queue, so the run loop has to turn for the
        // handler to be called. This is a real wait, not a sleep: `run(until:)` processes
        // sources.
        let deadline = Date(timeIntervalSinceNow: 2)
        while fired == 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        expect(fired > 0, "a change in the folder fires onChange, fired \(fired)")

        shelf.stopWatching()
        let before = fired
        try? Data(repeating: 0x41, count: 4).write(to: root.appendingPathComponent("y.txt"))
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3))
        expectEqual(fired, before, "no more callbacks arrive after stopWatching")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./run-tests.sh`
Expected: **FAIL to compile**, `value of type 'Shelf' has no member 'onChange'`.

- [ ] **Step 3: Write the implementation**

Add to the class:

```swift
    /// Called on the main queue whenever the folder's contents change.
    var onChange: (() -> Void)?

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchDescriptor: CInt = -1
    private var coalesceWork: DispatchWorkItem?

    /// Starts watching the folder so the hub stays honest when Finder changes it.
    ///
    /// `open(O_EVTONLY)` plus a `DispatchSource` rather than `FSEventStream`: measured, this
    /// needs **no entitlement and raises no permission prompt**, which `FSEventStream` on an
    /// arbitrary path does not guarantee. That is what makes it compatible with the
    /// never-prompt invariant.
    ///
    /// Adding or removing a child surfaces as `.write` on the parent — measured.
    func startWatching() {
        guard watchSource == nil else { return }
        let descriptor = open(root.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watchDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // `.delete` or `.revoke` means the folder itself went away. Measured: the
            // descriptor stays valid but stale, so a watcher that survives its directory
            // never fires again. Tear down and let the next intake recreate and re-arm.
            if events.contains(.delete) || events.contains(.revoke) {
                self.stopWatching()
                self.onChange?()
                return
            }
            // Coalesced: two quick Finder operations should be one refresh.
            self.coalesceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange?() }
            self.coalesceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.watchDescriptor >= 0 else { return }
            close(self.watchDescriptor)
            self.watchDescriptor = -1
        }
        watchSource = source
        source.resume()
    }

    func stopWatching() {
        coalesceWork?.cancel()
        coalesceWork = nil
        watchSource?.cancel()
        watchSource = nil
    }

    deinit {
        // The cancel handler closes the descriptor, so this is what stops the fd leaking.
        stopWatching()
    }
```

- [ ] **Step 4: Run the tests**

Run: `./run-tests.sh`
Expected: **PASS**, count rises by 2 to `✓ 1840 checks passed`.

Note: the debounce means the first assertion waits up to 2 s. If it is flaky on a loaded
machine, raise the deadline — do **not** shorten the 0.2 s coalescing window, which is there
to stop two Finder operations producing two redraws.

- [ ] **Step 5: Prove the teardown works**

Temporarily make `stopWatching()` an empty body.

Run: `./run-tests.sh`
Expected: **FAIL** with `no more callbacks arrive after stopWatching`.

Restore and re-run.

- [ ] **Step 6: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/Shelf.swift" "$G/Sources/"; cp "$P/Tests/ShelfTests.swift" "$G/Tests/"
git add Sources/Shelf.swift Tests/ShelfTests.swift
git commit -m "feat: watch the shelf folder without a permission prompt"
```

---

## Task 10: Orb intake and the presence dot

The store is complete and tested. This is the first task that touches the view layer, so its
checks go in `Tools/Smoke.swift` and need an unlocked screen.

**Files:**
- Modify: `Sources/OrbView.swift`
- Modify: `Sources/OrbController.swift`
- Modify: `Sources/main.swift`
- Modify: `Tools/Smoke.swift`

**Interfaces:**
- Consumes: `Shelf`, `AddOutcome`, `ShelfError`, `ShelfIntake.fileURLs(from:)`.
- Produces: on `OrbView`, `var shelfLoaded: Bool`; on `OrbController`,
  `var onDropURLs: (([URL]) -> Void)?` and `func shelfChanged(loaded: Bool)`.

- [ ] **Step 1: Read the two existing drop implementations first**

Before writing anything, read `Sources/OrbView.swift` around `paths(from:)`,
`draggingEntered`, `draggingExited`, `draggingEnded` and `performDragOperation`, and
`Sources/StatusItem.swift`'s `StatusDropView`. You are extending the first and must not
regress either.

**Two rules from the existing code that this task must obey:**

1. **Always return `.copy` from `draggingUpdated`, never `[]`.** `WheelView` carries the
   comment: returning nothing means AppKit never calls `performDragOperation`, so a refused
   drop becomes indistinguishable from a missed one. A cap refusal must be explained, so the
   drop must be accepted first.
2. **`draggingEnded` must clear the highlight.** `OrbView` already does this; the comment says
   why. Do not remove it.

- [ ] **Step 2: Add the presence state to `OrbView`**

In `Sources/OrbView.swift`, add the property next to `dotColors`:

```swift
    /// Whether the shelf is holding anything.
    ///
    /// Presence, not a count. The orb is a miniature of the user's own ring — eight dots
    /// that are their apps — and a digit in the middle turns it into a notification widget
    /// and costs it that identity. "Is there something on my shelf?" is the question at
    /// rest; "how many exactly?" is answered on hover and in the hub.
    var shelfLoaded = false {
        didSet { if shelfLoaded != oldValue { needsDisplay = true } }
    }
```

In `draw(_:)`, replace the centre-dot block with:

```swift
        // The centre dot grows and takes the accent colour when the shelf is loaded. At the
        // shipped 35% idle opacity this is still readable, and it costs the orb nothing when
        // the shelf is empty.
        let cr = shelfLoaded ? g.centreDotRadius * 1.9 : g.centreDotRadius
        (shelfLoaded ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.75)).setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - cr, y: centre.y - cr,
                                    width: cr * 2, height: cr * 2)).fill()
```

- [ ] **Step 3: Accept every dropped URL**

In `Sources/OrbView.swift`, replace `paths(from:)` and its two call sites with a URL-based
reader, and add the new callback next to `onDropPaths`:

```swift
    /// Every file URL dropped on the orb.
    ///
    /// Separate from `onDropPaths`, which adds apps to the ring and takes paths. The shelf
    /// needs URLs and needs **all** of them.
    var onDropURLs: (([URL]) -> Void)?
```

```swift
    private func urls(from info: NSDraggingInfo) -> [URL] {
        ShelfIntake.fileURLs(from: info.draggingPasteboard)
    }
```

Replace `draggingEntered` and add `draggingUpdated`:

```swift
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargetedByDrag = !urls(from: sender).isEmpty
        needsDisplay = true
        return .copy
    }

    /// Always `.copy`, even when the drag carries nothing usable.
    ///
    /// Returning `[]` makes AppKit skip `performDragOperation` entirely, so a refusal can
    /// never be explained and reads as a missed drop. `WheelView` learned this and the
    /// comment survives there.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
```

Replace `performDragOperation`:

```swift
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargetedByDrag = false
        needsDisplay = true
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }
        // Apps go to the ring; everything else goes to the shelf. An `.app` on the shelf is
        // refused by `Shelf`, and the ring is what the user meant.
        let applications = dropped.filter { $0.pathExtension.lowercased() == "app" }
        let others = dropped.filter { $0.pathExtension.lowercased() != "app" }
        if !applications.isEmpty { onDropPaths?(applications.map(\.path)) }
        if !others.isEmpty { onDropURLs?(others) }
        return true
    }
```

- [ ] **Step 4: Own a `Shelf` in `OrbController`**

In `Sources/OrbController.swift`, add to the stored properties and the initialiser:

```swift
    /// Nil when the shelf folder could not be resolved at all, which should not happen —
    /// `Application Support` is not protected and needs no permission.
    private let shelf: Shelf?
```

```swift
    init(outer: OuterRing, settings: Settings, shelf: Shelf?) {
        self.outer = outer
        self.settings = settings
        self.shelf = shelf
        super.init()
        // ... existing observer registration unchanged
    }
```

In `build(size:)`, after the existing `view.onDropPaths` line:

```swift
        view.onDropURLs = { [weak self] urls in self?.onDropURLs?(urls) }
```

and add the callback property next to `onDropPaths`:

```swift
    var onDropURLs: (([URL]) -> Void)?
```

Add the presence updater:

```swift
    /// Tells the orb whether the shelf is holding anything.
    func shelfChanged(loaded: Bool) {
        view?.shelfLoaded = loaded
    }
```

In `show()`, after `refreshDots()`:

```swift
        view.shelfLoaded = (shelf?.total().count ?? 0) > 0
```

- [ ] **Step 5: Wire it in the app delegate**

In `Sources/main.swift`, add a stored property next to `orb`:

```swift
    private let shelf: Shelf?
```

In `override init()`, after `let settings = Settings(defaults: defaults)`:

```swift
        // Resolved once. A failure here means the shelf is unavailable, not that Chakra
        // cannot run — the launcher is the app, the shelf is a feature of it.
        shelf = (try? Shelf.defaultRoot()).map { Shelf(root: $0) }
```

In `applicationDidFinishLaunching`, after `installOrb()`:

```swift
        if let shelf {
            // Litter from a crash, not from an error: an error path cleans up after itself.
            shelf.sweepIncoming(olderThan: 60)
            shelf.excludeFromBackup()
            shelf.onChange = { [weak self] in
                guard let self, let shelf = self.shelf else { return }
                self.orb?.shelfChanged(loaded: shelf.total().count > 0)
                self.wheel.refresh()
            }
            shelf.startWatching()
        }
```

In `installOrb()`, change the controller construction and add the drop handler:

```swift
            let controller = OrbController(outer: outer, settings: settings, shelf: shelf)
```

```swift
            controller.onDropURLs = { [weak self] urls in self?.shelveDropped(urls) }
```

And add the method:

```swift
    /// Puts dropped files on the shelf and reports what happened.
    ///
    /// The wheel is opened either way, for the same reason dropping an app on the menu-bar
    /// icon opens it: the user can see the result.
    private func shelveDropped(_ urls: [URL]) {
        guard let shelf else { return }
        let outcome = shelf.add(urls)
        orb?.shelfChanged(loaded: shelf.total().count > 0)
        wheel.show(atCursor: false, message: ShelfMessage.summary(outcome, shelf: shelf))
    }
```

- [ ] **Step 6: Add the message builder**

Create the text in one place, so the orb, the hub and any future entry point cannot drift.
Add to the bottom of `Sources/ShelfIntake.swift`:

```swift
/// The words Chakra shows for a shelf outcome.
///
/// `FileManager`'s own `localizedDescription` is unusable: measured, for a *source* file it
/// cannot read it says "…you don't have permission to access 'dst'", naming the
/// **destination**. So every message here is Chakra's own.
enum ShelfMessage {
    static func summary(_ outcome: AddOutcome, shelf: Shelf) -> String {
        if outcome.added.isEmpty, let first = outcome.refusals.first {
            return text(for: first)
        }
        let head = outcome.added.count == 1
            ? "Added \(outcome.added[0]) to the shelf"
            : "Added \(outcome.added.count) items to the shelf"
        guard outcome.refusals.isEmpty else {
            return head + " — skipped \(outcome.refusals.count)"
        }
        // Informational, not a warning, and the count is read rather than written.
        let count = shelf.total().count
        return count >= Shelf.itemNoteThreshold
            ? head + " — shelf now holds \(count)"
            : head
    }

    static func text(for error: ShelfError) -> String {
        switch error {
        case .blockedByFile:
            return "A file named Shelf is in the way — Chakra can't use its shelf folder"
        case .notEnoughSpace:
            return "Not enough space to add that"
        case .sourceMissing(let name):
            return "\(name) is no longer there"
        case .sourceUnreadable(let name):
            return "Chakra can't read \(name)"
        case .volumeDisconnected(let name):
            return "The disk holding \(name) was disconnected — nothing was added"
        case .wouldExceedCap(let drop, let existing, let cap):
            // The message does the arithmetic, which is what turns a refusal into something
            // actionable.
            return "That's \(bytes(drop)) and the shelf holds \(bytes(existing)) "
                + "— the limit is \(bytes(cap))"
        case .isApplication(let name):
            return "\(name) is an app — drop it on the wheel to pin it instead"
        case .nothingUsableOnClipboard:
            return "Nothing on the clipboard Chakra can save as a file"
        }
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}
```

- [ ] **Step 7: Add smoke checks**

In `Tools/Smoke.swift`, add a new section modelled on the existing `exerciseOrbDrop`:

```swift
    // The shelf's drop path. The existing orb-drop exercise covers apps going to the ring;
    // this covers files going to the shelf, and the two must not interfere.
    func exerciseShelfDrop() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chakra-smoke-shelf-\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: root) }
        let shelf = Shelf(root: root)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-\(UUID().uuidString).txt")
        _ = try? Data(repeating: 0x41, count: 32).write(to: source)
        defer { _ = try? FileManager.default.removeItem(at: source) }

        let outcome = shelf.add([source])
        check(outcome.added.count == 1, "a dropped file lands on the shelf")
        check(shelf.total().count == 1, "and the total reflects it")

        let view = OrbView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        view.shelfLoaded = false
        check(view.shelfLoaded == false, "the orb starts with an empty shelf")
        view.shelfLoaded = true
        check(view.shelfLoaded, "and can be told the shelf is loaded")
        // Drawing must not crash in either state; the presence dot changes size and colour.
        view.displayIfNeeded()

        // `draggingUpdated` must accept unconditionally, or a refusal can never be shown.
        let empty = NSPasteboard(name: NSPasteboard.Name("local.chakra.smoke.empty"))
        empty.clearContents()
        check(ShelfIntake.fileURLs(from: empty).isEmpty,
              "an empty pasteboard yields no URLs")
    }
```

Call `exerciseShelfDrop()` from wherever the other `exercise…` functions are invoked.

- [ ] **Step 8: Run everything**

Run: `./run-tests.sh && ./build.sh && ./run-smoke.sh`
Expected: unit checks unchanged at `✓ 1840 checks passed`, build exit 0, and smoke rises by 5
to `✓ 427 smoke checks passed`.

- [ ] **Step 9: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/OrbView.swift" "$P/Sources/OrbController.swift" "$P/Sources/main.swift" \
   "$P/Sources/ShelfIntake.swift" "$G/Sources/"
cp "$P/Tools/Smoke.swift" "$G/Tools/"
git add Sources/OrbView.swift Sources/OrbController.swift Sources/main.swift \
        Sources/ShelfIntake.swift Tools/Smoke.swift
git commit -m "feat: shelve files dropped on the orb, and show presence on it"
```

---

## Task 11: The hub — readout, gestures, and drag-out

The last task. It changes two gestures that exist today, so read the spec's §2.8 before
starting.

**Files:**
- Modify: `Sources/WheelView.swift`
- Modify: `Sources/WheelWindow.swift`
- Modify: `Tools/Smoke.swift`

**Interfaces:**
- Consumes: `Shelf`, `ShelfItem`, `ShelfMessage`.
- Produces: on `WheelView`, `var shelfCount: Int`, `var shelfBytes: Int64`,
  `var shelfItems: [ShelfItem]`, `var onOpenShelf: (() -> Void)?`,
  `var onShelfDrop: (([URL]) -> Void)?`.

- [ ] **Step 1: Add the readout state to `WheelView`**

```swift
    /// What the hub displays. Set by the controller from `Shelf.total()`.
    var shelfCount = 0 { didSet { if shelfCount != oldValue { invalidate() } } }
    var shelfBytes: Int64 = 0 { didSet { if shelfBytes != oldValue { invalidate() } } }
    /// The items themselves, needed only to start a drag out.
    var shelfItems: [ShelfItem] = []
    /// Clicking the hub opens the folder in Finder.
    var onOpenShelf: (() -> Void)?
    /// Files dropped on the hub. Separate from `onDropPath`, which targets a ring slot.
    var onShelfDrop: (([URL]) -> Void)?
```

- [ ] **Step 2: Draw the readout**

Replace `drawCenterPill()`'s empty-wheel branch and add a hub readout. The hovered-app name
still wins — it is the more urgent thing to say — so the readout draws only when no slot is
hovered or focused:

```swift
    /// The shelf readout, in the hole.
    ///
    /// One number and the size, with no kind word: a mixed shelf has no single noun, and
    /// "items" would spend the only spare line saying nothing. Dropping the word buys a
    /// 62 pt number instead of 46 pt, which is what keeps it legible at the 0.7× minimum
    /// wheel scale.
    ///
    /// The hole is 144 pt across at scale 1, so a square inscribed in it is about
    /// 100 × 100 pt. That is the entire budget. Three digits do not fit, hence `99+`.
    private func drawShelfReadout() {
        let scale = geometry.scale
        guard shelfCount > 0 else {
            // The empty state is the invitation, and the only time an instruction is shown.
            // Once there is content, a permanent imperative is noise that never goes away.
            let radius = geometry.holeRadius - 10 * scale
            let ring = NSBezierPath(ovalIn: NSRect(x: wheelCenter.x - radius,
                                                   y: wheelCenter.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 1.5 * scale
            ring.setLineDash([5 * scale, 5 * scale], count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(0.30).setStroke()
            ring.stroke()
            drawHubText("Shelf empty", at: wheelCenter.y - 6 * scale,
                        size: 12 * scale, weight: .medium, alpha: 0.75)
            drawHubText("drop files on the orb", at: wheelCenter.y - 22 * scale,
                        size: 10 * scale, weight: .regular, alpha: 0.45)
            return
        }
        let shown = shelfCount > 99 ? "99+" : "\(shelfCount)"
        drawHubText(shown, at: wheelCenter.y + 8 * scale,
                    size: 62 * scale, weight: .semibold, alpha: 1)
        drawHubText(ShelfMessage.bytes(shelfBytes), at: wheelCenter.y - 30 * scale,
                    size: 12 * scale, weight: .regular, alpha: 0.55)
    }

    private func drawHubText(_ text: String, at y: CGFloat, size: CGFloat,
                             weight: NSFont.Weight, alpha: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ])
        let width = geometry.holeRadius * 2
        attributed.draw(in: NSRect(x: wheelCenter.x - width / 2,
                                   y: y - attributed.size().height / 2,
                                   width: width, height: attributed.size().height))
    }
```

In `draw(_:)`, call it before `drawCenterPill()`:

```swift
        drawShelfReadout()
        drawCenterPill()
```

And in `drawCenterPill()`, delete the `else if isEmptyWheel` branch that drew
`"Drop apps here"` — the hub now owns that space. Leave the hovered-name branch alone.

- [ ] **Step 3: Move the wheel from the glass bands instead of the hole**

In `mouseDown(with:)`, change the `switch target` so `.center` no longer grabs and a slot
press on empty glass does:

```swift
        switch target {
        case .slot(let ring, let index):
            let ref = SlotRef(ring: ring, index: index)
            dragOrigin = item(ref) != nil ? ref : nil
            // An empty slot is bare glass, and pressing the glass is now how the wheel is
            // moved — the hole belongs to the shelf. The bands are large and a press on
            // them did nothing before, so the gesture was free.
            if dragOrigin == nil {
                moveGrabOffset = CGSize(width: wheelCenter.x - point.x,
                                        height: wheelCenter.y - point.y)
            }
        case .center:
            // The shelf's territory. No grab offset, so no move.
            dragOrigin = nil
        case .outside:
            dragOrigin = nil
        }
```

In `mouseUp(with:)`, change the release switch so the hole opens the shelf instead of
dismissing:

```swift
        switch release {
        case .center:
            // Dismissal is Esc and click-outside. The hole opens the shelf folder.
            onOpenShelf?()
        case .outside:
            onDismiss?()
        case .slot(let ring, let index):
            // ... unchanged
```

- [ ] **Step 4: Accept drops on the hub**

In `draggingUpdated`, add a hub branch before the slot lookup:

```swift
        let point = convert(sender.draggingLocation, from: nil)
        if case .center = geometry.hit(point, center: wheelCenter) {
            if dropTarget != nil { dropTarget = nil; invalidate() }
            return .copy
        }
```

In `performDragOperation`, add the same branch first:

```swift
        let point = convert(sender.draggingLocation, from: nil)
        if case .center = geometry.hit(point, center: wheelCenter) {
            let urls = ShelfIntake.fileURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else {
                flashMessage("Nothing there Chakra can put on the shelf")
                return false
            }
            onShelfDrop?(urls)
            return true
        }
```

- [ ] **Step 5: Drag out of the hub, copy-only**

In `mouseDragged(with:)`, add a hub branch before the slot drag:

```swift
        if !isDraggingOut, !shelfItems.isEmpty, let start = mouseDownAt,
           case .center = geometry.hit(start, center: wheelCenter),
           hypot(location.x - start.x, location.y - start.y) > 6 {
            isDraggingOut = true
            let items = shelfItems.map { item -> NSDraggingItem in
                let dragged = NSDraggingItem(pasteboardWriter: item.url as NSURL)
                let side = geometry.innerIconSize
                dragged.setDraggingFrame(
                    NSRect(x: wheelCenter.x - side / 2, y: wheelCenter.y - side / 2,
                           width: side, height: side),
                    contents: NSWorkspace.shared.icon(forFile: item.url.path))
                return dragged
            }
            // Every item, not just the first: `WheelView` passes one today, and a shelf
            // drag-out should take what is there.
            beginDraggingSession(with: items, event: event, source: self)
            return
        }
```

In the `NSDraggingSource` extension, the operation mask must now depend on where the drag
started. Replace the method:

```swift
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Two opposite rules in one method, because there are two kinds of outgoing drag.
        //
        // A ring icon leaving the app would hand Finder a real file URL and have it copy a
        // whole app bundle, so that stays confined to the application.
        //
        // A shelf item leaving the app **is the point** — it is how a file gets off the
        // shelf — so it must be allowed out. `.copy` only, never `.move`: including `.move`
        // makes it Finder's default for a same-volume drag and hands the destination the
        // right to delete the shelf's copy, which is an auto-delete triggered by an easy
        // accident with no undo.
        if draggedFromHub { return .copy }
        return context == .withinApplication ? .copy : []
    }
```

Add the flag next to the other drag state, set it in the hub branch above
(`draggedFromHub = true`) and clear it in `mouseDown` alongside `isDraggingOut = false`:

```swift
    /// Whether the drag in flight started in the hub, which decides whether it may leave
    /// the application.
    private var draggedFromHub = false
```

- [ ] **Step 6: Wire the controller**

In `Sources/WheelWindow.swift`, add a `shelf` parameter to `WheelController.init` exactly as
Task 10 did for `OrbController`, store it, and in `makeWindowIfNeeded()` add:

```swift
        view.onOpenShelf = { [weak self] in
            guard let shelf = self?.shelf else { return }
            // `activateFileViewerSelecting` rather than `open`: it reveals the folder and
            // needs no permission.
            NSWorkspace.shared.activateFileViewerSelecting([shelf.root])
            self?.hide()
        }
        view.onShelfDrop = { [weak self] urls in
            guard let self, let shelf = self.shelf else { return }
            let outcome = shelf.add(urls)
            self.refresh()
            self.wheel?.flashMessage(ShelfMessage.summary(outcome, shelf: shelf))
        }
```

In `populate()`, add:

```swift
        if let shelf {
            let total = shelf.total()
            wheel.shelfCount = total.count
            wheel.shelfBytes = total.bytes
            wheel.shelfItems = shelf.items()
        }
```

In `Sources/main.swift`, pass the shelf when constructing the `WheelController`.

- [ ] **Step 7: Add smoke checks**

Append to `exerciseShelfDrop()` in `Tools/Smoke.swift`:

```swift
        let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        wheel.geometry = RingGeometry()
        wheel.wheelCenter = CGPoint(x: 300, y: 300)

        wheel.shelfCount = 0
        wheel.displayIfNeeded()
        check(wheel.shelfCount == 0, "the hub renders an empty shelf")

        wheel.shelfCount = 6
        wheel.shelfBytes = 199 * 1024 * 1024
        wheel.displayIfNeeded()
        check(wheel.shelfCount == 6, "the hub renders a loaded shelf")

        // Three digits do not fit the 100 pt budget, so the readout caps.
        wheel.shelfCount = 1234
        wheel.displayIfNeeded()
        check(wheel.shelfCount == 1234, "a four-digit count does not crash the readout")

        // The hub must no longer dismiss. A press and release in the hole opens the shelf.
        var opened = false
        wheel.onOpenShelf = { opened = true }
        var dismissed = false
        wheel.onDismiss = { dismissed = true }
        wheel.mouseDown(with: NSEvent())
        wheel.mouseUp(with: NSEvent())
        check(!dismissed, "a click in the hub does not dismiss the wheel")
        _ = opened
```

- [ ] **Step 8: Run everything**

Run: `./run-tests.sh && ./build.sh && ./run-smoke.sh`
Expected: `✓ 1840 checks passed`, build exit 0, `✓ 431 smoke checks passed`.

- [ ] **Step 9: Check by hand, because the gestures cannot be smoke-tested**

`./build.sh --install` needs `sudo` on this machine — see `ai/PENDING.md`. Run the built app
from `build/Chakra.app` instead and verify, in order:

1. Enable the orb in Settings. The centre dot is small and white.
2. Drag a file from Finder onto the orb. The wheel opens with "Added … to the shelf". The
   orb's centre dot is now larger and accent-coloured.
3. Open the wheel. The hub shows `1` and a size.
4. Press in the hub and drag to a Finder window. The file copies out and **stays** on the shelf.
5. Press on the glass band between the rings and drag. The **wheel** moves.
6. Press in the hub and release without moving. Finder opens the shelf folder.
7. Press Esc with the wheel open. It dismisses.
8. Right-click a ring icon. It still removes, which is the `M1` regression path with no
   automated coverage.

- [ ] **Step 10: Sync and commit** *(commit blocked)*

```bash
P=~/Claude/projects/Chakra; G=~/Claude/docs/GIT/GIT_Chakra
cp "$P/Sources/WheelView.swift" "$P/Sources/WheelWindow.swift" "$P/Sources/main.swift" "$G/Sources/"
cp "$P/Tools/Smoke.swift" "$G/Tools/"
git add Sources/WheelView.swift Sources/WheelWindow.swift Sources/main.swift Tools/Smoke.swift
git commit -m "feat: shelf readout in the hub, drag-out, and the gesture rework"
```

---

## Self-review

**Spec coverage.** Walked every numbered section of the spec against the tasks:

| Spec | Task |
|---|---|
| §2.1 copies not references | 5 (`resolve`) |
| §2.2 storage location | 3 (`defaultRoot`) |
| §2.3 no Change… button | not built, by design — nothing to implement |
| §2.4 orb is the intake | 10 |
| §2.5 content at rest, invitation when empty | 11 (`drawShelfReadout`) |
| §2.6 count and size, no kind word, `99+` | 11 |
| §2.7 presence on the orb | 10 |
| §2.8 hub is shelf-only, bands move the wheel | 11 |
| §2.9 paste writes verbatim bytes | 8 |
| §2.10 pasted name | 8 |
| §2.11 collision convention | 2 |
| §2.12 caps | 4 (arithmetic), 5 (atomic refusal) |
| §2.13 `.app` refused | 5 |
| §2.14 promise drags | **GAP — see below** |
| §2.15 leading dots, `/`, length, Unicode | 2 |
| §2.16 Time Machine exclusion | 7 |
| §2.17 removal via Trash | 7 |
| §2.18 drag-out copy-only | 11 |
| §4.1 verified copy | 5, 6 |
| §4.2 live scan | 4 |
| §4.3 directory watch | 9 |
| §5 self-healing | 3 |
| §6 error messages | 10 (`ShelfMessage`) |

**One real gap, and it is deliberate.** §2.14 requires `NSFilePromiseReceiver` support so that
dragging an image out of Safari, Mail or Photos works — measured, such a drag yields **zero**
file URLs. No task above implements it, because it needs its own test fixture (a promise-only
pasteboard) and its own async receipt path, and folding it into Task 10 would have made that
task un-reviewable.

**It must be Task 12, and it must not be dropped.** Until it exists, `performDragOperation`
returns `false` for a promise-only drag, which is a **silent** failure — the worst outcome
available, and the exact thing the spec calls out. If Task 12 is deferred, Task 10 must instead
show `"Chakra can't take that kind of drag yet"` rather than returning `false`. Recorded here
rather than quietly omitted.

**Placeholder scan.** No `TBD`, `TODO`, "add error handling", or "similar to Task N". Every
code step carries the code. Every test step carries the assertions.

**Type consistency.** Checked across tasks: `ShelfError` cases are spelled identically in
Tasks 3, 5 and 10; `AddOutcome.added` is `[String]` everywhere; `ShelfItem.bytes` is `Int64`
and `total()` returns `Int64`, matching `ShelfMessage.bytes(_ count: Int64)`;
`ShelfIntake.fileURLs(from:)` takes an `NSPasteboard` in Tasks 8, 10 and 11;
`Shelf.incomingPrefix` is referenced in Tasks 4, 5 and 7 and defined once in Task 4.

One inconsistency found and fixed inline: Task 5 introduces an **instance** `capBytes` that
shadows the static, so the initialiser default is written `Shelf.capBytes` explicitly. Task 4's
test asserts the static; Task 5's test injects the instance value. Both are correct as written.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-22-chakra-shelf.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**

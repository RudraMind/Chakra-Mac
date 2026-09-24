// `AppKit`, not `Foundation` alone: the pasteboard suites at the end of this file need
// `NSPasteboard`. It is not a UI object and needs no window server, which is what keeps this
// binary runnable without one — the same reasoning recorded on `Sources/Shelf.swift`'s import.
import AppKit
import Foundation

// A note that applies to every stub in this file, because it has now bitten twice.
//
// A stub only intercepts what it overrides. The first instance was `fileExists`: overriding
// `fileExists(atPath:)` alone left the `isDirectory:` overload hitting the real filesystem.
// The second is `attributesOfItem`, which `ensureExists()` now calls first for its symlink
// guard. No stub here overrides it, so each falls through to the real implementation against
// a path that does not exist, which throws, and `try?` turns that into `nil`. That is the
// behaviour these suites want — but it is luck, not design. If a stub ever needs to model a
// symlink, `attributesOfItem` is the method to override.

/// A `FileManager` that reports a directory which can never be made writable.
///
/// Drives the `shelfNotWritable` guard deterministically. The real-world condition is a
/// directory carrying an ACL `deny add_file` ACE, which cannot be created from the test binary
/// without shelling out to `/bin/chmod +a`. This injection seam is what
/// `Shelf.init(root:fileManager:)` was for — the same shape `OuterRing` and `Recents` use for
/// `UserDefaults`.
private final class UnrepairableFileManager: FileManager {
    var setAttributesCalls = 0
    var createDirectoryCalls = 0

    override func fileExists(atPath path: String) -> Bool {
        return true
    }

    override func fileExists(atPath path: String,
                            isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = ObjCBool(true)
        return true
    }

    override func isWritableFile(atPath path: String) -> Bool { false }

    override func setAttributes(_ attributes: [FileAttributeKey: Any],
                                ofItemAtPath path: String) throws {
        setAttributesCalls += 1
        throw NSError(domain: NSCocoaErrorDomain,
                      code: NSFileWriteNoPermissionError,
                      userInfo: nil)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        // Should never be called - the folder exists and should throw shelfNotWritable.
        // Counted rather than fatalError so the run keeps its summary and cleanup.
        createDirectoryCalls += 1
        expect(false, "UnrepairableFileManager: createDirectory should not be called")
    }
}

/// A `FileManager` that fails to create a directory with a specific error code.
private final class FailingCreateFileManager: FileManager {
    let errorCode: Int
    var createDirectoryCalls = 0

    init(errorCode: Int) {
        self.errorCode = errorCode
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        return false
    }

    override func fileExists(atPath path: String,
                            isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        return false
    }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        createDirectoryCalls += 1
        throw NSError(domain: NSCocoaErrorDomain, code: errorCode, userInfo: nil)
    }
}

/// A `FileManager` whose folder vanishes between the writability check and the repair.
private final class DeletedDuringRepairFileManager: FileManager {
    var fileExistsCalls = 0
    var isWritableFileCalls = 0
    var createDirectoryCalls = 0

    override func fileExists(atPath path: String) -> Bool {
        var ignored = ObjCBool(false)
        return fileExists(atPath: path, isDirectory: &ignored)
    }

    /// Present, then deleted, then present again once this stub has recreated it.
    ///
    /// The third phase used to be missing — every call after the first said "gone" — which meant
    /// the stub insisted the folder did not exist immediately after claiming `createDirectory`
    /// had succeeded. `ensureExists()` now re-checks after creating, so the stub has to tell a
    /// consistent story.
    override func fileExists(atPath path: String,
                            isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileExistsCalls += 1
        if createDirectoryCalls > 0 {
            // Recreated by the create path.
            isDirectory?.pointee = ObjCBool(true)
            return true
        }
        if fileExistsCalls == 1 {
            // First call: directory exists
            isDirectory?.pointee = ObjCBool(true)
            return true
        }
        // Second call (after the repair attempt): deleted by another writer
        isDirectory?.pointee = ObjCBool(false)
        return false
    }

    /// Not writable while the old folder is in the way; writable once this stub has recreated it.
    ///
    /// The flat `false` this used to return was incoherent: it claimed "nothing here is ever
    /// writable" while also claiming "createDirectory succeeded". `ensureExists()` now verifies
    /// writability after creating, so the stub has to answer the question honestly, and the F-4
    /// suite gains a real assertion — that the recovery produced something usable — instead of
    /// only counting calls.
    override func isWritableFile(atPath path: String) -> Bool {
        isWritableFileCalls += 1
        return createDirectoryCalls > 0
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any],
                                ofItemAtPath path: String) throws {
        // Repair attempt fails (folder is immutable or whatever)
        throw NSError(domain: NSCocoaErrorDomain,
                      code: NSFileWriteNoPermissionError,
                      userInfo: nil)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        createDirectoryCalls += 1
        // Successfully created
    }
}

/// A `FileManager` whose `createDirectory` succeeds while producing a folder nothing can write.
///
/// The create-path half of A2. Real causes, both measured on 2026-09-22 with no stub at all: a
/// parent carrying an inheritable `everyone deny add_file,file_inherit,directory_inherit` ACE,
/// which makes `mkdir` succeed and the child inherit the deny; and a `umask` of 0o222, which
/// creates the folder at mode 0o555. Neither can be set up from the test binary without shelling
/// out or mutating process-global state, so the seam stands in for them.
private final class UnwritableAfterCreateFileManager: FileManager {
    var createDirectoryCalls = 0
    var fileExistsWithDirectoryCalls = 0

    override func fileExists(atPath path: String) -> Bool { createDirectoryCalls > 0 }

    override func fileExists(atPath path: String,
                            isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileExistsWithDirectoryCalls += 1
        // Absent before the create, a directory afterwards.
        isDirectory?.pointee = ObjCBool(createDirectoryCalls > 0)
        return createDirectoryCalls > 0
    }

    /// False throughout: the folder is created, and it is still unwritable.
    override func isWritableFile(atPath path: String) -> Bool { false }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        createDirectoryCalls += 1
    }
}

/// A `FileManager` whose freshly created folder is deleted again by another writer.
///
/// Separates "not writable" from "not there" on the create path. Reporting `shelfNotWritable`
/// for a folder that another writer has just removed is the same lie fix round 4 removed from
/// the repair branch; measured under two `rmdir` threads it happened 814 times in 10,000 calls.
private final class VanishedAfterCreateFileManager: FileManager {
    var createDirectoryCalls = 0
    var fileExistsWithDirectoryCalls = 0

    override func fileExists(atPath path: String) -> Bool { false }

    override func fileExists(atPath path: String,
                            isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileExistsWithDirectoryCalls += 1
        isDirectory?.pointee = ObjCBool(false)
        return false
    }

    override func isWritableFile(atPath path: String) -> Bool { false }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        createDirectoryCalls += 1
    }
}

/// A `FileManager` that reports "a directory is here" whatever is really on disk.
///
/// Everything else — `isWritableFile`, `createDirectory`, `attributesOfItem` — is the real
/// implementation, so this drives the W1 window against a real file with no timing luck: the
/// type check is answered "directory" at the instant a regular file occupies the path.
private final class LiesAboutDirectoryFileManager: FileManager {
    var calls = 0

    override func fileExists(atPath path: String,
                            isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        calls += 1
        isDirectory?.pointee = ObjCBool(true)
        return true
    }
}

/// A `FileManager` that simulates another writer recreating the folder as writable.
///
/// Drives the D-5 race: folder exists but is unwritable, repair fails, but by the time
/// the recheck runs, another writer has recreated it as a writable directory. Measured:
/// 665 spurious `shelfNotWritable` errors in 160,000 concurrent calls before the fix.
private final class RecreatedAsWritableFileManager: FileManager {
    var isWritableFileCalls = 0
    var fileExistsWithDirectoryCalls = 0

    override func fileExists(atPath path: String) -> Bool {
        return true
    }

    override func fileExists(atPath path: String,
                            isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileExistsWithDirectoryCalls += 1
        // Always reports a directory exists
        isDirectory?.pointee = ObjCBool(true)
        return true
    }

    override func isWritableFile(atPath path: String) -> Bool {
        isWritableFileCalls += 1
        // First two calls: not writable. Third call (after recheck): writable.
        return isWritableFileCalls > 2
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any],
                                ofItemAtPath path: String) throws {
        // Repair fails - folder is immutable or whatever
        throw NSError(domain: NSCocoaErrorDomain,
                      code: NSFileWriteNoPermissionError,
                      userInfo: nil)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        // Should never be called - the folder exists and is writable after recheck
        expect(false, "RecreatedAsWritableFileManager: createDirectory should not be called")
    }
}

/// A `FileManager` whose `copyItem` creates the destination and then throws.
///
/// The shape spec §4.1 measured on a real folder copy: one unreadable child threw and left
/// four of five entries in place. That is the only reason `copyIn` lands on a hidden temporary
/// name at all, and nothing else in this file can drive it — a *missing* source is refused by
/// `resolve()` before `copyItem` is ever called, so a suite built on one proves the cleanup
/// exists without ever running it.
///
/// `errorCode` doubles as the seam for §6's mapping table: `add(_:)` returns whatever
/// `mapped(_:name:)` makes of the code thrown here, which is the only way to reach a `private
/// static` function from a test.
private final class FailingCopyFileManager: FileManager {
    let errorCode: Int
    var copyAttempts = 0

    init(errorCode: Int = NSFileWriteNoPermissionError) {
        self.errorCode = errorCode
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        copyAttempts += 1
        // Measured: `createFile` here does produce the file, and the production
        // `removeItem` in `copyIn`'s catch does remove it again — so the assertion in
        // `shelf/no-litter-after-failure` is about real litter, not an absent file.
        _ = FileManager.default.createFile(atPath: dstURL.path,
                                          contents: Data("partial".utf8))
        throw NSError(domain: NSCocoaErrorDomain, code: errorCode, userInfo: nil)
    }

    // The `moveItem` override that used to live here is gone with its counter. `copyIn` renames
    // with `renamex_np` now, so this stub could never see a rename — it was dead code backing a
    // check that could never fail.
}

/// A `FileManager` that fails `trashItem` with a specific error.
///
/// Drives the remove error path deterministically without touching the real Trash.
private final class FailingTrashFileManager: FileManager {
    var trashItemCalls = 0

    override func trashItem(at url: URL,
                           resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        trashItemCalls += 1
        throw NSError(domain: NSCocoaErrorDomain,
                      code: NSFileWriteNoPermissionError,
                      userInfo: nil)
    }
}

/// A `FileManager` whose `copyItem` produces a copy of exactly the right *size* and the wrong
/// *bytes*.
///
/// This is the one corruption a size comparison cannot see, which is why the cross-volume
/// branch hashes instead. It stands in for what the size check was never able to catch: a real
/// byte-for-byte copy across volumes that arrives damaged. A stub is used rather than a second
/// real volume because creating one costs 1.2 s of `hdiutil` and leaves a mount behind if the
/// run dies — see `Shelf.sameVolumeOverride` for the full measurement.
private final class CorruptingCopyFileManager: FileManager {
    var copyAttempts = 0

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        copyAttempts += 1
        let original = try Data(contentsOf: srcURL)
        try Data(repeating: 0x42, count: original.count).write(to: dstURL)
    }
}

/// A `FileManager` whose `copyItem` makes a correct copy and then makes both sides unreadable.
///
/// Drives the case where `digest(of:)` returns nil for the source *and* the copy. Comparing two
/// nils would call an unverifiable copy verified, which is the one thing the verification step
/// must never do. Assumes the run is not root; as root, mode 0 does not block a read and this
/// stub would produce two equal digests instead.
private final class UnreadableAfterCopyFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try Data(contentsOf: srcURL).write(to: dstURL)
        _ = try? setAttributes([.posixPermissions: 0], ofItemAtPath: srcURL.path)
        _ = try? setAttributes([.posixPermissions: 0], ofItemAtPath: dstURL.path)
    }
}

/// A `FileManager` whose `temporaryDirectory` is somewhere the tests choose.
///
/// `temporaryDirectory` is the only input to `add(pasteboard:)`'s staging path, and production
/// always answers with a writable directory, so a stub is the only way to drive a staging
/// failure that is *not* a full disk. It also records the staging directories that were
/// created, which is how the uniqueness of the staging path is observed from outside.
private final class StagingDirectoryFileManager: FileManager {
    let directory: URL
    var createdInTemporary: [String] = []

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override var temporaryDirectory: URL { directory }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.path.hasPrefix(directory.path) {
            createdInTemporary.append(url.lastPathComponent)
        }
        try super.createDirectory(at: url,
                                  withIntermediateDirectories: withIntermediateDirectories,
                                  attributes: attributes)
    }
}

/// A tiny real PNG, so the pasteboard suites work on genuine image data rather than bytes
/// that happen to carry a PNG header. `side` varies so two fixtures can be told apart by size.
private func pngFixture(_ side: Int) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: side * 4, bitsPerPixel: 32) else { return Data() }
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

/// A private pasteboard, so no suite ever disturbs the user's own clipboard.
///
/// The UUID is load-bearing, not decoration. `NSPasteboard.Name` is **machine-global**, so with a
/// fixed name two test binaries running at once shared one board. Measured across 4,000 trials per
/// process: solo, `setData` returned false 0 times and a read came back nil 0 times; with two
/// processes on the same name, `setData` returned false 627 times and reads came back nil 1,116
/// times. The pasteboard suites failed 10 runs in 30 under six-way process load and never once
/// solo. `scratchDirectory` already uses a UUID for exactly this reason.
private func testBoard(_ label: String) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name(
        "local.chakra.tests.shelf.\(label).\(UUID().uuidString)"))
    board.clearContents()
    registerScratchBoard(board)
    return board
}

/// Puts a PNG fixture on a board and asserts it really arrived.
///
/// `setData` returns a `Bool` that was being discarded, and `pngFixture` returns an empty `Data`
/// rather than trapping if `NSBitmapImageRep` refuses — so a board that silently took nothing
/// produced `nothingUsableOnClipboard` and a failure message pointing somewhere else entirely.
/// That is what the process-load flakiness above actually looked like from inside a suite.
private func putPNG(_ board: NSPasteboard, side: Int, _ label: String) {
    let png = pngFixture(side)
    expect(!png.isEmpty, "the \(label) PNG fixture has bytes, got \(png.count)")
    expect(board.setData(png, forType: .png), "and the board accepted them for \(label)")
}

/// A `FileManager` whose `copyItem` succeeds and then makes the shelf folder unwritable.
///
/// The only seam found that drives `copyIn`'s rename onto a non-`EEXIST` `errno`. The rename is a
/// raw `renamex_np`, so no `FileManager` stub can intercept it — this lets the real syscall run and
/// fail with `EACCES`, which is what proves the loop distinguishes "that name is taken" from "this
/// can never work".
private final class LocksRootAfterCopyFileManager: FileManager {
    let lockedRoot: URL

    init(lockedRoot: URL) {
        self.lockedRoot = lockedRoot
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        _ = try? super.setAttributes([.posixPermissions: 0o500],
                                     ofItemAtPath: lockedRoot.path)
    }
}

/// The cap payload of whichever refusal carries one, or nil.
///
/// A helper rather than `refusals[0]` at each site, because `expectEqual(refusals.count, 1, …)`
/// records a failure and then keeps going — and the next line subscripted an empty array.
/// Measured: a single value sabotage that stopped the cap firing aborted the whole binary with
/// `Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range`, SIGTRAP, exit 133.
/// The accumulated failure list was discarded, so the maintainer saw a bare trap and no check
/// name, and `removeScratchDomains()` / `removeScratchDirectories()` never ran — 184 stray
/// `chakra-test-*` directories were left in `$TMPDIR`. The two suites whose whole job is the cap
/// refusal were the two that could not report a cap refusal going missing. `Tests/TestMain.swift`
/// states the principle this broke: counted rather than `fatalError`, so the run keeps its summary.
private func capPayload(_ refusals: [ShelfError]) -> (drop: Int64, existing: Int64, cap: Int64)? {
    for refusal in refusals {
        if case .wouldExceedCap(let drop, let existing, let cap) = refusal {
            return (drop, existing, cap)
        }
    }
    return nil
}

/// Counts this process's open file descriptors without opening one.
///
/// `fcntl(fd, F_GETFD)` is a pure syscall. Listing `/dev/fd` would answer the same question but
/// has to open the directory to do it, so the act of counting would change the count — and the
/// descriptor it uses is closed asynchronously, which is exactly the kind of noise that makes a
/// descriptor check flaky. The table is walked to 4096 rather than `getdtablesize()` because the
/// limit here is 10,240 and the whole walk is 4096 cheap syscalls, measured under 2 ms.
private func openDescriptorCount() -> Int {
    var count = 0
    for descriptor in 0..<CInt(min(getdtablesize(), 4096)) where fcntl(descriptor, F_GETFD) != -1 {
        count += 1
    }
    return count
}

/// Turns the main run loop for a fixed period.
///
/// A real wait, not a sleep: a `DispatchSource` cancel handler is *submitted* to the source's
/// queue by `cancel()` and does not run until that queue turns, so a descriptor closed in one is
/// still open until the run loop has been given the chance.
private func drainMainQueue(for seconds: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

func runShelfTests() {
    suite("shelf/root") {
        let root = scratchDirectory("root").appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        expectEqual(shelf.root, root, "the shelf remembers the root it was given")
    }

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

        // Measured: createDirectory(withIntermediateDirectories: true) succeeds on an existing
        // directory, which is what makes the deliberate fall-through on the healthy path safe —
        // `ensureExists()` calls `createDirectory` every time now, including when the folder is
        // already there and fine. This check is the one that would go red if that stopped being
        // true.
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
        // Assert the setup took. Without this the suite can pass because the repair branch
        // was never entered, which is a check that proves nothing.
        let beforeMode = (try? FileManager.default
            .attributesOfItem(atPath: root.path)[.posixPermissions]) as? NSNumber
        expectEqual(beforeMode?.intValue ?? 0, 0o555, "the setup made the folder read-only")

        do {
            try shelf.ensureExists()
        } catch {
            expect(false, "ensureExists repairs a read-only shelf, got \(error)")
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
            as? NSNumber
        expectEqual(mode?.intValue ?? 0, 0o755, "the permissions were repaired")
        // The post-condition that actually matters. Measured: `setAttributes` can succeed
        // while the directory stays unwritable, so the mode alone is not evidence.
        expect(FileManager.default.isWritableFile(atPath: root.path),
               "and the folder is writable afterwards")
    }

    suite("shelf/default-root") {
        // `defaultRoot()` is not a pure getter, and the name hides it: it passes `create: true`,
        // so `FileManager` creates `~/Library/Application Support` if it is missing. That write
        // is the only reason the function is `throws`, and it means this suite touches the real
        // user's home on every run. Harmless in practice — the directory exists on any macOS
        // install — but worth saying out loud, because a getter with a filesystem side effect is
        // the kind of thing that gets called in a loop later.
        //
        // What it does *not* create is the `local.chakra/Shelf` pair, which is appended as
        // strings. That is `ensureExists()`'s job. An earlier comment here discussed
        // `create: false`; the code has always passed `create: true`.
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

    suite("shelf/unrepairable-reports") {
        // Why writability is the only post-condition worth checking, measured 2026-09-22 on a
        // directory carrying an `everyone deny add_file` ACE with POSIX mode already 0o755:
        // `setAttributes([.posixPermissions: 0o755])` **succeeds**, the mode is unchanged, and
        // `isWritableFile` is still false — a real `open(O_CREAT)` in it fails with 513. So
        // trusting the call's own result would report success on a folder nothing can write to.
        //
        // An earlier version of this comment blamed `chflags uchg`, and said in one sentence
        // that `chmod(2)` returns EPERM *and* that `setAttributes` succeeds — which cannot both
        // be true, since `setAttributes` with `.posixPermissions` **is** `chmod(2)`. Measured:
        // under `uchg`, `setAttributes` throws 513. What silently succeeded was `/bin/chmod`,
        // because BSD `chmod` skips the syscall when the mode already matches. The evidence had
        // come from a shell tool instead of the API under test — `ai/GOTCHAS.md` #20 exactly.
        //
        // Scope, stated honestly: this suite guards the **repair** branch. The create branch has
        // its own post-condition and its own suite, `shelf/create-path-unwritable-reports`.
        // Also note that `UnrepairableFileManager.setAttributes` *throws*, so the shape described
        // above — the call succeeding on a broken folder — is not the shape this stub builds.
        // Production uses `try?`, so both converge on the same branch and the coverage holds.
        let stub = UnrepairableFileManager()
        let root = scratchDirectory("stub-unrepairable")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must report a folder it could not repair")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.shelfNotWritable(root),
                        "and it names the folder it gave up on")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }
        expectEqual(stub.setAttributesCalls, 1, "the repair was attempted exactly once")
        expectEqual(stub.createDirectoryCalls, 0, "and createDirectory was not called")
        // The tripwire for production code reaching for `FileManager.default` instead of the
        // injected instance. It only works because `root` is somewhere writable: measured, a root
        // under `/nonexistent` yields code 642, read-only volume, because the macOS root volume
        // is the Signed System Volume — so under the old path no change to production code could
        // ever have turned this red. `scratchDirectory` registers itself for cleanup.
        expect(!FileManager.default.fileExists(atPath: root.path),
               "and nothing was written to disk")
    }

    suite("shelf/create-error-513-mapped") {
        // F-1: `createDirectory` throwing 513 (EACCES) must be mapped to `shelfUnusable`
        // rather than leaked as a raw NSError. Every non-516 code must be mapped.
        let stub = FailingCreateFileManager(errorCode: NSFileWriteNoPermissionError)
        let root = scratchDirectory("stub-513")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must map a 513 error from createDirectory")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.shelfUnusable(root, code: NSFileWriteNoPermissionError),
                        "and it reports the code for bug reports")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }
        expectEqual(stub.createDirectoryCalls, 1, "createDirectory was called exactly once")
        expect(!FileManager.default.fileExists(atPath: root.path),
               "and nothing was written to disk")
    }

    suite("shelf/create-error-516-mapped") {
        // F-2: The file/directory race caught by round 1 must be tested. A stub throwing 516
        // from `createDirectory` drives the race deterministically with no real filesystem.
        let stub = FailingCreateFileManager(errorCode: NSFileWriteFileExistsError)
        let root = scratchDirectory("stub-516")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must map a 516 error to blockedByFile")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.blockedByFile(root),
                        "and it names the path that is blocked")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }
        expectEqual(stub.createDirectoryCalls, 1, "createDirectory was called exactly once")
        expect(!FileManager.default.fileExists(atPath: root.path),
               "and nothing was written to disk")
    }

    suite("shelf/deleted-during-repair-recovers") {
        // F-4: If the folder is deleted between the writability check and the repair attempt,
        // `ensureExists()` must recover by creating it rather than throwing `shelfNotWritable`.
        // Spec §5 says user deletions should be recovered on next intake.
        let stub = DeletedDuringRepairFileManager()
        let root = scratchDirectory("stub-deleted")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
        } catch {
            expect(false, "ensureExists must recover from deletion during repair, got \(error)")
        }
        expectEqual(stub.fileExistsCalls, 3,
                    "fileExists called thrice: initial check, recheck, then after the recreate")
        expectEqual(stub.isWritableFileCalls, 3,
                    "isWritableFile called thrice: initial, post-repair, then after the recreate")
        expectEqual(stub.createDirectoryCalls, 1, "and the folder was recreated")
        expect(stub.isWritableFile(atPath: root.path),
               "and what was recreated is writable, not merely present")
        expect(!FileManager.default.fileExists(atPath: root.path),
               "and nothing was written to disk")
    }

    suite("shelf/recreated-by-another-writer") {
        // D-5: The race where folder exists but is unwritable, repair fails, but by the time
        // the recheck runs another writer has already recreated it as a writable directory.
        // Measured: 665 spurious `shelfNotWritable` in 160,000 concurrent calls before the
        // fix, 6 after. The fix succeeds when the folder is actually writable.
        let stub = RecreatedAsWritableFileManager()
        let root = scratchDirectory("stub-recreated")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
        } catch {
            expect(false, "ensureExists must succeed when another writer recreates as writable, got \(error)")
        }
        expectEqual(stub.fileExistsWithDirectoryCalls, 2,
                    "fileExists(isDirectory:) called twice: initial check, then recheck")
        expectEqual(stub.isWritableFileCalls, 3,
                    "isWritableFile called thrice: initial, post-repair, then recheck finds it writable")
        expect(!FileManager.default.fileExists(atPath: root.path),
               "and nothing was written to disk")
    }

    suite("shelf/symlink-at-root-refused") {
        // A1, the one real security hole this function had. A symlink planted at the shelf's own
        // path sent the self-heal `chmod` outside the shelf: `fileExists(atPath:isDirectory:)`
        // follows a symlink and reports the target's type, and `setAttributes` is `chmod(2)`
        // rather than `lchmod`, so it follows too. Measured before the fix: a victim directory
        // went from 0500 to 0755 while `ensureExists()` returned success. No race is needed — the
        // link can be planted before Chakra's first run, because `local.chakra/` does not exist.
        let parent = scratchDirectory("symlink")
        let victim = parent.appendingPathComponent("victim", isDirectory: true)
        _ = try? FileManager.default.createDirectory(at: victim,
                                                    withIntermediateDirectories: true)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                   ofItemAtPath: victim.path)
        let before = (try? FileManager.default
            .attributesOfItem(atPath: victim.path)[.posixPermissions]) as? NSNumber
        expectEqual(before?.intValue ?? 0, 0o500, "the victim starts at mode 0500")

        let root = parent.appendingPathComponent("Shelf", isDirectory: true)
        _ = try? FileManager.default.createSymbolicLink(atPath: root.path,
                                                       withDestinationPath: victim.path)
        var linkIsDirectory = ObjCBool(false)
        expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &linkIsDirectory),
               "fileExists follows the link and says something is there")
        expect(linkIsDirectory.boolValue,
               "and calls it a directory, which is why the blockedByFile guard never fired")

        let shelf = Shelf(root: root)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must refuse a symlink at the shelf root")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.blockedByFile(root),
                        "and it names the path it refused")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }

        // The assertion that matters: the target's permissions were not widened.
        let after = (try? FileManager.default
            .attributesOfItem(atPath: victim.path)[.posixPermissions]) as? NSNumber
        expectEqual(after?.intValue ?? 0, 0o500,
                    "the symlink target's mode is untouched")
        // And the link itself was neither followed into nor replaced.
        let type = (try? FileManager.default.attributesOfItem(atPath: root.path)[.type])
            as? FileAttributeType
        expectEqual(type ?? .typeUnknown, FileAttributeType.typeSymbolicLink,
                    "the link is still a link, not a directory Chakra created")

        // Leave the scratch tree removable.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: victim.path)
    }

    suite("shelf/dangling-symlink-at-root-refused") {
        // The same guard, and the reason `attributesOfItem` is the right question: measured, it
        // reports NSFileTypeSymbolicLink for a dangling link too, without following it. Before
        // the guard a dangling link reached `createDirectory` and came back as
        // `shelfUnusable(512)` — a code this file used to label "the volume went away", so the
        // user was told their disk had vanished when in fact something was in the way.
        let parent = scratchDirectory("dangling")
        let missing = parent.appendingPathComponent("no-such-target", isDirectory: true)
        let root = parent.appendingPathComponent("Shelf", isDirectory: true)
        _ = try? FileManager.default.createSymbolicLink(atPath: root.path,
                                                       withDestinationPath: missing.path)
        expect(!FileManager.default.fileExists(atPath: root.path),
               "fileExists reports a dangling link as absent")
        let type = (try? FileManager.default.attributesOfItem(atPath: root.path)[.type])
            as? FileAttributeType
        expectEqual(type ?? .typeUnknown, FileAttributeType.typeSymbolicLink,
                    "but attributesOfItem still sees the link itself")

        let shelf = Shelf(root: root)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must refuse a dangling symlink at the shelf root")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.blockedByFile(root),
                        "and it says a file is in the way, not that the volume went away")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }
        expect(!FileManager.default.fileExists(atPath: missing.path),
               "and the link's target was not created")
    }

    suite("shelf/create-path-unwritable-reports") {
        // A2: `createDirectory` succeeding is not evidence that the result can be written into.
        // This is the same defect round 1 fixed on the repair branch, which survived here for
        // four rounds. Measured with no stub: a parent with an inheritable `deny add_file` ACE
        // makes `mkdir` succeed, the child inherit the deny, `isWritableFile` false, and the
        // caller's first write fail with 513 — while `ensureExists()` reported success. A
        // `umask` of 0o222 reaches the same state through mode 0o555.
        let stub = UnwritableAfterCreateFileManager()
        let root = scratchDirectory("stub-create-unwritable")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must not report success on a folder nothing can write")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.shelfNotWritable(root),
                        "and it names the folder, with the same case the repair branch uses")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }
        expectEqual(stub.createDirectoryCalls, 1, "the folder was created exactly once")
        expect(!FileManager.default.fileExists(atPath: root.path),
               "and nothing was written to disk")
    }

    suite("shelf/create-path-vanished-is-success") {
        // The other half of the create-path post-condition. "Not writable" and "not there" are
        // different answers, and reporting the first when the second is true is exactly the
        // spurious `shelfNotWritable` round 4 removed from the repair branch — measured, under
        // two `rmdir` threads an unconditional check produced 814 of them in 10,000 calls.
        // `ensureExists()` is a precondition, not a lock; a folder that vanished the instant
        // after it was created is not a folder Chakra can honestly call unusable.
        let stub = VanishedAfterCreateFileManager()
        let root = scratchDirectory("stub-create-vanished")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
        } catch {
            expect(false, "a folder deleted again by another writer is not shelfNotWritable, "
                          + "got \(error)")
        }
        expectEqual(stub.createDirectoryCalls, 1, "the folder was created exactly once")
        expectEqual(stub.fileExistsWithDirectoryCalls, 2,
                    "fileExists(isDirectory:) called twice: initial check, then after the create")
        expect(!FileManager.default.fileExists(atPath: root.path),
               "and nothing was written to disk")
    }

    suite("shelf/file-appears-after-the-type-check") {
        // A3/W1: the window between the type check and the writability check. A stub answers
        // "directory" while a real regular file occupies the path — `isWritableFile` on a *file*
        // returns true, so the old early return handed back success with a file sitting in the
        // shelf's path, and the caller's next write died with 512, "the volume went away".
        // Measured 30 times in 40,000 concurrent calls, and deterministically here.
        //
        // The fix is the deliberate absence of an early return: the healthy path falls through to
        // `createDirectory`, which throws 516 over a file, which is already mapped to
        // `blockedByFile`. Everything except the type check in this stub is the real
        // `FileManager`, so the 516 is Foundation's, not the stub's.
        let root = scratchDirectory("w1-swap").appendingPathComponent("Shelf")
        let payload = Data("user data".utf8)
        _ = try? payload.write(to: root)
        expect(FileManager.default.isWritableFile(atPath: root.path),
               "isWritableFile on a regular file is true, which is what made this silent")

        let stub = LiesAboutDirectoryFileManager()
        let shelf = Shelf(root: root, fileManager: stub)
        do {
            try shelf.ensureExists()
            expect(false, "ensureExists must not succeed with a file occupying the shelf path")
        } catch let error as ShelfError {
            expectEqual(error, ShelfError.blockedByFile(root),
                        "and the error says a file is in the way")
        } catch {
            expect(false, "the error is a ShelfError, got \(error)")
        }
        expectEqual(stub.calls, 1, "the lying type check was consulted once")
        // Never-auto-delete: the user's file is untouched.
        expectEqual((try? Data(contentsOf: root)) ?? Data(), payload,
                    "and the user's file is byte-identical afterwards")
    }

    // MARK: - Task 4: sizes, counting and the cap

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
        //
        // Measured: this one is filtered by `.skipsHiddenFiles` before `isLitter` ever sees it
        // (`isHidden = true`), so it passes with `isLitter` returning `false`. It is kept as a
        // regression check on the *option*, not on `isLitter`.
        try? Data().write(to: root.appendingPathComponent(".DS_Store"))
        expectEqual(shelf.total().count, 2, ".DS_Store is not an item")

        // `Icon\r` has isHidden = false — measured — so it survives .skipsHiddenFiles and
        // has to be excluded by name. This is the only clause of `isLitter` that does work.
        try? Data(repeating: 0x42, count: 10).write(to: root.appendingPathComponent("Icon\r"))
        expectEqual(shelf.total().count, 2, "Icon\\r is not an item either")

        // A copy in flight must not appear as a shelf entry. Also hidden (measured
        // `isHidden = true`, the leading dot), so like `.DS_Store` this guards the option.
        try? Data(repeating: 0x43, count: 10)
            .write(to: root.appendingPathComponent(".chakra-incoming-abc"))
        expectEqual(shelf.total().count, 2, "an in-flight copy is not an item")

        // A directory counts as one item, with its contents summed.
        let folder = root.appendingPathComponent("folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(repeating: 0x44, count: 500).write(to: folder.appendingPathComponent("inner.txt"))
        expectEqual(shelf.total().count, 3, "a folder is one item")
        expectEqual(shelf.total().bytes, 850, "and its interior is included in the total")

        // A package: a directory macOS presents as one document, which §2.13 accepts as one
        // item with its interior in the size. Measured 2026-09-22: `.totalFileSizeKey` is nil
        // for **any** directory, package or not, so a package routed down the `totalFileSize`
        // branch reports 0. This exact fixture gave `(4, 850)` before the fix against a true
        // `(4, 5850)` — and because `add(_:)` reads `total().bytes` as the existing total, a
        // shelf of `.photoslibrary` bundles reported ~0 bytes and the 1 GB cap never fired.
        // No fixture in either task reached a package, which is why both halves stayed green.
        let package = root.appendingPathComponent("doc.rtfd")
        try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try? Data(repeating: 0x45, count: 5000)
            .write(to: package.appendingPathComponent("TXT.rtf"))
        // Matched on the path component, not `name`: `displayName(atPath:)` answers to the
        // user's extension-hiding preference and is not the test's business.
        let packaged = shelf.items().first { $0.url.lastPathComponent == "doc.rtfd" }
        expect((try? package.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true,
               "the fixture really is a package, or this suite proves nothing")
        expectEqual(packaged?.bytes ?? -1, 5000, "a package's interior is counted")
        expectEqual(packaged?.isDirectory ?? true, false,
                    "but it is one document, not a folder the user opens")
        expectEqual(shelf.total().count, 4, "and the package is one item")
        expectEqual(shelf.total().bytes, 5850, "with its bytes in the total")
    }

    suite("shelf/item-name-is-the-display-name") {
        // `items()` builds `name` from `displayName(atPath:)` rather than `lastPathComponent`, and
        // that call is 78% of the scan's measured cost. Measured: swapping it for
        // `lastPathComponent` left all 2051 checks green — nothing distinguished them. macOS swaps
        // ":" and "/" between the POSIX and display layers, which is the entire reason for the
        // call: a file stored as `with:colon.txt` is shown to the user as `with/colon.txt`.
        //
        // Asserted on the swap rather than on the whole string, because `displayName(atPath:)` also
        // honours the user's extension-hiding preference, which is not this suite's business.
        let box = scratchDirectory("display-name")
        let root = box.appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let stored = "with:colon.txt"
        try? Data(repeating: 0x41, count: 4).write(to: root.appendingPathComponent(stored))
        guard let item = shelf.items().first else {
            expect(false, "the fixture landed on the shelf")
            return
        }
        expectEqual(item.url.lastPathComponent, stored,
                    "the path component keeps the POSIX colon, or this suite proves nothing")
        expect(item.name.contains("/"),
               "and the item's name is the one Finder shows, got \(item.name)")
        expect(!item.name.contains(":"),
               "never the POSIX spelling, got \(item.name)")
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
        // The label went through two corrections and both are worth recording. It first claimed
        // "the item note fires at ten" when nothing read the constant at all — a claim about
        // behaviour that did not exist. It was then corrected to say nothing consumed it. As of
        // Task 10 that is wrong too: `ShelfMessage.summary` reads it, and
        // `shelf-message/summary` asserts both sides of the threshold. So the note really does
        // fire at ten now, and this check pins the number it fires at.
        expectEqual(Shelf.itemNoteThreshold, 10,
                    "the item note fires at ten, and ShelfMessage.summary is what fires it")

        // The refusal has to name all three numbers so the message can do the arithmetic
        // for the user.
        //
        // Comparing the value to an identical literal — which is what this did — is a
        // tautology: synthesised `Equatable` is reflexive and no product code runs, so no
        // change anywhere in Chakra could ever redden it. What every other `expectEqual` on a
        // `ShelfError` in this file silently depends on is that the synthesised `==` really
        // compares the payload, so that is what is asserted instead: change any single field
        // and the values must differ.
        let error = ShelfError.wouldExceedCap(dropBytes: 900, existingBytes: 800,
                                              capBytes: 1000)
        expect(error != .wouldExceedCap(dropBytes: 901, existingBytes: 800, capBytes: 1000),
               "the drop size is part of the cap error's identity")
        expect(error != .wouldExceedCap(dropBytes: 900, existingBytes: 801, capBytes: 1000),
               "and so is the existing total")
        expect(error != .wouldExceedCap(dropBytes: 900, existingBytes: 800, capBytes: 1001),
               "and so is the cap")
    }

    suite("shelf/sort-breaks-ties") {
        // `Array.sorted` is documented as making no stability guarantee, so a run of items
        // sharing one `added` value comes out in whatever order `readdir` returned and the hub
        // reshuffles between scans. Real ties happen: an unzip, a `cp -p`, a restore that
        // stamps a whole batch. The most severe defect this project has shipped was an
        // unbroken tie.
        //
        // The comparator is tested directly because a tie cannot be manufactured on disk:
        // measured, `addedToDirectoryDate` has sub-microsecond resolution on APFS — eight
        // files written back to back were 0.17 ms apart, all eight distinct — and
        // `URLResourceValues.addedToDirectoryDate` is get-only, so it cannot be written either.
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let item: (String, Date) -> ShelfItem = { name, added in
            ShelfItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                      bytes: 0, added: added, isDirectory: false)
        }
        expect(Shelf.newestFirst(item("b.txt", moment.addingTimeInterval(1)),
                                 item("a.txt", moment)),
               "a newer item sorts first whatever its name")
        expect(Shelf.newestFirst(item("apple.txt", moment), item("banana.txt", moment)),
               "two items sharing one date fall back to the name")
        expect(!Shelf.newestFirst(item("banana.txt", moment), item("apple.txt", moment)),
               "and the fallback is an ordering, not a coin toss")

        let tied = ["delta", "alpha", "echo", "bravo", "golf", "charlie", "hotel", "foxtrot"]
            .map { item($0, moment) }
        expectEqual(tied.sorted(by: Shelf.newestFirst).map { $0.name },
                    ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"],
                    "eight tied items sort by name, every time")
    }

    suite("shelf/newest-first-is-intake-order") {
        // What the hub sorts by is when the file landed, not when it was authored. Measured
        // 2026-09-22: `copyItem` preserves the source's creation date — true through the
        // temp-name-then-`moveItem` route `copyIn` uses as well — so a source stamped
        // 2001-09-09 lands with `creationDate = 2001-09-09` while `addedToDirectoryDate` is
        // `now`. Sorting on the creation date put a file shelved *today* at the bottom of the
        // hub, which is the one thing the hub's order is for.
        let box = scratchDirectory("intake-order")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)

        let ancient = box.appendingPathComponent("ancient.txt")
        try? Data(repeating: 0x41, count: 12).write(to: ancient)
        var values = URLResourceValues()
        values.creationDate = Date(timeIntervalSince1970: 1_000_000_000)   // 2001-09-09
        values.contentModificationDate = values.creationDate
        var stamped = ancient
        do { try stamped.setResourceValues(values) } catch { expect(false, "setup: \(error)") }

        let fresh = box.appendingPathComponent("fresh.txt")
        try? Data(repeating: 0x42, count: 34).write(to: fresh)

        // `fresh` is shelved first and `ancient` second, so intake order puts `ancient` on top
        // while creation order would put it at the bottom.
        expectEqual(shelf.add([fresh]).added, ["fresh.txt"], "the new file is shelved first")
        expectEqual(shelf.add([ancient]).added, ["ancient.txt"], "then the old one")

        expectEqual(shelf.items().map { $0.url.lastPathComponent },
                    ["ancient.txt", "fresh.txt"],
                    "the file shelved most recently is first, whatever its creation date")
        // Asserted on the old file by name rather than on whatever sorted first, so this stays
        // a check on the *date* even if the ordering above is what breaks.
        let shelved = shelf.items().first { $0.url.lastPathComponent == "ancient.txt" }
        expect((shelved?.added ?? Date.distantPast).timeIntervalSinceNow > -300,
               "and the old file's `added` is the intake moment, not 2001, "
               + "got \(shelved?.added as Any)")
        // The source really was stamped in 2001, so the assertion above is not vacuous.
        let created = (try? ancient.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        expectEqual(created ?? Date(), Date(timeIntervalSince1970: 1_000_000_000),
                    "the source's own creation date is 2001, not today")
    }

    // MARK: - Task 5: verified copy

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
        // `skipped` is always empty in v1: §6's `shouldProceedAfterError` delegate is
        // deliberately not implemented, because a skipped child makes the copy smaller than its
        // source and `copyIn`'s size check would then refuse the whole folder as
        // `volumeDisconnected`. The field exists so that fix needs no change of shape.
        expectEqual(outcome.skipped.count, 0, "and nothing was skipped")
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

        // A missing source. `resolve()` *does* pre-check with `fileExists` — an earlier comment
        // here claimed it deliberately did not — because that names the item the user dropped
        // rather than whatever it resolved to. The pre-check is not a substitute for mapping
        // `copyItem`'s own error: the TOCTOU window it cannot close is covered by
        // `shelf/error-codes-mapped`, where a 260 out of `copyItem` becomes the same
        // `sourceMissing`.
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
        if let payload = capPayload(over.refusals) {
            expectEqual(payload.drop, 4096, "the refusal names the drop size")
            expectEqual(payload.existing, 0, "and the existing total")
            expectEqual(payload.cap, 1000, "and the cap")
        } else {
            expect(false, "the refusal is a cap refusal, got \(over.refusals)")
        }
    }

    suite("shelf/cap-refusal-tells-the-truth") {
        // §2.12's message does arithmetic with this number — "they total X, free up Y" — so a
        // lower bound is a lie the user acts on. The accumulator in `add(_:)` is a lower bound
        // twice over: the early bail abandons the tree it is walking the moment the total
        // passes the headroom, and the `break` leaves every remaining source unmeasured.
        //
        // Measured before the re-total, with exactly these fixtures: the folder reported
        // `dropBytes: 2000` for 50,000 bytes, and the two-file drop reported 4096 for 8192. The
        // brief's own fixture was one flat 4,096-byte file, which cannot show either.
        let box = scratchDirectory("cap-truth")

        let folder = box.appendingPathComponent("fifty")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<50 {
            try? Data(repeating: 0x41, count: 1000)
                .write(to: folder.appendingPathComponent("f\(index).bin"))
        }
        let tiny = Shelf(root: box.appendingPathComponent("Tiny"), capBytes: 1000)
        let over = tiny.add([folder])
        expectEqual(over.added.count, 0, "an over-cap folder copies nothing at all")
        expectEqual(over.refusals.count, 1, "and reports one refusal")
        if let payload = capPayload(over.refusals) {
            expectEqual(payload.drop, 50_000,
                        "the refusal names the true total, not the bail's running total")
            expectEqual(payload.existing, 0, "the shelf was empty")
            expectEqual(payload.cap, 1000, "and the cap is the one this shelf was given")
        } else {
            expect(false, "the refusal is a cap refusal, got \(over.refusals)")
        }
        expectEqual(tiny.total().count, 0, "and nothing landed")

        // The other half: sources discarded by the `break`, which no folder fixture can show.
        let first = box.appendingPathComponent("first.bin")
        let second = box.appendingPathComponent("second.bin")
        try? Data(repeating: 0x42, count: 4096).write(to: first)
        try? Data(repeating: 0x43, count: 4096).write(to: second)
        let pair = Shelf(root: box.appendingPathComponent("Pair"), capBytes: 1000)
        let both = pair.add([first, second])
        expectEqual(both.refusals.count, 1, "two over-cap files are one refusal")
        if let payload = capPayload(both.refusals) {
            expectEqual(payload.drop, 8192,
                        "and the drop counts both files, not just the first")
        } else {
            expect(false, "the refusal is a cap refusal, got \(both.refusals)")
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

        // `.first`, not `[0]`. `expectEqual(added.count, 1, …)` above records a failure and keeps
        // going, so the subscript aborted the whole binary with `Index out of range` and SIGTRAP
        // whenever the drop was refused — discarding the accumulated failure list and skipping
        // `removeScratchDirectories()`. Measured: reverting `copyIn`'s containment guard reddened
        // this suite as exit 133 with **zero** checks reported.
        let copied = outcome.added.first.map { root.appendingPathComponent($0) }
        let isLink = copied.flatMap {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
        }
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
        //
        // Driven by a stub whose `copyItem` creates the destination and *then* throws, which is
        // §4.1's measured folder-copy shape. The obvious fixture — a missing source — proves
        // nothing at all: `resolve()` refuses it before `copyIn` is reached, so `copyItem` is
        // never called (measured: 0 calls), and the suite asserts the absence of a temp file
        // that was never created. It passed with every cleanup line deleted.
        let box = scratchDirectory("litter")
        let root = box.appendingPathComponent("Shelf")
        let source = box.appendingPathComponent("keep.txt")
        try? Data(repeating: 0x41, count: 64).write(to: source)

        let stub = FailingCopyFileManager()
        let shelf = Shelf(root: root, fileManager: stub)
        let outcome = shelf.add([source])

        expectEqual(stub.copyAttempts, 1, "the copy was attempted, so cleanup really ran")
        // There used to be `expectEqual(stub.moveAttempts, 0, "and no rename happened, …")` here.
        // It is gone because it became a constant: `copyIn` no longer calls
        // `FileManager.moveItem` at all — `grep -c "fileManager.moveItem" Sources/Shelf.swift` is
        // 0 — so the stub's counter cannot be non-zero even on a **fully successful** add.
        // Measured: a successful drop left the file on the shelf with `copyAttempts: 1` and
        // `moveAttempts: 0`. The check read as coverage of "nothing became visible" and could
        // never have failed. What that claim actually rests on is the two assertions below, which
        // observe the shelf rather than the stub.
        expectEqual(outcome.added.count, 0, "a failed copy adds nothing")
        expectEqual(outcome.refusals, [ShelfError.sourceUnreadable("keep.txt")],
                    "and the failure is reported against the source's name")

        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        expect(!names.contains(where: { $0.hasPrefix(Shelf.incomingPrefix) }),
               "no temporary file survives a failed copy, found \(names)")
        expectEqual(shelf.total().count, 0, "and the shelf is still empty")
        expectEqual(names.count, 0, "with nothing else left behind either, found \(names)")
    }

    suite("shelf/error-codes-mapped") {
        // §6's table, one row at a time. `mapped(_:name:)` is `private static`, so the only
        // honest way in is through `add(_:)` with a stub that throws the code from `copyItem` —
        // and before this suite existed every row was untested.
        //
        // The constants were measured on 2026-09-22 rather than recalled:
        // 640 `NSFileWriteOutOfSpaceError`, 512 `NSFileWriteUnknownError`,
        // 513 `NSFileWriteNoPermissionError`, 260 `NSFileReadNoSuchFileError`. Two traps in
        // that list: `NSFileNoSuchFileError` is **4**, not 260, so matching on it would never
        // fire; and `NSFileReadNoPermissionError` is **257**, not 513.
        //
        // 516 `EEXIST` is absent deliberately — §6 says it is never surfaced. In `copyIn` it
        // can only arrive from `moveItem`, where the naming loop consumes it; out of `copyItem`
        // it is unreachable, because the destination is a freshly minted UUID.
        let refusal: (Int) -> ShelfError? = { code in
            let box = scratchDirectory("mapped-\(code)")
            let source = box.appendingPathComponent("item.txt")
            try? Data(repeating: 0x41, count: 16).write(to: source)
            let stub = FailingCopyFileManager(errorCode: code)
            let shelf = Shelf(root: box.appendingPathComponent("Shelf"), fileManager: stub)
            let outcome = shelf.add([source])
            expectEqual(stub.copyAttempts, 1, "code \(code) reached copyItem")
            return outcome.refusals.first
        }

        expectEqual(refusal(NSFileWriteOutOfSpaceError),
                    ShelfError.notEnoughSpace("item.txt"),
                    "640 ENOSPC becomes \"not enough space to add item.txt\"")
        expectEqual(refusal(NSFileWriteUnknownError),
                    ShelfError.volumeDisconnected("item.txt"),
                    "512 EIO becomes \"the disk holding item.txt was disconnected\"")
        expectEqual(refusal(NSFileReadUnknownError),
                    ShelfError.volumeDisconnected("item.txt"),
                    "256, the read-side EIO, says the same thing")
        expectEqual(refusal(NSFileWriteNoPermissionError),
                    ShelfError.sourceUnreadable("item.txt"),
                    "513 EACCES becomes \"Chakra can't read item.txt\"")
        expectEqual(refusal(NSFileReadNoPermissionError),
                    ShelfError.sourceUnreadable("item.txt"),
                    "and so does 257, the read-side EACCES")
        expectEqual(refusal(NSFileReadNoSuchFileError),
                    ShelfError.sourceMissing("item.txt"),
                    "260 ENOENT becomes \"item.txt is no longer there\"")
        expectEqual(refusal(NSFileNoSuchFileError),
                    ShelfError.sourceUnreadable("item.txt"),
                    "4 is NOT the missing-file code, and must not be mapped as one")
        expectEqual(refusal(NSFileWriteInvalidFileNameError),
                    ShelfError.sourceUnreadable("item.txt"),
                    "an unlisted code falls back to the readable message, never a raw NSError")

        // Nothing from `mapped` may leak `FileManager`'s own text, which §6 forbids: measured,
        // for an unreadable source it names the *destination*, "you don't have permission to
        // access 'dst'".
        let leaked = refusal(NSFileWriteNoPermissionError)
        expect(!"\(leaked as Any)".contains("permission to access"),
               "and no FileManager text survives the mapping, got \(leaked as Any)")
    }

    suite("shelf/remove") {
        let box = scratchDirectory("remove")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        // Place a file directly in the shelf folder for removal testing
        let uuid = UUID().uuidString
        let testFile = root.appendingPathComponent("chakra-test-trashed-\(uuid).txt")
        try? Data(repeating: 0x41, count: 10).write(to: testFile)

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

        // The assertion that makes this suite worth its cost. Until now its only check was the
        // line above, which a plain `unlink` satisfies just as well — measured, sabotaging
        // `trashItem` to `removeItem` left this suite green and put **zero** files in the Trash.
        // So the one suite that spends the user's real Trash bought no coverage the stub suite
        // `shelf/remove-error-handling` did not already provide, while its comment claimed to be
        // "the real Trash test required by spec §2.17".
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        let trashed = trash?.appendingPathComponent(item.url.lastPathComponent)
        expect(trashed.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
               "and it is really in the Trash, still recoverable, not unlinked")

        // Takes this run's own file back out again. Without this the suite accumulated one
        // `chakra-test-trashed-<uuid>.txt` in the user's Trash per run — 178 of them by the time
        // anyone counted. Only ever this run's uniquely named file is touched.
        if let trashed { _ = try? FileManager.default.removeItem(at: trashed) }
    }

    suite("shelf/remove-error-handling") {
        // Drive the error path with a stub so error handling is covered without touching
        // the real Trash repeatedly.
        let stub = FailingTrashFileManager()
        let root = scratchDirectory("remove-error")
            .appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, fileManager: stub)
        let dummyItem = ShelfItem(url: root.appendingPathComponent("nonexistent.txt"),
                                  name: "nonexistent.txt",
                                  bytes: 0,
                                  added: Date(),
                                  isDirectory: false)
        do {
            try shelf.remove(dummyItem)
            expect(false, "remove must throw when trashItem fails")
        } catch {
            // Expected to throw
        }
        expectEqual(stub.trashItemCalls, 1, "trashItem was called exactly once")
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
        // Correction 2: The original single-pass `run(mode:before:)` returns as soon as the
        // first input source is processed (the raw vnode event), long before the 0.2 s debounce
        // deadline. So the callback has not fired yet either way, and the test would pass even
        // with an empty `stopWatching()`. The spin loop waits through the entire quiet period.
        let quiet = Date(timeIntervalSinceNow: 0.6)
        while Date() < quiet {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        expectEqual(fired, before, "no more callbacks arrive after stopWatching")
    }

    suite("shelf/watch-delete-teardown") {
        let box = scratchDirectory("watch-delete")
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        // Settle first, so the descriptor count below means something.
        drainMainQueue(for: 0.2)
        let beforeWatching = openDescriptorCount()

        var fired = 0
        shelf.onChange = { fired += 1 }
        shelf.startWatching()

        // Delete the folder to trigger .delete event
        try? FileManager.default.removeItem(at: root)

        // Wait for the delete event to fire
        let deadline = Date(timeIntervalSinceNow: 1.0)
        while fired == 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        expect(fired > 0, "onChange fires when the folder is deleted")

        // Now verify the watcher has stopped: recreate the folder and modify it,
        // and verify no new callbacks arrive
        do { try shelf.ensureExists() } catch { expect(false, "recreate: \(error)") }
        let afterDelete = fired
        try? Data("new".utf8).write(to: root.appendingPathComponent("after-delete.txt"))

        // Wait to confirm no callback
        let quiet = Date(timeIntervalSinceNow: 0.6)
        while Date() < quiet {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        expectEqual(fired, afterDelete,
                    "the watcher stopped itself on .delete and did not fire for the new write")

        // The behavioural check above cannot fail on its own, and that is why this one exists.
        // Once the folder is deleted the descriptor is stale, so no event can arrive for the
        // recreated folder whether the teardown ran or not — measured, replacing
        // `stopWatching()` in the `.delete` branch with a bare `coalesceWork?.cancel()` left
        // all 1938 checks green. What the teardown is actually for is releasing the descriptor,
        // so that is the post-condition worth asserting.
        drainMainQueue(for: 0.3)
        let leaked = openDescriptorCount() - beforeWatching
        expectEqual(leaked, 0,
                    "the .delete teardown closed the watcher's descriptor, leaked \(leaked)")
    }

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

    suite("shelf/cross-volume-hash") {
        let box = scratchDirectory("cross-volume")
        let source = box.appendingPathComponent("payload.bin")
        try? Data(repeating: 0x41, count: 4096).write(to: source)

        // The control. On one volume the copy is a clone, identical by construction, so the
        // size check is conclusive and no hash is computed — and a same-size corruption is
        // therefore accepted. This half is here to show that the cross-volume half below is
        // testing the hash and not something else.
        let sameVolumeManager = CorruptingCopyFileManager()
        let sameVolumeShelf = Shelf(root: box.appendingPathComponent("SameVolume"),
                                    fileManager: sameVolumeManager)
        sameVolumeShelf.sameVolumeOverride = { _, _ in true }
        let accepted = sameVolumeShelf.add([source])
        expectEqual(accepted.added.count, 1,
                    "on one volume a same-size copy is accepted on size alone")
        expect(accepted.refusals.isEmpty, "on one volume nothing is refused")

        // Across volumes real bytes moved. The sizes still match, so only the hash can tell
        // that what arrived is not what was sent.
        let crossVolumeManager = CorruptingCopyFileManager()
        let crossRoot = box.appendingPathComponent("CrossVolume")
        let crossVolumeShelf = Shelf(root: crossRoot, fileManager: crossVolumeManager)
        crossVolumeShelf.sameVolumeOverride = { _, _ in false }
        let refused = crossVolumeShelf.add([source])
        expect(refused.added.isEmpty, "across volumes a copy with different bytes is not added")
        expectEqual(refused.refusals, [.volumeDisconnected("payload.bin")],
                    "the mismatch is reported as volumeDisconnected")
        expectEqual(crossVolumeManager.copyAttempts, 1, "the copy was attempted exactly once")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: crossRoot.path))
            ?? ["unreadable"]
        expectEqual(leftovers, [], "the unverified copy is removed rather than left as litter")
    }

    suite("shelf/cross-volume-unreadable") {
        let box = scratchDirectory("cross-volume-unreadable")
        let source = box.appendingPathComponent("locked.bin")
        try? Data(repeating: 0x41, count: 2048).write(to: source)

        let manager = UnreadableAfterCopyFileManager()
        let root = box.appendingPathComponent("Shelf")
        let shelf = Shelf(root: root, fileManager: manager)
        shelf.sameVolumeOverride = { _, _ in false }
        let outcome = shelf.add([source])

        // Both digests are nil here. A bare `digest(of: source) == digest(of: temporary)` would
        // compare nil to nil and let the copy through: "could not be read" is not "matches".
        expect(outcome.added.isEmpty,
               "a cross-volume copy neither side of which can be hashed is not added")
        expectEqual(outcome.refusals, [.volumeDisconnected("locked.bin")],
                    "an unverifiable cross-volume copy is refused, not accepted")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))
            ?? ["unreadable"]
        expectEqual(leftovers, [], "the unverifiable copy is removed rather than left as litter")

        // Hand the permissions back, or the scratch cleanup cannot walk the tree.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: source.path)
    }

    suite("shelf/watch-no-descriptor-leak") {
        // A behavioural guard is not enough here, and that is the whole reason this suite
        // exists. `shelf/watch-delete-teardown` asserts that no further `onChange` arrives,
        // and both a `[weak self]` cancel handler and one capturing the local descriptor
        // cancel the source — so both stay green while one of them leaks one file descriptor
        // per watcher. The leak needs `self` to be *deallocated before the cancel handler
        // runs*, which no other suite arranges. Measured on this tree: with the local capture,
        // 40 watchers open 40 descriptors and close 40; with `[weak self]`, 40 open and 0
        // close.
        let box = scratchDirectory("watch-leak")

        // Settle first. Earlier suites leave watchers and coalesced work in flight, and a
        // descriptor count only means something when nothing else is closing one.
        drainMainQueue(for: 0.2)
        let before = openDescriptorCount()

        let watchers = 40
        do {
            var shelves: [Shelf] = []
            for index in 0..<watchers {
                let shelf = Shelf(root: box.appendingPathComponent("s\(index)"))
                do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }
                shelf.startWatching()
                shelves.append(shelf)
            }
            let alive = openDescriptorCount()
            expectEqual(alive - before, watchers,
                        "each watcher holds one open descriptor, got \(alive - before)")
            // Dropping the last reference is the point: `deinit` cancels the source, and the
            // cancel handler is what must close the descriptor.
            shelves.removeAll()
        }
        drainMainQueue(for: 0.4)

        let after = openDescriptorCount()
        expectEqual(after - before, 0,
                    "a deallocated watcher closes its descriptor, leaked \(after - before)")
    }

    // MARK: - Pasteboard intake

    suite("shelf/paste-write-error-names-its-real-cause") {
        // §6's whole premise is that every refusal names its real cause: `ShelfError` exists
        // because `FileManager`'s own text is actively misleading. The staging write in
        // `add(pasteboard:)` reported `notEnoughSpace` for *every* error code, so five measured
        // non-ENOSPC failures — a read-only staging directory (513), a staging path under a
        // regular file (512), a 300-character component (514), an absent directory (4), and a
        // directory occupying the staging path (512) — all told the user to free disk space on a
        // volume measured with 790 GiB free. `mapped(_:name:)` already holds the right table and
        // was simply not called.
        let box = scratchDirectory("paste-write-error")
        let locked = box.appendingPathComponent("locked-temp", isDirectory: true)
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                   ofItemAtPath: locked.path)
        expect(!FileManager.default.isWritableFile(atPath: locked.path),
               "the setup made the staging directory unwritable, or this suite proves nothing")

        let board = testBoard("write-error")
        putPNG(board, side: 8, "write-error")

        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true),
                          fileManager: StagingDirectoryFileManager(directory: locked))
        let outcome = shelf.add(pasteboard: board)
        expectEqual(outcome.added.count, 0, "a paste that cannot be staged adds nothing")
        expectEqual(outcome.refusals.count, 1, "and reports exactly one refusal")

        // The success arm asserts something, rather than `expect(true, …)`. A literal `true` reads
        // as coverage, inflates the check count, and cannot fail — the real check was only ever the
        // `else` branch.
        let refusal = outcome.refusals.first ?? .nothingUsableOnClipboard
        if case .sourceUnreadable(let named) = refusal {
            expect(named.hasPrefix("Pasted "),
                   "a 513 is reported as unreadable and names the pasted file, got \(named)")
        } else {
            expect(false, "a 513 must not be reported as notEnoughSpace, got \(refusal)")
        }

        // Hand the permissions back, or the scratch cleanup cannot walk the tree.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: locked.path)
    }

    suite("shelf/paste-stages-in-its-own-directory") {
        // The staging *name* was the pasted name alone, which has one-second resolution and so
        // is not unique. Two pastes in the same second staged to the same path, `Data.write(to:)`
        // truncates, and the second write replaced the first's bytes before the first `copyIn`
        // read them. Measured: 30 of 30 concurrent rounds, 60 files announced, far fewer on
        // disk, and **zero refusals** — precisely the miscount `AddOutcome`'s own docstring says
        // the type exists to prevent. The predictable path was also a pre-plantable symlink
        // target, which sent the write outside the temporary directory entirely.
        //
        // Asserted on the staging directory rather than by racing two threads: uniqueness is the
        // property that fixes this, and it can be checked deterministically.
        let box = scratchDirectory("paste-unique")
        let temporary = box.appendingPathComponent("temp", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let stub = StagingDirectoryFileManager(directory: temporary)
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true),
                          fileManager: stub)

        let first = testBoard("unique-one")
        putPNG(first, side: 8, "unique-one")
        let second = testBoard("unique-two")
        putPNG(second, side: 24, "unique-two")

        let one = shelf.add(pasteboard: first)
        let two = shelf.add(pasteboard: second)
        expectEqual(one.refusals.count, 0, "the first paste is accepted, got \(one.refusals)")
        expectEqual(two.refusals.count, 0, "the second paste is accepted, got \(two.refusals)")

        expectEqual(stub.createdInTemporary.count, 2,
                    "each paste stages inside a directory of its own, "
                    + "got \(stub.createdInTemporary)")
        expect(stub.createdInTemporary.count == 2
                && stub.createdInTemporary[0] != stub.createdInTemporary[1],
               "and the two staging directories are different paths")
        expect(stub.createdInTemporary.allSatisfy { $0.hasPrefix(Shelf.incomingPrefix) },
               "named so the sweep can recognise them, got \(stub.createdInTemporary)")

        // Both pastes survive with their own bytes. The fixtures are different sizes by
        // construction, which is what makes this discriminating rather than a name check.
        let sizes = shelf.items().map { $0.bytes }.sorted()
        expectEqual(sizes.count, 2, "two pastes leave two items")
        expect(sizes.first != sizes.last,
               "and neither overwrote the other's bytes, got \(sizes)")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path))
            ?? ["unreadable"]
        expectEqual(leftovers, [], "and no staging directory survives, found \(leftovers)")
    }

    suite("shelf/concurrent-collision-loses-nothing") {
        // The naming loop's race-safety rested on a comment claiming `moveItem` throws rather
        // than clobbers. It does throw — but only because it tests for the destination *first*
        // and then calls `rename(2)`, which is check-then-act. Measured: two callers racing on
        // one name announced two files and left one in 182 of 200 thread trials and 11 of 20
        // trials with two real processes. A file the user had just shelved was destroyed while
        // `AddOutcome` reported success for both callers.
        //
        // `expect` is deliberately not called from the workers: the harness's `checks` and
        // `failures` are globals and would race with each other. Results are collected under a
        // lock and asserted here on one thread.
        let box = scratchDirectory("concurrent-collision")
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true))
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let callers = 8
        var sources: [URL] = []
        for index in 0..<callers {
            let directory = box.appendingPathComponent("src\(index)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("report.pdf")
            // A distinct size per caller, so a lost file shows up as a missing payload and not
            // only as a missing name.
            try? Data(repeating: UInt8(0x41 + index), count: 100 + index).write(to: file)
            sources.append(file)
        }

        let lock = NSLock()
        var announced: [String] = []
        DispatchQueue.concurrentPerform(iterations: callers) { index in
            let outcome = shelf.add([sources[index]])
            lock.lock()
            announced.append(contentsOf: outcome.added)
            lock.unlock()
        }

        let landed = shelf.items()
        expectEqual(announced.count, callers, "every caller announced its file")
        expectEqual(Set(announced).count, announced.count,
                    "no two callers announced the same name, got \(announced.sorted())")
        expectEqual(landed.count, announced.count,
                    "every announced file is really on the shelf, announced "
                    + "\(announced.sorted()), found \(landed.map { $0.name }.sorted())")
        expectEqual(Set(landed.map { $0.bytes }).count, callers,
                    "and all \(callers) distinct payloads survived")
    }

    suite("shelf/concurrent-start-watching-leaks-nothing") {
        // `guard watchSource == nil else { return }` is not synchronised. Measured: with four
        // threads calling `startWatching()` at once, 300 of 300 trials had two descriptors open
        // simultaneously, and the losing source was resumed and never cancelled — its own event
        // handler holds it strongly, so ARC cannot reclaim it and the descriptor survived both
        // `stopWatching()` and deallocation. ThreadSanitizer reported a write race on
        // `watchSource` as well, which is an ARC reference: a torn retain count, not merely a
        // lost value.
        let box = scratchDirectory("watch-race")
        drainMainQueue(for: 0.2)
        let before = openDescriptorCount()

        // A start gate, not `concurrentPerform`. Measured: with `concurrentPerform(iterations: 4)`
        // and sub-millisecond work, GCD sometimes runs the four calls serially, so the guard is
        // never contended and the suite **missed its own defect in 2 of 30 runs** — a 7% false
        // negative, which is worse than no test. Four threads parked on a semaphore and released
        // together contend every time. Trials raised from 20 to 30 for the same reason.
        let trials = 30
        for index in 0..<trials {
            let shelf = Shelf(root: box.appendingPathComponent("s\(index)", isDirectory: true))
            do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

            let gate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            for _ in 0..<4 {
                DispatchQueue.global().async(group: group) {
                    gate.wait()
                    shelf.startWatching()
                }
            }
            for _ in 0..<4 { gate.signal() }
            group.wait()
            shelf.stopWatching()
        }
        drainMainQueue(for: 0.4)

        let leaked = openDescriptorCount() - before
        expectEqual(leaked, 0,
                    "\(trials) watchers started from four threads each leak no descriptor, "
                    + "leaked \(leaked)")
    }

    suite("shelf/sweep-keeps-an-in-flight-copy") {
        // `sweepIncoming` defaulted an unreadable modification date to `Date.distantPast`, which
        // reads as "infinitely old" and deletes. That is fail-open on the one path in this file
        // that removes a file without the user asking, so it has to fail closed instead — the
        // age check exists precisely because a copy may still be in flight in another instance.
        //
        // **This suite does not prove the guard, and that is stated rather than implied.** Four
        // probe shapes — a fresh file, a live symlink, a dangling symlink, and a symlink whose
        // target sits behind a mode-0 directory — all returned a date, so nothing here can drive
        // the nil. Measured: restoring the `?? Date.distantPast` default leaves all 2,007 checks
        // green, so the fail-closed guard is unproven, not covered.
        //
        // What these two checks do pin is the age comparison either side of it — inverting
        // `modified < cutoff` reddens both of them. That is worth having, and it is less than the
        // suite's name suggests.
        let box = scratchDirectory("sweep-undatable")
        let root = box.appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let fresh = root.appendingPathComponent(Shelf.incomingPrefix + "in-flight")
        try? Data(repeating: 0x41, count: 8).write(to: fresh)
        // A dangling link named like an in-flight copy: the sweep must not remove it on the
        // strength of a date it could not read.
        let dangling = root.appendingPathComponent(Shelf.incomingPrefix + "dangling")
        _ = try? FileManager.default.createSymbolicLink(
            atPath: dangling.path,
            withDestinationPath: box.appendingPathComponent("no-such-target").path)

        shelf.sweepIncoming(olderThan: 60)
        expect(FileManager.default.fileExists(atPath: fresh.path),
               "a copy that may still be in flight is kept")
        let danglingType = (try? FileManager.default.attributesOfItem(atPath: dangling.path)[.type])
            as? FileAttributeType
        // Labelled for what it is. This check used to say "an entry whose date the sweep could not
        // read", which is false: measured, a dangling symlink returns a perfectly good
        // `contentModificationDate`. It is a dangling link kept on its age, nothing more, and the
        // suite was renamed to stop claiming otherwise.
        expectEqual(danglingType ?? .typeUnknown, FileAttributeType.typeSymbolicLink,
                    "and so is a dangling link named like one, on its age alone")
    }

    suite("shelf/root-built-from-a-path-string") {
        // `copyIn`'s containment guard compared whole `URL` values. `URL` equality is
        // trailing-slash sensitive and `deletingLastPathComponent()` always returns a directory
        // URL, so whether the guard held depended on whether the injected root happened to carry
        // `hasDirectoryPath` — nothing at all to do with the name it exists to check. Measured
        // across four constructions of one path: `URL(fileURLWithPath:)` with no hint failed the
        // guard for all 999 candidates, and a perfectly good drop came back as `sourceUnreadable`
        // after 11 ms of futile renames. `defaultRoot()` passes `isDirectory: true` and every
        // other fixture in this file lands on the working side, which is why it stayed invisible.
        let box = scratchDirectory("path-string-root")
        let source = box.appendingPathComponent("payload.txt")
        try? Data(repeating: 0x41, count: 32).write(to: source)

        let root = URL(fileURLWithPath: box.appendingPathComponent("Shelf").path)
        expect(!root.hasDirectoryPath,
               "the root is not directory-flagged, or this suite proves nothing")

        let shelf = Shelf(root: root)
        let outcome = shelf.add([source])
        expectEqual(outcome.added, ["payload.txt"],
                    "a root built from a path string still accepts a drop")
        expectEqual(outcome.refusals.count, 0, "and refuses nothing, got \(outcome.refusals)")
        expectEqual(shelf.total().bytes, 32, "and the bytes really landed")
    }

    suite("shelf/collision-exhaustion-names-its-cause") {
        // Reachable, and it used to lie. With all 999 candidate names taken, the next drop was
        // refused as `sourceUnreadable` — a case documented on itself as
        // `NSFileWriteNoPermissionError` (513) / `EACCES` — so a user whose file reads perfectly
        // well would be told Chakra cannot read it. Measured at 64 ms, clobbering nothing. There
        // was no coverage at all: a sabotage that changed the thrown case left 1938 checks green.
        let box = scratchDirectory("exhaustion")
        let root = box.appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        // Every candidate name `copyIn` will try, already occupied.
        let sanitized = ShelfName.sanitize("dup.txt")
        for attempt in 1...ShelfName.maxAttempts {
            let name = ShelfName.candidate(sanitized, attempt: attempt)
            try? Data(repeating: 0x41, count: 1).write(to: root.appendingPathComponent(name))
        }
        expectEqual(shelf.total().count, ShelfName.maxAttempts,
                    "every candidate name is occupied")

        let source = box.appendingPathComponent("dup.txt")
        try? Data(repeating: 0x42, count: 5).write(to: source)
        let outcome = shelf.add([source])
        expectEqual(outcome.added.count, 0, "a drop with no name left to take adds nothing")
        expectEqual(outcome.refusals, [ShelfError.tooManyNames("dup.txt")],
                    "and names its real cause, rather than claiming the source is unreadable")
        expectEqual(shelf.total().count, ShelfName.maxAttempts,
                    "and nothing already on the shelf was clobbered")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        expect(!names.contains { $0.hasPrefix(Shelf.incomingPrefix) },
               "and no temporary copy survives, found \(names.count) entries")
    }

    // MARK: - The cap's arithmetic against a shelf that is not empty

    suite("shelf/cap-counts-what-is-already-there") {
        // The `existing` term of the cap had no coverage at all. Every cap fixture in this file
        // used a fresh, empty shelf, so `existing` was always 0 and every assertion about it was
        // `expectEqual(0, 0)`. Measured: replacing `let existing = total().bytes` with a literal
        // `0` — so the cap ignores everything already on the shelf and it grows without limit —
        // left all 1941 checks green.
        let box = scratchDirectory("cap-existing")
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true),
                          capBytes: 1000)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let source: (String, Int) -> URL = { name, bytes in
            let directory = box.appendingPathComponent("src-\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try? Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        expectEqual(shelf.add([source("first.bin", 800)]).added, ["first.bin"],
                    "800 bytes fit an empty 1000-byte shelf")
        expectEqual(shelf.total().bytes, 800, "and the shelf now holds them")

        // 300 more is 1100 against a 1000-byte cap. It only exceeds the cap if what is already on
        // the shelf is counted, which is the whole point of this suite.
        let second = shelf.add([source("second.bin", 300)])
        expectEqual(second.added.count, 0, "a drop that would only fit an empty shelf is refused")
        // The count, not just the payload. `capPayload` returns the *first* cap refusal, so a
        // spurious extra refusal alongside it left this suite completely green — measured, only the
        // older `add-refuses` and `cap-refusal-tells-the-truth` caught that, because they assert a
        // count.
        expectEqual(second.refusals.count, 1, "exactly once, got \(second.refusals)")
        if let payload = capPayload(second.refusals) {
            expectEqual(payload.existing, 800, "and the refusal names what was already there")
            expectEqual(payload.drop, 300, "and the size of the drop")
            expectEqual(payload.cap, 1000, "and the cap")
        } else {
            expect(false, "the refusal is a cap refusal, got \(second.refusals)")
        }
        expectEqual(shelf.total().bytes, 800, "and nothing was copied")

        // The boundary, in both directions, on a shelf that is not empty. Nothing pinned this
        // either: measured, flipping `dropBytes > headroom` to `>=` left all 1941 checks green, so
        // the cap could silently become exclusive. Shipped behaviour is inclusive.
        expectEqual(shelf.add([source("exact.bin", 200)]).added, ["exact.bin"],
                    "a drop of exactly the remaining headroom is accepted")
        expectEqual(shelf.total().bytes, 1000, "which fills the shelf to the cap exactly")
        let overflowing = shelf.add([source("one-more.bin", 1)])
        expectEqual(overflowing.added.count, 0, "and one byte more than the cap is refused")
        expect(capPayload(overflowing.refusals) != nil,
               "with a cap refusal, got \(overflowing.refusals)")
    }

    suite("shelf/digest-refuses-a-pipe") {
        // `FileHandle.read(upToCount:)` blocks forever on a FIFO — measured, a direct
        // `digest(of:)` on one had to be killed after 15 s. It went unnoticed because it is
        // unreachable through `add(_:)`: `copyItem` refuses a FIFO immediately with 512 /
        // `ENOTSUP` in 0.0000 s, with or without a writer attached, so the digest is never asked
        // for. But `digest(of:)` is `internal` rather than `private`, because these tests call it,
        // so a future caller would inherit an unbounded block with no timeout.
        //
        // Read this suite's failure mode honestly: if the regular-file guard is removed, the check
        // below does **not** go red — the whole test binary hangs. A hang is a worse signal than a
        // red check, and it is also precisely why the guard is code rather than a comment.
        let box = scratchDirectory("fifo")
        let pipe = box.appendingPathComponent("pipe.bin")
        let made = pipe.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return mkfifo(path, 0o644) == 0
        }
        expect(made, "the fixture really is a FIFO, or this suite proves nothing")

        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true))
        expect(shelf.digest(of: pipe) == nil, "a FIFO has no digest, and does not block")

        // And the reachable path: a FIFO dropped on the shelf is refused rather than hung on.
        shelf.sameVolumeOverride = { _, _ in false }
        let outcome = shelf.add([pipe])
        expectEqual(outcome.added.count, 0, "a FIFO is not shelved")
        expectEqual(outcome.refusals.count, 1, "and is refused exactly once, got \(outcome.refusals)")
    }

    suite("shelf/concurrent-adds-respect-the-cap") {
        // The cap is a read of the filesystem followed by a write to it, and nothing held the two
        // together. Bytes in flight are invisible to `total()` — `isLitter` excludes the
        // `.chakra-incoming-` prefix — so two concurrent callers each saw the full headroom.
        // Measured before the fix: two threads, a 900-byte file each, a 1,000-byte cap →
        // **1,800 bytes landed in 25 of 25 trials with zero refusals**, both callers told the drop
        // succeeded. At eight callers it reached 7,200 bytes on the same cap, so the overage is
        // not bounded by a constant. Separate `Shelf` instances behaved identically, so it is the
        // filesystem read and not shared mutable state.
        //
        // Deterministic with the gate in place: the first caller through sees headroom 1,000 and
        // lands, and every later caller sees headroom 100 against a 900-byte drop.
        //
        // `expect` is deliberately not called from the workers — the harness's `checks` and
        // `failures` are globals and would race with each other.
        let box = scratchDirectory("concurrent-cap")
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true),
                          capBytes: 1000)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let callers = 4
        var sources: [URL] = []
        for index in 0..<callers {
            let directory = box.appendingPathComponent("src\(index)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("payload\(index).bin")
            try? Data(repeating: 0x41, count: 900).write(to: url)
            sources.append(url)
        }

        let lock = NSLock()
        var accepted = 0
        var refused = 0
        var capRefusals = 0
        DispatchQueue.concurrentPerform(iterations: callers) { index in
            let outcome = shelf.add([sources[index]])
            lock.lock()
            accepted += outcome.added.count
            refused += outcome.refusals.count
            if capPayload(outcome.refusals) != nil { capRefusals += 1 }
            lock.unlock()
        }

        expectEqual(accepted, 1, "exactly one 900-byte drop fits a 1000-byte cap")
        expectEqual(refused, callers - 1,
                    "and the other \(callers - 1) are refused rather than silently accepted")
        // The refusal *kind*, not just the count. Measured: changing `add()`'s cap refusal from
        // `.wouldExceedCap` to `.sourceUnreadable` reddened 7 checks in six other suites and **none
        // in this one** — three refusals of any kind plus one accept would have satisfied it.
        expectEqual(capRefusals, callers - 1,
                    "and each refusal is a cap refusal, not some other error")
        expect(shelf.total().bytes <= 1000,
               "the shelf never exceeds its cap, got \(shelf.total().bytes)")
        expectEqual(shelf.total().count, 1, "and holds exactly one item")
    }

    suite("shelf/exceeds-cap-is-the-same-arithmetic-add-uses") {
        // `exceedsCap` was lifted out of `add(_:)` so the hub can predict, before the user lets go,
        // the refusal `add(_:)` would give. The whole point is that there is one implementation, so
        // what is asserted here is that the two **agree** — a second copy of the arithmetic would
        // eventually predict one answer and refuse with another, which is worse than not predicting.
        let box = scratchDirectory("exceeds-cap")
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true),
                          capBytes: 1000)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        let source: (String, Int) -> URL = { name, bytes in
            let directory = box.appendingPathComponent("src-\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try? Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        // Both sides, on an empty shelf. Without the second of these a predicate that always said
        // "too big" would pass.
        let fits = source("fits.bin", 400)
        let huge = source("huge.bin", 4096)
        expect(!shelf.exceedsCap([fits], existing: 0), "400 bytes fit a 1000-byte cap")
        expect(shelf.exceedsCap([huge], existing: 0), "4096 bytes do not")

        // And on a shelf that is not empty, which is the term the hub passes and the one that has
        // to move with the folder's contents.
        expectEqual(shelf.add([fits]).added, ["fits.bin"], "the shelf now holds 400 bytes")
        expectEqual(shelf.total().bytes, 400, "confirmed")
        let second = source("second.bin", 400)
        expect(!shelf.exceedsCap([second], existing: 400), "400 more still fits")
        let third = source("third.bin", 700)
        expect(shelf.exceedsCap([third], existing: 400), "but 700 more does not")

        // The agreement, which is the reason this function exists rather than a second copy.
        let predicted = shelf.exceedsCap([third], existing: shelf.total().bytes)
        let actual = capPayload(shelf.add([third]).refusals) != nil
        expectEqual(predicted, actual,
                    "the prediction and the real refusal agree, predicted \(predicted)")

        // The boundary, inclusive, matching the cap itself. Measured on `add(_:)`: flipping
        // `dropBytes > headroom` to `>=` left every check green before that boundary was pinned.
        let exact = source("exact.bin", 600)
        expect(!shelf.exceedsCap([exact], existing: 400),
               "a drop of exactly the remaining headroom fits")
        let oneMore = source("one-more.bin", 601)
        expect(shelf.exceedsCap([oneMore], existing: 400), "and one byte more does not")

        // Several sources counted together, not just the first — the bug `add(_:)`'s own suite
        // pins, asserted here too because the hub passes whole drops.
        expect(shelf.exceedsCap([second, exact, oneMore], existing: 400),
               "a drop is measured as a whole")
    }

    suite("shelf/hidden-entries-are-counted") {
        // `items()` passed `.skipsHiddenFiles`, so any hidden top-level entry was invisible to
        // `total()` and therefore to the cap. Measured on the shipped 1 GiB cap: 20 hidden files
        // of 500 MB reported `(count: 0, bytes: 0)` against 9.77 GiB really in the folder, and a
        // further 1 GiB drop was accepted — unbounded. Worse, those bytes were unreachable from
        // inside Chakra: `items()` never listed them, so `remove(_:)` could never be handed one.
        //
        // What makes this a defect rather than a policy question is `UF_HIDDEN` — an ordinary BSD
        // flag on an ordinary name, preserved by `copyItem`. One plain drag-and-drop returned
        // `added: ["holiday.mov"]` and then `total() == (count: 0, bytes: 0)`: the app said it had
        // added a file it could then neither show nor delete. `sanitize` strips leading dots, so
        // the dot-name door into `add` was already shut; this one was not.
        let box = scratchDirectory("hidden")
        let root = box.appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        // A dot-named hidden file placed straight into the folder, which Finder or any other tool
        // can do at any time — the hub's own click action opens the folder in Finder.
        try? Data(repeating: 0x41, count: 500).write(to: root.appendingPathComponent(".notes.txt"))
        expectEqual(shelf.total().count, 1, "a hidden entry in the shelf folder is an item")
        expectEqual(shelf.total().bytes, 500, "and its bytes count toward the cap")

        // The drop route: UF_HIDDEN on an ordinary name, carried across by `copyItem`.
        let source = box.appendingPathComponent("holiday.mov")
        try? Data(repeating: 0x42, count: 700).write(to: source)
        var values = URLResourceValues()
        values.isHidden = true
        var flagged = source
        do { try flagged.setResourceValues(values) } catch { expect(false, "setup: \(error)") }
        expectEqual((try? source.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false, true,
                    "the fixture really is hidden, or this suite proves nothing")

        let outcome = shelf.add([source])
        expectEqual(outcome.added, ["holiday.mov"], "a hidden file is accepted")
        expectEqual(shelf.total().count, 2, "and it is an item the shelf can see")
        expectEqual(shelf.total().bytes, 1200, "with its bytes in the total")
        // The consequence that actually bit: it can be handed to `remove(_:)`.
        expect(shelf.items().contains { $0.url.lastPathComponent == "holiday.mov" },
               "and items() lists it, so it can be selected and removed")

        // `isLitter` is the only filter now, so every clause of it has to still work.
        try? Data().write(to: root.appendingPathComponent(".DS_Store"))
        try? Data(repeating: 0x43, count: 9).write(to: root.appendingPathComponent("._resource"))
        try? Data(repeating: 0x44, count: 9)
            .write(to: root.appendingPathComponent(Shelf.incomingPrefix + "flight"))
        try? Data(repeating: 0x45, count: 9).write(to: root.appendingPathComponent("Icon\r"))
        expectEqual(shelf.total().count, 2, "and Finder litter is still excluded, by name")
        expectEqual(shelf.total().bytes, 1200, "contributing no bytes")
    }

    suite("shelf/huge-logical-sizes-saturate") {
        // `+` traps on overflow in Swift, and every size here is *logical*. Measured: this volume
        // accepts a single file of 2^55−1 bytes, `ftruncate` creates one for free and `du -sh`
        // reports `0B` for the whole fixture — so 257 of them overflow `Int64`. Four sites
        // trapped, each with EXC_BREAKPOINT/SIGTRAP and a named frame: `size(of:limit:)`,
        // `total()`'s reduce, and both accumulators in `add(_:)`.
        //
        // The most reachable was the exact re-total on the refusal path — the line that exists for
        // truthfulness — reached by one ordinary drag-and-drop of one folder onto an empty shelf
        // at the shipped 1 GiB cap. The `limit` bail is no protection: the addition happens before
        // the comparison, and the refusal path re-walks with `limit: nil` anyway.
        let box = scratchDirectory("huge")
        let tree = box.appendingPathComponent("tree", isDirectory: true)
        try? FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)

        let enormous = Int64.max / 256
        var made = 0
        for index in 0..<260 {
            let url = tree.appendingPathComponent("sparse\(index).bin")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else { continue }
            do { try handle.truncate(atOffset: UInt64(enormous)) } catch { }
            try? handle.close()
            let reported = (try? url.resourceValues(forKeys: [.totalFileSizeKey]))?.totalFileSize
            if (reported ?? 0) > 0 { made += 1 }
        }
        expect(made >= 257, "the fixture really holds 257 sparse files, got \(made)")

        let measuring = Shelf(root: box.appendingPathComponent("Measure", isDirectory: true))
        expectEqual(measuring.size(of: tree, limit: nil), Int64.max,
                    "a walk of the whole tree saturates rather than trapping")

        // The one-drag-and-drop route, at the shipped cap.
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true),
                          capBytes: Shelf.capBytes)
        let outcome = shelf.add([tree])
        expectEqual(outcome.added.count, 0, "an impossibly large folder is refused, not copied")
        // Counted for the same reason as `cap-counts-what-is-already-there`: `capPayload` finds the
        // first cap refusal, so an extra spurious refusal would otherwise go unseen here.
        expectEqual(outcome.refusals.count, 1, "with exactly one refusal, got \(outcome.refusals)")
        if let payload = capPayload(outcome.refusals) {
            expectEqual(payload.drop, Int64.max,
                        "and the refusal reports the saturated total rather than crashing")
        } else {
            expect(false, "the refusal is a cap refusal, got \(outcome.refusals)")
        }

        // And `total()`, which is the hub-refresh path, with the same files as shelf entries.
        let live = Shelf(root: tree)
        let total = live.total()
        expectEqual(total.count, made, "every sparse file is one item")
        expectEqual(total.bytes, Int64.max, "and the total saturates rather than trapping")
    }

    suite("shelf/rename-errno-table") {
        // Every row, asserted directly. Only the `EACCES` row is reachable through `copyIn`, and a
        // sabotage of each of the other five left all 2,051 checks green — including
        // `ENAMETOOLONG`, which is the errno the whole `Int32`-instead-of-`Bool` redesign was built
        // around and the one quoted in its docstring's headline measurement.
        expectEqual(Shelf.mappedRename(ENAMETOOLONG, name: "a"), ShelfError.nameTooLong("a"),
                    "ENAMETOOLONG is its own case, not a collision and not \"can't read\"")
        expectEqual(Shelf.mappedRename(ENOSPC, name: "a"), ShelfError.notEnoughSpace("a"),
                    "ENOSPC is the one code that really means out of space")
        expectEqual(Shelf.mappedRename(EACCES, name: "a"), ShelfError.sourceUnreadable("a"),
                    "EACCES is unreadable")
        expectEqual(Shelf.mappedRename(EPERM, name: "a"), ShelfError.sourceUnreadable("a"),
                    "and so is EPERM")
        expectEqual(Shelf.mappedRename(EROFS, name: "a"), ShelfError.sourceUnreadable("a"),
                    "and EROFS")
        expectEqual(Shelf.mappedRename(ENOENT, name: "a"), ShelfError.sourceMissing("a"),
                    "ENOENT is a source that went away")
        expectEqual(Shelf.mappedRename(EIO, name: "a"), ShelfError.volumeDisconnected("a"),
                    "EIO is a volume that went away")
        // Not because `EEXIST` is meaningful here — the naming loop consumes it before this is
        // called — but because an unlisted code must land on a readable message rather than leak.
        expectEqual(Shelf.mappedRename(EDQUOT, name: "a"), ShelfError.sourceUnreadable("a"),
                    "an unlisted code falls back to a readable message, never a raw errno")
    }

    suite("shelf/rename-failure-names-its-real-cause") {
        // `renameWithoutClobbering` returned a bare `Bool`, so the naming loop could not tell "that
        // name is taken, try the next" from "this can never work". Every failure was retried 999
        // times and then reported as `tooManyNames`: measured on a real file, an `ENAMETOOLONG`
        // surfaced as "too many names" after 998 futile syscalls and about 40 ms.
        //
        // The rename is a raw syscall, so no `FileManager` stub can intercept it. This drives the
        // real `renamex_np` onto `EACCES` by making the shelf folder unwritable between the copy
        // and the rename.
        let box = scratchDirectory("rename-errno")
        let root = box.appendingPathComponent("Shelf", isDirectory: true)
        let source = box.appendingPathComponent("payload.txt")
        try? Data(repeating: 0x41, count: 24).write(to: source)

        let shelf = Shelf(root: root, fileManager: LocksRootAfterCopyFileManager(lockedRoot: root))
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }
        let outcome = shelf.add([source])

        // Permissions back first, unconditionally, so the scratch cleanup can walk the tree
        // whatever the assertions below do.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.path)

        expectEqual(outcome.added.count, 0, "a rename that can never succeed adds nothing")
        expectEqual(outcome.refusals.count, 1,
                    "and reports exactly one refusal, got \(outcome.refusals)")
        expectEqual(outcome.refusals, [ShelfError.sourceUnreadable("payload.txt")],
                    "mapped from errno rather than labelled a name collision, "
                    + "got \(outcome.refusals)")
    }

    suite("shelf/a-compatibility-ideograph-name-shelves-twice") {
        // The collision path, on the scalar that disproved a plain NFD count. A file named
        // 127 × U+2F804 is 254 UTF-16 units and the filesystem accepts it, but its decomposed
        // count is 127 — so the first version of the length fix left the name untouched, the
        // collision candidate was 256 units, and every one of `copyIn`'s 999 renames failed with
        // `ENAMETOOLONG`. Measured: drop 1 succeeded in 2.7 ms and drops 2, 3 and 4 were each
        // refused after ~40 ms. The file could be shelved once and never twice.
        let box = scratchDirectory("compat-ideograph")
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true))
        let name = String(repeating: "\u{2F804}", count: 127)

        let source: (Int) -> URL = { index in
            let directory = box.appendingPathComponent("src\(index)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try? Data(repeating: UInt8(0x41 + index), count: 10 + index).write(to: url)
            return url
        }

        let first = source(0)
        expect(FileManager.default.fileExists(atPath: first.path),
               "the 254-unit fixture really exists on disk, or this suite proves nothing")
        let one = shelf.add([first])
        expectEqual(one.refusals.count, 0, "the first drop is accepted, got \(one.refusals)")
        let two = shelf.add([source(1)])
        expectEqual(two.refusals.count, 0,
                    "and so is the second, which used to burn 999 renames and then lie, "
                    + "got \(two.refusals)")
        expectEqual(two.added.count, 1, "landing under a second name")
        expectEqual(shelf.total().count, 2, "so the shelf holds both")
        expectEqual(Set(shelf.items().map { $0.bytes }).count, 2,
                    "with both payloads intact, got \(shelf.items().map { $0.bytes })")
    }

    suite("shelf/system-litter-stays-out-of-the-hub") {
        // Dropping `.skipsHiddenFiles` was necessary — a `UF_HIDDEN` file the app said it had added
        // was otherwise invisible to `items()` forever — but it also let seven classes of macOS
        // volume metadata into the hub. Measured, all seven in one shelf folder, and `.Trashes` and
        // `.fseventsd` came back `isDirectory: true`, so `remove(_:)` would have offered to Trash
        // them. `isLitter` names them instead.
        let box = scratchDirectory("system-litter")
        let root = box.appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        // Every name in `Shelf.systemLitter` that can be planted as a file, plus the two prefix
        // rules. `.TemporaryItems` and `.DocumentRevisions-V100` are here because a sabotage of
        // each left all 2051 checks green — the first version of this fixture planted nine of the
        // eleven names and missed exactly those two.
        let clutter = [".VolumeIcon.icns", ".apdisk", ".Spotlight-V100", ".metadata_never_index",
                       ".localized", ".DS_Store", "Icon\r", "._resource",
                       ".TemporaryItems", ".DocumentRevisions-V100",
                       Shelf.incomingPrefix + "flight"]
        for name in clutter {
            try? Data(repeating: 0x41, count: 11).write(to: root.appendingPathComponent(name))
        }
        for name in [".fseventsd", ".Trashes"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try? Data(repeating: 0x42, count: 7)
                .write(to: directory.appendingPathComponent("inner"))
        }
        // Proof the fixture landed, or the whole suite is vacuous.
        //
        // One name short of the obvious total, and the reason is worth recording precisely, because
        // an earlier version of this comment got it wrong. `._resource` is written successfully and
        // then does not come back — but **`readdir(3)` does return it**; it is *Foundation* that
        // filters AppleDouble entries, in both the `atPath:` and `at:` spellings of
        // `contentsOfDirectory`. Measured: 9 names written, 8 returned by Foundation, all 9 listed
        // by raw `readdir`. So the `._` clause of `isLitter` cannot be exercised through any call
        // Chakra makes; it is kept because an `._*` file arriving from a FAT volume or an archive is
        // a real shape, not because this suite covers it.
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        expectEqual(onDisk.count, clutter.count + 1,
                    "every clutter fixture that can land really did, found \(onDisk.sorted())")

        expectEqual(shelf.total().count, 0, "none of it is a shelf item")
        expectEqual(shelf.total().bytes, 0, "and none of it counts toward the cap")

        // And a real file alongside it still shows, so the filter is not simply "hide everything".
        try? Data(repeating: 0x43, count: 5).write(to: root.appendingPathComponent("report.pdf"))
        expectEqual(shelf.total().count, 1, "while a real file beside it is still an item")
        expectEqual(shelf.total().bytes, 5, "with its bytes counted")
    }

    suite("shelf/a-negative-cap-refuses-rather-than-accepting-everything") {
        // `capBytes` is an injectable initialiser parameter, so `capBytes - existing` could
        // overflow. The saturating subtraction was added with the comment "it costs one line to
        // close" and no check behind it. Measured: with wrapping arithmetic, `Int64.min` minus a
        // non-empty shelf wraps to +9223372036854775800 and **every drop is accepted**; with
        // saturation it clamps to `Int64.min` and every drop is refused. Unreachable in the shipped
        // wiring, which always passes `Shelf.capBytes` — pinned so the clause cannot rot.
        let box = scratchDirectory("negative-cap")
        let root = box.appendingPathComponent("Shelf", isDirectory: true)
        let shelf = Shelf(root: root, capBytes: Int64.min)
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        // Something already on the shelf, so `existing` is not zero and the subtraction can wrap.
        try? Data(repeating: 0x41, count: 8).write(to: root.appendingPathComponent("seed.bin"))
        expectEqual(shelf.total().bytes, 8, "the shelf is not empty, or the subtraction cannot wrap")

        let source = box.appendingPathComponent("payload.bin")
        try? Data(repeating: 0x42, count: 16).write(to: source)
        let outcome = shelf.add([source])
        expectEqual(outcome.added.count, 0, "a drop against a nonsensical cap is refused")
        expect(capPayload(outcome.refusals) != nil,
               "with a cap refusal rather than silent acceptance, got \(outcome.refusals)")
        expectEqual(shelf.total().count, 1, "and nothing was copied in")
    }
}

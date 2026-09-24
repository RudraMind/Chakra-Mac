// `AppKit`, not `Foundation`. This file was Foundation-only until Task 8 and that was
// load-bearing, not incidental: it is the reason `Shelf` links into the UI-free test binary,
// and "no AppKit in Shelf.swift" is a property several reviews checked for. `add(pasteboard:)`
// takes an `NSPasteboard`, which is AppKit, so the rule ends here — it is being retired
// deliberately and on the record, not quietly.
//
// Nothing breaks: AppKit links into `run-tests.sh`'s binary fine, and the tests still need no
// window server, because a named `NSPasteboard` is not a UI object. But `ai/INVARIANTS.md` §1's
// evidence is now stale — the `nm -u` gated-symbol check and the `otool -L` framework list must
// both be re-run against a fresh build, since that audit is the only enforcement the
// never-prompt invariant has.
import AppKit
import CryptoKit

/// Why an intake or a folder operation could not be completed.
///
/// A typed error rather than the `NSError` `FileManager` produces, because that error's
/// `localizedDescription` is actively misleading: for a *source* file Chakra cannot read it
/// says "…you don't have permission to access 'dst'", naming the **destination**. Never
/// surface it. Each case here maps to text Chakra owns.
enum ShelfError: Error, Equatable {
    /// A file sits where the shelf folder should be. The only case that must not self-heal.
    case blockedByFile(URL)
    /// The shelf folder exists and is a directory, but Chakra cannot write into it and could
    /// not repair it. Distinct from `blockedByFile`: nothing is in the way, the folder itself
    /// is unusable.
    case shelfNotWritable(URL)
    /// The shelf folder could not be created, for a reason Chakra has no better name for.
    /// Carries the underlying POSIX-ish code purely so a bug report can say which, never to be
    /// shown to the user.
    ///
    /// This case exists because `FileManager`'s own message names the wrong file — measured, an
    /// unwritable parent yields "You don't have permission to save the file "Shelf" in the
    /// folder "locked"" — and §6 forbids surfacing that text.
    ///
    /// Codes this case *maps*, rather than "codes seen in testing": only 513 and 516 are
    /// exercised by anything in `Tests/`. The rest were reproduced by hand on 2026-09-22 with a
    /// probe that drives the real `createDirectory`, and are listed so that a number in a bug
    /// report can be recognised:
    ///
    /// - **513** (`EACCES`) — parent directory at mode `0500`.
    /// - **514** (`ENAMETOOLONG`) — a 300-character path component.
    /// - **518** — a non-`file:` URL handed to `init(root:)`. Note this case can therefore name
    ///   an `https` URL, despite being documented as naming a folder.
    /// - **642** (`NSFileWriteVolumeReadOnlyError`) — anything under `/nonexistent`, because the
    ///   macOS root volume is the read-only Signed System Volume. Worth knowing because it is
    ///   also why a test asserting "nothing was written" under `/nonexistent` can never go red.
    /// - **512** (`EIO`) — two measured sources, neither of them a disconnected volume: a
    ///   `mkdir` losing a race against another process's `rmdir`, and a dangling symlink at the
    ///   root path. The dangling-symlink route no longer reaches here, because `ensureExists()`
    ///   refuses a symlink before it creates anything.
    ///
    /// 640 (`ENOSPC`) was listed here previously. No probe reproduced it from `createDirectory`;
    /// a full disk surfaces during the copy, which is what `notEnoughSpace` is for.
    case shelfUnusable(URL, code: Int)
    /// `NSFileWriteOutOfSpaceError` (640) / `ENOSPC`. Carries the name so the message can say
    /// which item would not fit, as spec §6 requires.
    case notEnoughSpace(String)
    /// `NSFileReadNoSuchFileError` (260) / `ENOENT`. Note: `NSFileNoSuchFileError` is 4 and
    /// is *not* what a failed read throws, so matching on it would never fire.
    case sourceMissing(String)
    /// `NSFileWriteNoPermissionError` (513) / `EACCES`.
    case sourceUnreadable(String)
    /// `NSFileWriteUnknownError` (512) / `EIO` — in practice a volume that went away *during a
    /// copy*, which is the only place this case is raised from.
    ///
    /// Do not reuse this label for a 512 out of `ensureExists()`: measured, a `mkdir` racing
    /// another process's `rmdir` also yields 512, and so did a dangling symlink at the root path
    /// before that was refused outright. 512 on the folder path means "try again", not
    /// "your disk vanished".
    case volumeDisconnected(String)
    case wouldExceedCap(dropBytes: Int64, existingBytes: Int64, capBytes: Int64)
    /// A `.app` bundle. Refused: a copied bundle may not launch, and the wheel already
    /// exists for pinning applications.
    case isApplication(String)
    case nothingUsableOnClipboard
    /// Every one of the 999 candidate names was taken, or none of them could ever work.
    ///
    /// Reachable, measured: a shelf pre-loaded with `dup.txt` … `dup 999.txt` refuses the next
    /// `dup.txt` in 64 ms and clobbers nothing. 999 *directories* occupying the candidate names
    /// reach it too, in 98 ms.
    ///
    /// `copyIn` used to report `sourceUnreadable` here, which is documented as
    /// `NSFileWriteNoPermissionError` (513) / `EACCES` — so it broke its own stated contract and
    /// would have told a user whose file reads perfectly well that Chakra cannot read it. Nothing
    /// in the app consumes `AddOutcome.refusals` yet, so the user-facing string for this case is
    /// owed rather than wrong.
    case tooManyNames(String)
    /// The name the shelf would have to write is longer than the filesystem allows.
    ///
    /// Distinct from `tooManyNames`, and the distinction is the point: the rename loop used to
    /// treat *every* failure as "that name is taken, try the next", so an `ENAMETOOLONG` burned
    /// 998 futile syscalls and then reported "too many names". Measured on a real file named
    /// 127 × U+2F804: `renamex_np` returned `EEXIST` for attempt 1 and `ENAMETOOLONG` for attempts
    /// 2 through 999.
    ///
    /// `ShelfName.fileSystemLength` should now make this unreachable from `copyIn` — it is kept
    /// because the loop can no longer tell itself that, and a wrong label is what this case exists
    /// to stop. Like every other case here, its user-facing string is owed, not written.
    case nameTooLong(String)
}

/// One entry on the shelf. A folder or a package counts as one.
struct ShelfItem: Equatable {
    let url: URL
    /// What Finder would call it. `displayName(atPath:)` rather than `lastPathComponent`,
    /// because macOS swaps ":" and "/" between the POSIX and display layers — measured, a
    /// file stored as `with:colon.txt` displays as `with/colon.txt`.
    let name: String
    /// Logical size. `.totalFileSizeKey` for a file; for any directory, including a package,
    /// the recursive total — see the comment in `items()` for why the distinction matters.
    let bytes: Int64
    /// When this landed on the shelf, not when the original was authored. See `items()`.
    let added: Date
    /// True for a folder the user can open. False for a package, which is one document.
    let isDirectory: Bool
}

/// What happened to a drop. Reports every item, because "Added 2 apps" with three
/// unaccounted for is the bug this shape exists to prevent.
struct AddOutcome {
    var added: [String] = []
    var refusals: [ShelfError] = []
    /// Items that landed, but with something inside them left behind.
    ///
    /// **Always empty in v1, deliberately.** Spec §6 describes a `FileManagerDelegate` that
    /// returns `true` from `shouldProceedAfterError` so a folder with one unreadable child
    /// copies anyway, skipping that child. That delegate is not implemented, and must not be
    /// added without also changing `copyIn`: a skipped child makes the copy legitimately
    /// smaller than its source, and `copyIn`'s size verification would then throw
    /// `volumeDisconnected` and refuse the whole folder — turning "added, skipped 1 item" into
    /// "your disk went away", which is a worse lie than the one the delegate fixes.
    ///
    /// The field exists now so that fix needs no change to this type's shape or to any caller.
    var skipped: [String] = []
}

/// The file shelf: a folder of copied files, with the sizes and the counting that the
/// wheel's hub displays.
///
/// UI-free on purpose, and constructed with an injected root directory, so it links into
/// the test binary and can be exercised against a throwaway folder — the same shape as
/// `OuterRing` and `Recents` taking an injected `UserDefaults`.
///
/// "UI-free" still holds, but as of Task 8 it no longer means "Foundation-only": see the note
/// on the `import` at the top of this file. `NSPasteboard` is an AppKit type with no window
/// and no window server behind it, so the class stays testable without one.
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

    /// This shelf's cap. An instance value so a test can use a small one; production always
    /// takes the default.
    ///
    /// `Shelf.capBytes` (the static) stays the shipped value; `self.capBytes` shadows it inside
    /// the instance, which is why the initialiser default spells out `Shelf.capBytes`.
    let capBytes: Int64

    init(root: URL, fileManager: FileManager = FileManager(),
         capBytes: Int64 = Shelf.capBytes) {
        self.root = root
        self.fileManager = fileManager
        self.capBytes = capBytes
    }

    /// The shipped location: `~/Library/Application Support/local.chakra/Shelf`.
    ///
    /// The bundle identifier rather than "Chakra", because macOS 14+
    /// `kTCCServiceSystemPolicyAppData` prompts for access to *another* app's container —
    /// being unambiguously inside our own is what keeps that prompt impossible.
    ///
    /// Resolved through `FileManager`, never by concatenating `NSHomeDirectory()`: that
    /// path differs under a sandbox, and a future sandbox flag would otherwise silently
    /// relocate the shelf and orphan every file.
    ///
    /// Note the returned URL is a *directory* URL and so carries a trailing slash. `URL`
    /// equality is slash-sensitive — measured, `file:///…/Shelf/` does not equal
    /// `file:///…/Shelf` — so any comparison against this value, including against
    /// `ShelfError.blockedByFile`, must build its URL the same way or compare `path` instead.
    ///
    /// **This is not a pure getter.** `create: true` makes `FileManager` create
    /// `~/Library/Application Support` if it is missing, and that write is the only reason the
    /// function is `throws`. It stops there: the `local.chakra/Shelf` pair is appended as strings
    /// and is never created here, which is what `ensureExists()` is for.
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
    /// Shape of the function, and why it is this shape:
    ///
    /// 1. Refuse a symlink at `root` outright. This is the only security check in the file; see
    ///    the comment on the guard itself.
    /// 2. If something is already there and is not a directory, refuse. A *file* in the way is
    ///    the one condition that must never self-heal.
    /// 3. If it is a directory that cannot be written into, attempt one `chmod` and verify the
    ///    result. Chakra created this folder and owns it, so that is repair, not destruction.
    /// 4. Otherwise fall through to `createDirectory` unconditionally — including when the
    ///    folder already exists and looks healthy. `createDirectory(withIntermediateDirectories:
    ///    true)` is idempotent on an existing directory (measured) and throws 516 if the path
    ///    has become a file, which is mapped to `blockedByFile` below. That fall-through is what
    ///    closes the window described at step 4 in the `createDirectory` comment.
    /// 5. Verify writability afterwards. The create call succeeding is not evidence that the
    ///    folder can be written into; see the comment on that guard.
    ///
    /// There is no `build.sh` analogy here, despite an earlier comment claiming one. `build.sh:67`
    /// regenerates the icon *conditionally* and the repair at step 3 is *also* conditional, so
    /// "an unconditional repair mirroring build.sh" was wrong in both halves and sent maintainers
    /// looking for code that does not exist.
    func ensureExists() throws {
        // A symlink at the shelf's own path is refused before anything touches it.
        //
        // This is not hygiene, it is the one real security hole this function had.
        // `fileExists(atPath:isDirectory:)` follows a symlink and reports the *target*'s type,
        // and `setAttributes` is `chmod(2)` rather than `lchmod` — so a link planted here made
        // Chakra widen permissions on a directory it does not own. Measured: a victim directory
        // went 0500 -> 0755 while `ensureExists()` returned success. No race is needed; the
        // link can be planted before Chakra's first run, because `local.chakra/` does not exist
        // yet.
        //
        // `attributesOfItem` reports the link itself rather than its target, which is why it is
        // the right question to ask here — measured, it returns `NSFileTypeSymbolicLink` for
        // both a live and a dangling link without following either. A dangling link used to
        // reach `createDirectory` and come back as `shelfUnusable(512)`, i.e. "your volume went
        // away"; it is now the truthful `blockedByFile`.
        //
        // Known gap, recorded rather than silently fixed: a symlinked *intermediate* component
        // is still followed. Measured — with `local.chakra` a symlink, `Shelf` is created inside
        // the target. Refusing that would break a user who deliberately moved
        // `Application Support` to another volume, so it is a policy decision, not a one-liner.
        //
        // Cost, measured on this machine: 12.8 us per call, against 1.1 us for a bare `stat`.
        // `destinationOfSymbolicLink` would answer the same question in 2.1 us if this ever
        // lands somewhere hot. It is called once per shelf operation, so it is not hot.
        if let type = (try? fileManager.attributesOfItem(atPath: root.path)[.type])
            as? FileAttributeType, type == .typeSymbolicLink {
            throw ShelfError.blockedByFile(root)
        }

        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            // A *file* in the way is the one thing that must not be repaired silently: it
            // is user data of unknown value, and removing it would breach never-auto-delete.
            //
            // This particular `guard` is belt-and-braces: measured, a real `createDirectory`
            // over a file throws 516, which the `catch` below already maps to the identical
            // `blockedByFile(root)`. What the surrounding `if fileExists` block is genuinely
            // load-bearing for is the **repair branch** underneath it. Delete the block and an
            // existing read-only folder is silently accepted, because `createDirectory` succeeds
            // on an existing directory whatever its mode. A maintainer told this guard exists
            // "to detect a file" may remove it during a tidy-up, watch `shelf/blocked-by-a-file`
            // still pass through the 516 catch, and reintroduce the round 1 defect.
            guard isDirectory.boolValue else { throw ShelfError.blockedByFile(root) }

            // A read-only folder is different from a file in the way. Chakra created this
            // folder and owns it, so restoring its permissions is repair, not destruction.
            //
            // The result is verified rather than assumed, and that is not belt-and-braces.
            // Measured on a directory carrying an ACL `deny add_file` ACE, POSIX mode already
            // 0o755: `setAttributes([.posixPermissions: 0o755])` **succeeds**, the mode is
            // unchanged at 0o755, and `isWritableFile` is still false — a real `open(O_CREAT)`
            // in it fails with 513. So the call's own result would report success on a folder
            // nothing can write to. Writability is the only post-condition that means anything.
            //
            // An earlier version of this comment cited `chflags uchg` instead. That was wrong,
            // and wrong in the way `ai/GOTCHAS.md` #20 warns about: measured, under `uchg`
            // `setAttributes` **throws 513**. What succeeded silently was `/bin/chmod`, because
            // BSD `chmod` skips the syscall when the requested mode already matches. The
            // evidence had come from a shell tool rather than from the API this line calls.
            //
            // Spec §5 requires attempting the repair once and then verifying writability.
            // Measured: a second `chmod` is pointless. Under `uchg` it throws again; in the
            // reachable ACL case it *succeeds* again and still changes nothing. Either way it
            // buys nothing, so this verifies instead of repeating.
            if !fileManager.isWritableFile(atPath: root.path) {
                _ = try? fileManager.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.path)

                if fileManager.isWritableFile(atPath: root.path) {
                    return  // Repair succeeded
                }

                // Still not writable. But the window between the initial existence check and
                // here can let another writer delete then recreate the folder — measured: 665
                // spurious `shelfNotWritable` in 160,000 concurrent calls before this recheck,
                // 6 after. So re-check with `isDirectory:` and branch on what is actually there.
                var isDirectory = ObjCBool(false)
                if !fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
                    // Gone. Fall through to create path below.
                } else if !isDirectory.boolValue {
                    // Another writer replaced it with a file. That is the truthful error.
                    throw ShelfError.blockedByFile(root)
                } else if fileManager.isWritableFile(atPath: root.path) {
                    // A directory, and writable — another writer already fixed it. Success.
                    return
                } else {
                    // Present, a directory, and genuinely not writable.
                    throw ShelfError.shelfNotWritable(root)
                }
            }

            // Deliberately no `return` for the healthy case. See step 4 of the summary above and
            // the window listed in the `createDirectory` comment below.
        }
        do {
            // Reached on three routes: the folder is absent, the folder vanished mid-repair, or
            // the folder is a healthy writable directory. The third route is the point.
            //
            // The window it closes: between the type check above and the writability check,
            // another writer can replace the directory with a file. `isWritableFile` on a *file*
            // returns true, so the old early return handed back **success with a file sitting in
            // the shelf's path**, and the caller's next write then failed with 512 — the code
            // this file used to label "the volume went away", so a user with a file named `Shelf`
            // in the way was told their disk had disappeared.
            //
            // Measured against this file by injecting the real directory-to-file swap inside
            // `fileExists(atPath:isDirectory:)`, so no timing luck is involved: 2,000 of 2,000
            // trials returned success with a file in the path before this change, 0 of 2,000
            // after, all 2,000 now `blockedByFile`. A wall-clock race is useless as a measurement
            // here — the old function returns in about 6 us, quicker than the shortest `usleep` a
            // swapper thread can take, so it reports a misleading zero. The user's planted file
            // was byte-identical in every trial of both runs.
            //
            // The extra `mkdir` on an already-existing directory is not free, and the honest
            // accounting is:
            //
            // - Time: 2.8 us for the call, 8.5 us for the whole fall-through including the
            //   re-checks, against 6.0 us for the old early return. Paid once per shelf
            //   operation, immediately before a file copy, so it is invisible.
            // - Robustness under an adversarial `rmdir` loop: with two threads doing nothing but
            //   removing the folder, running `mkdir` on every call takes 10,000 calls from
            //   9,982 successes and 15 errors to 8,866 successes and about 1,110 errors, all of
            //   them a retryable 512. That harness is not a shape Chakra produces; the realistic
            //   one is 16 concurrent callers with no deleter, where both versions succeed 16 of
            //   16.
            // - The alternative shape — keep the early return but re-assert the type before
            //   taking it — was built and measured too. Same 0 of 2,000 on the W1 injection, and
            //   9,238 successes with 750 errors under the `rmdir` loop, so it is only modestly
            //   better there. It was not taken because it leaves two ways to succeed and two
            //   places to map errors, which is how this window survived four rounds of review.
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            // A *file* occupies this path. Measured: `createDirectory` throws 516 with text
            // naming the wrong file, which §6 forbids surfacing — and a file in the way is
            // exactly `blockedByFile`.
            throw ShelfError.blockedByFile(root)
        } catch let error as NSError {
            // Everything else. Mapped rather than rethrown, because `FileManager`'s text names
            // the wrong file and §6 forbids showing it.
            throw ShelfError.shelfUnusable(root, code: error.code)
        }

        // `createDirectory` succeeding is not evidence that anything can be written into the
        // result. This is the same defect round 1 fixed on the repair branch, which survived on
        // this branch for four rounds; it is not redundant with that check, it covers the other
        // half of the function.
        //
        // Measured two ways, with no stub and no race:
        //
        // - A parent carrying an inheritable `everyone deny add_file,file_inherit,
        //   directory_inherit` ACE. `mkdir` is permitted, the child inherits the deny-ACE, mode
        //   is 0o755, `isWritableFile` is false, and the caller's first write fails with 513.
        // - A `umask` of 0o222, because `createDirectory` is called with no `attributes:`. The
        //   folder is created at mode 0o555. Not reachable in the shipped wiring, where a GUI
        //   app's umask is 022, but it is the same hole through a second door.
        //
        // In both cases `ensureExists()` previously returned success.
        //
        // The three questions are asked in this order — is it there, is it a directory, can it
        // be written — and the order is load-bearing:
        //
        // - Writability first is what the obvious one-line version does, and it leaks a narrower
        //   copy of the defect it was added to fix: `isWritableFile` on a *file* returns true, so
        //   a directory swapped for a file after the `mkdir` comes straight back as success. That
        //   version was built and measured — 13 to 34 such returns per 20,000 timed trials,
        //   depending on the run — before the order was changed.
        // - "Not there" is not "not writable". Reporting `shelfNotWritable` for a folder another
        //   writer has just deleted is the same lie round 4 removed from the repair branch;
        //   measured, under two `rmdir` threads an unconditional report produced 814 of them in
        //   10,000 calls against 1 when the question is asked properly.
        var createdDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: root.path, isDirectory: &createdDirectory) else {
            // Deleted again by another writer between the `mkdir` and this check. Nothing
            // truthful is left to report: `ensureExists()` is a precondition, not a lock, and
            // even an unqualified success can be invalidated the instant it returns.
            return
        }
        guard createdDirectory.boolValue else { throw ShelfError.blockedByFile(root) }
        guard fileManager.isWritableFile(atPath: root.path) else {
            throw ShelfError.shelfNotWritable(root)
        }
    }

    // MARK: - Listing, counting and sizes

    /// The prefix on a copy that is still in flight.
    ///
    /// Hidden, so a partial copy can never appear as a shelf entry, and recognisable, so
    /// `sweepIncoming(olderThan:)` can bin one left behind by a crash.
    ///
    /// The paragraph that used to sit here described `isLitter`'s name list, not this constant —
    /// a maintainer reading the doc for `incomingPrefix` was told about `Icon\r`.
    static let incomingPrefix = ".chakra-incoming-"

    /// Names that are never shelf items however they are flagged.
    ///
    /// `items()` no longer passes `.skipsHiddenFiles` — see the comment there for why, and what it
    /// cost — so this is the only filter, and `.DS_Store` and `.chakra-incoming-*` reach it rather
    /// than being dropped upstream. Both are live: sabotaging them reddens 12 and 7 checks.
    ///
    /// `Icon\r` was always the clause that did work under the old option too: measured, its
    /// `isHidden` is false. It matters because clicking the hub opens the folder in Finder, which
    /// creates exactly this file. Sabotaging it reddens 8 checks.
    ///
    /// **The `._` clause is dead code, and an earlier version of this comment claimed every clause
    /// was load-bearing.** Measured: an `._resource` file is created successfully and then *never
    /// returned* by `contentsOfDirectory` in either spelling — Foundation filters AppleDouble
    /// entries at the enumeration layer, so nothing downstream can see one. Sabotaging the clause
    /// to `hasPrefix("._ZZ")` reddens nothing. It is kept because an `._*` file arriving from a FAT
    /// volume or an archive is a real shape and the clause costs one comparison, not because
    /// anything here exercises it.
    /// macOS volume metadata, which `.skipsHiddenFiles` used to hide for free.
    ///
    /// Dropping that option was necessary — a `UF_HIDDEN` file the app said it had added was
    /// otherwise invisible to `items()` forever — but it also let seven classes of system clutter
    /// into the hub. Measured, all seven in one shelf folder: `.VolumeIcon.icns`, `.apdisk`,
    /// `.Spotlight-V100`, `.metadata_never_index`, `.fseventsd`, `.Trashes`, `.localized`. The last
    /// two come back `isDirectory: true`, so `remove(_:)` would have offered to Trash them.
    ///
    /// Listing them by name keeps the defect fixed and restores the previous behaviour for exactly
    /// the entries that were never the user's files. `.TemporaryItems` and `.DocumentRevisions-V100`
    /// are included because they appear on the same volumes for the same reason, though neither was
    /// observed inside a shelf folder.
    static let systemLitter: Set<String> = [
        ".DS_Store", "Icon\r", ".localized", ".Trashes", ".fseventsd", ".Spotlight-V100",
        ".VolumeIcon.icns", ".apdisk", ".metadata_never_index", ".TemporaryItems",
        ".DocumentRevisions-V100",
    ]

    private func isLitter(_ name: String) -> Bool {
        Self.systemLitter.contains(name)
            || name.hasPrefix("._") || name.hasPrefix(Self.incomingPrefix)
    }

    /// The hub's order: newest first, ties broken by name.
    ///
    /// The tie-break is not decoration. Eight files can share one `added` value — an unzip, a
    /// `cp -p`, a restore from a backup — and `Array.sorted` is documented as making no
    /// stability guarantee, so without a total order the tied run falls back to whatever order
    /// `readdir` happened to return and the hub reshuffles between scans. The most severe
    /// defect this project has shipped was an unbroken tie.
    ///
    /// Pure and static so the tie can be tested at all. Measured: `addedToDirectoryDate` has
    /// sub-microsecond resolution on APFS — eight files written back to back came out 0.17 ms
    /// apart, all eight distinct — and `URLResourceValues.addedToDirectoryDate` is get-only, so
    /// a test can neither race into a tie nor plant one. Comparing two values directly is the
    /// only honest way to cover it.
    static func newestFirst(_ lhs: ShelfItem, _ rhs: ShelfItem) -> Bool {
        lhs.added != rhs.added ? lhs.added > rhs.added : lhs.name < rhs.name
    }

    /// Everything on the shelf, newest first.
    ///
    /// A live directory scan, deliberately, with no persisted index. An index would introduce a
    /// second source of truth that can be wrong, which is the only way this feature can lie to the
    /// user.
    ///
    /// **The cost figures here were wrong by 13× and 20×, and they were the sole argument for
    /// having no index.** They said 0.035 ms at 10 items and 1.905 ms at 1000, "0.002% and 11% of
    /// one 60 Hz frame". Re-measured 2026-09-22, `-O`, best of seven:
    ///
    /// ```
    ///                                              10 items    1000 items
    /// items()                                       0.460 ms     38.851 ms
    /// total()                                       0.381 ms     37.994 ms
    ///   contentsOfDirectory alone                   0.041 ms      1.383 ms
    ///   resourceValues per entry                    0.019 ms      1.714 ms
    ///   displayName(atPath:) per entry              0.291 ms     30.255 ms
    /// one 60 Hz frame                              16.667 ms     16.667 ms
    /// ```
    ///
    /// So 1,000 items is **2.3 frames, not 11% of one**, and the old numbers were the cost of
    /// `contentsOfDirectory` alone (1.383 ≈ the quoted 1.905) rather than of this function. The
    /// dominant cost is `displayName(atPath:)` — 78% of the total — which is called once per entry
    /// at line `:522` and is needed because macOS swaps ":" and "/" between the POSIX and display
    /// layers.
    ///
    /// Whether that is acceptable is a live question and not settled here: at a realistic shelf of
    /// 10 to 50 items it is well under a frame, and `total()` has exactly one production consumer
    /// today (`add(_:)`). If a hub refresh ever runs per frame at 1,000 items, the fix is to cache
    /// or drop `displayName`, not to add an index.
    func items() -> [ShelfItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileSizeKey,
                                      .addedToDirectoryDateKey, .creationDateKey,
                                      .isPackageKey, .nameKey]
        // `contentsOfDirectory(at:includingPropertiesForKeys:)`, never
        // `contentsOfDirectory(atPath:)` plus `attributesOfItem` — measured 7.7× slower at
        // 1000 files because the latter stats each file again.
        // `.skipsHiddenFiles` is deliberately **not** passed, and this is the second place in
        // this file where that decision has to be made consistently — `size(of:)` never skipped
        // them either.
        //
        // With the option, any hidden top-level entry was invisible to `items()` and therefore to
        // `total()` and therefore to the cap. Measured on the shipped 1 GiB cap: 20 hidden files
        // of 500 MB gave `total() == (count: 0, bytes: 0)` while the folder held 9.77 GiB, and a
        // further 1 GiB drop was accepted — unbounded, and the bytes were unreachable from inside
        // Chakra, because `items()` never listed them so `remove(_:)` could never be handed one.
        //
        // The route that makes this a defect rather than a policy question is `UF_HIDDEN`: it is
        // an ordinary BSD flag on an ordinary name, and `copyItem` preserves it. Measured, one
        // plain drag-and-drop of a `chflags hidden` file returned `added: ["holiday.mov"]` and
        // then `total() == (count: 0, bytes: 0)` — the app said it had added a file it could
        // neither show nor delete. `sanitize` strips leading dots, so the dot-name door was
        // already shut; this one was not.
        //
        // Nothing is lost by dropping the option: `isLitter` already rejects `.DS_Store`, `._*`
        // and `.chakra-incoming-*` by name. Measured — removing the option reddened not one of
        // 1941 checks, which is exactly how this survived.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys,
            options: []) else { return [] }

        var out: [ShelfItem] = []
        for url in entries {
            let name = url.lastPathComponent
            if isLitter(name) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            // A package is one item even though it is a directory underneath, so it reports
            // `isDirectory: false`: Finder shows it as a single document, and §2.13 accepts it
            // as one item with its interior in the size.
            let treatAsFolder = isDirectory && !isPackage
            // The size branch asks `isDirectory`, **not** `treatAsFolder`, and that difference
            // is the whole cap. Measured 2026-09-22: `.totalFileSizeKey` is nil for *any*
            // directory, package or not. Routing a package down the `totalFileSize` branch
            // therefore reported 0 bytes for it — an `.rtfd` holding 5,000 bytes gave
            // `total() = (4, 850)` against a true `(4, 5850)`. Since `add(_:)` reads
            // `total().bytes` as the existing total, a shelf of `.photoslibrary` bundles
            // reported ~0 and the 1 GB cap could never fire.
            let bytes = isDirectory
                ? size(of: url, limit: nil)
                : Int64(values?.totalFileSize ?? 0)
            out.append(ShelfItem(url: url,
                                 name: fileManager.displayName(atPath: url.path),
                                 bytes: bytes,
                                 // The intake date, not the file's own. Measured 2026-09-22:
                                 // `copyItem` preserves the source's creation date, so a
                                 // source stamped 2001-09-09 lands with
                                 // `creationDate = 2001-09-09` while `addedToDirectoryDate` is
                                 // `now` — true through the temp-name-then-`moveItem` route
                                 // `copyIn` uses as well. Sorting on `creationDate` sank a file
                                 // shelved today to the bottom of the hub. `.creationDateKey`
                                 // remains only as a fallback for a volume that does not record
                                 // an added date.
                                 added: values?.addedToDirectoryDate
                                     ?? values?.creationDate ?? Date.distantPast,
                                 isDirectory: treatAsFolder))
        }
        return out.sorted(by: Self.newestFirst)
    }

    /// What the hub displays.
    ///
    /// The sum saturates rather than using `+`, which **traps** on overflow in Swift. These are
    /// *logical* sizes: measured, this volume accepts a single sparse file of `Int64.max / 256`
    /// bytes, `ftruncate` creates one for free and `du -sh` reports `0B` for it — so 257 of them
    /// sitting in the shelf folder crashed the app on **every hub refresh**, with SIGTRAP inside
    /// this closure. Saturating is correct for every caller, because the answer is only ever
    /// compared against a cap and "at least `Int64.max`" already exceeds any cap.
    func total() -> (count: Int, bytes: Int64) {
        let all = items()
        let bytes = all.reduce(Int64(0)) { running, item in
            let (sum, overflowed) = running.addingReportingOverflow(item.bytes)
            return overflowed ? Int64.max : sum
        }
        return (all.count, bytes)
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
            // Saturating, not `+=`. See `total()` for the measurement: a folder of 257 sparse
            // files crashed `add(_:)` here on a single drag-and-drop, and the `limit` bail is no
            // protection because the addition happens before the comparison — and the refusal
            // path re-walks with `limit: nil` anyway.
            let (sum, overflowed) = running
                .addingReportingOverflow(Int64(file?.totalFileSize ?? 0))
            running = overflowed ? Int64.max : sum
            if let limit, running > limit { return running }
        }
        return running
    }

    // MARK: - Intake

    /// Copies everything in `urls` onto the shelf.
    ///
    /// Atomic in the sense that matters: the cap is checked against the whole drop first,
    /// and if the drop does not fit, nothing is copied. A partial copy is unverifiable by
    /// the user — they cannot tell which files landed without comparing against the source
    /// by hand — and every rule for "what fits" is arbitrary.
    /// Serialises measure-and-copy across every `Shelf` in this process.
    ///
    /// The cap is a read of the filesystem followed by a write to it, and nothing held the two
    /// together. Bytes in flight are invisible to `total()` — `isLitter` excludes the
    /// `.chakra-incoming-` prefix — so two concurrent callers each saw the full headroom.
    /// Measured with two threads and a 900-byte file against a 1,000-byte cap: **1,800 bytes
    /// landed, 25 of 25 trials, with zero refusals** — both callers told the drop succeeded.
    /// Separate `Shelf` instances behave identically, so this is the filesystem read and not
    /// shared mutable state. The overage is not bounded by a constant: at eight concurrent
    /// callers it reached 7,200 bytes on a 1,000-byte cap.
    ///
    /// That breaks `capBytes`' own docstring — "to stop the shelf becoming unbounded". The other
    /// half of that sentence, keeping the hub's total honest, survives, because `total()` reads
    /// real files after they land.
    ///
    /// **The cost, named rather than glossed.** Measured hold time for the whole of `add(_:)`:
    /// 6.0 ms for a 100 MB same-volume clone, 154 ms for a 100 MB cross-volume SHA-256, and
    /// 776 ms for 500 MB cross-volume. A second drop during a large cross-volume copy waits that
    /// long. The common local case is 6 ms and invisible.
    ///
    /// **What it does not fix.** Two Chakra processes. Measured, 10 of 25 two-process trials went
    /// over the cap, and an in-process lock cannot help — only an `O_EXLOCK` coordinated file
    /// would, and spec §5 says "Do not add a lock file", which is the owner's call to reverse.
    /// So the cap is exact per process and advisory across instances.
    ///
    /// The alternative was counting `.chakra-incoming-*` bytes toward the cap. It was built and
    /// measured and is close to useless: it bought 3 of 25 trials, left the worst-case overage
    /// unchanged at every concurrency level, and made an in-flight copy appear as a phantom hub
    /// item — exactly what `incomingPrefix` exists to prevent.
    private static let intakeLock = NSLock()

    /// Whether adding these sources would take the shelf past its cap.
    ///
    /// The *decision* half of the cap check, lifted out of `add(_:)` so there is exactly one
    /// implementation of it. The hub's drag-over forecast asks this before the user lets go, and a
    /// second copy of the arithmetic would eventually predict one answer and refuse with another —
    /// which is worse than not predicting at all.
    ///
    /// `existing` is passed in rather than read here: `add(_:)` has already paid for `total()`, and
    /// that is a live directory scan — 0.46 ms at ten items, 38.9 ms at a thousand.
    ///
    /// **It does not resolve symbolic links, and `add(_:)` does.** So a link to a huge tree can pass
    /// this forecast and then be refused on release. Accepted deliberately: resolving costs I/O on
    /// a path that runs while the user is mid-drag, and the refusal on release is still correct.
    ///
    /// Saturating throughout, for the reasons given on `total()` and below: `capBytes` is an
    /// injectable initialiser parameter, so `Int64.min` minus a non-empty shelf would trap.
    func exceedsCap(_ sources: [URL], existing: Int64) -> Bool {
        let (headroomValue, headroomOverflowed) = capBytes.subtractingReportingOverflow(existing)
        let headroom = headroomOverflowed ? Int64.min : headroomValue
        var dropBytes: Int64 = 0
        for source in sources {
            // The limit is the remaining headroom, so the walk stops as soon as the answer cannot
            // change.
            let (sum, overflowed) = dropBytes
                .addingReportingOverflow(size(of: source, limit: max(headroom - dropBytes, 0)))
            dropBytes = overflowed ? Int64.max : sum
            if dropBytes > headroom { return true }
        }
        return dropBytes > headroom
    }

    func add(_ urls: [URL]) -> AddOutcome {
        // Taken here and nowhere else. `add(pasteboard:)` funnels into this method, so it must
        // not take the lock itself: `NSLock` is not recursive and that would deadlock a paste.
        Self.intakeLock.lock()
        defer { Self.intakeLock.unlock() }

        var outcome = AddOutcome()
        do {
            try ensureExists()
        } catch let error as ShelfError {
            outcome.refusals.append(error)
            return outcome
        } catch {
            // Every `ShelfError` is caught by the clause above, so this generic catch can only
            // see a non-`ShelfError`, which is not an out-of-space condition — it is a folder
            // problem from `ensureExists()`. The honest value is `shelfUnusable` with the code.
            outcome.refusals.append(.shelfUnusable(root, code: (error as NSError).code))
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
        if exceedsCap(sources, existing: existing) {
            // `dropBytes` is a **lower bound**, not the drop's size: the loop above bails out
            // of the tree it is walking the moment the total passes the headroom, and `break`s
            // with the remaining sources never measured at all. That is right for the decision
            // and wrong for the message. Measured before this re-total: a folder of
            // 50 × 1,000 bytes against a 1,000-byte cap reported `dropBytes: 2000`, so §2.12's
            // message — "They total 2 KB … free up 1 KB" — asked the user to free 1 KB for a
            // 50 KB drop.
            //
            // The cost is real and is accepted: the exact total walks every source in full, so
            // a refused hostile million-file tree pays the ~3.6 s the bail exists to avoid. It
            // is paid once, only on the refusal path, and only for a drop the user is about to
            // be shown a dialog about. §2.12's "time-box the walk at ~500 ms and show a
            // measuring state" is the proper fix and is not implemented here; it needs a
            // progress-reporting shape this function does not have.
            var exact: Int64 = 0
            for source in sources {
                let (sum, overflowed) = exact
                    .addingReportingOverflow(size(of: source, limit: nil))
                exact = overflowed ? Int64.max : sum
            }
            outcome.refusals.append(.wouldExceedCap(dropBytes: exact,
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
        // This *is* a `fileExists` pre-check, and it is not a substitute for mapping
        // `copyItem`'s own error. It catches the common case — a dangling link, a source the
        // user deleted before dropping — with a message that names the item the user dropped
        // rather than the target it resolved to. The TOCTOU window it cannot close is exactly
        // what `mapped(_:name:)` handles: a source that disappears between here and the copy
        // comes back from `copyItem` as 260 and is mapped to the same `sourceMissing`.
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

        // Verify before the copy becomes visible. On one volume the copy is a clone and
        // identical by construction, so comparing sizes is conclusive and costs ~0.03 ms.
        // Across volumes real bytes moved, and only a hash proves they arrived — at 41 ms per
        // 100 MB, which is the honest price of a drop from an external or network disk.
        let wanted = size(of: source, limit: nil)
        let got = size(of: temporary, limit: nil)
        var verified = wanted == got
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory ?? false
        if verified, !isDirectory, !treatAsSameVolume(source, root) {
            // A nil digest on either side is *not* verified. "The bytes could not be read" and
            // "the bytes match" are different answers, and only one of them may let a copy
            // become visible under its final name.
            let left = digest(of: source)
            verified = left != nil && left == digest(of: temporary)
        }
        // A cross-volume *directory* is still verified by size alone, and that is a known gap
        // rather than an oversight. Spec §4.1 says "otherwise → SHA-256 both sides" without
        // naming an exception, but SHA-256 is defined over a byte stream and a directory is not
        // one: `digest(of:)` returns nil for it, so hashing both sides would compare nil to nil
        // and pass unconditionally. That is strictly worse than the size check, because it reads
        // like verification while proving nothing. Closing the gap properly needs a recursive
        // tree digest — every entry's relative path plus its contents, in a sorted order — and
        // that is a larger change with its own failure mode: one unreadable child inside an
        // otherwise good folder would turn "added" into `volumeDisconnected`, which is the same
        // lie documented on `AddOutcome.skipped`. Recorded here, not silently fixed.
        guard verified else {
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
            //
            // Compared on `path`, not on the whole `URL`. `URL` equality is trailing-slash
            // sensitive and `deletingLastPathComponent()` always yields a directory URL, so
            // whether this guard held depended on whether the injected `root` happened to be
            // built with `isDirectory: true` — nothing to do with the name it exists to check.
            // Measured: with a root built by `appendingPathComponent` with no hint, all 999
            // candidates were skipped and a perfectly good drop came back as `sourceUnreadable`
            // after 11 ms of futile renames. The shipped `defaultRoot()` passes
            // `isDirectory: true` and was never affected, and the note on `defaultRoot()` already
            // said to compare `path` — this is that note being followed.
            guard destination.deletingLastPathComponent().standardizedFileURL.path
                    == root.standardizedFileURL.path else { continue }
            let failure = Self.renameWithoutClobbering(temporary, to: destination)
            if failure == 0 { return name }
            // `EEXIST` is the ordinary answer: that name is taken, try the next one. Everything
            // else is permanent, and retrying it 998 more times only delays a wrong label —
            // measured on a real file, an `ENAMETOOLONG` burned 998 syscalls and about 40 ms and
            // then surfaced as "too many names". The loop had no way to tell the two apart while
            // the rename reported a bare `Bool`.
            if failure != EEXIST {
                _ = try? fileManager.removeItem(at: temporary)
                throw Self.mappedRename(failure, name: source.lastPathComponent)
            }
        }
        _ = try? fileManager.removeItem(at: temporary)
        throw ShelfError.tooManyNames(source.lastPathComponent)
    }

    /// Maps a POSIX `errno` from the rename onto a `ShelfError`.
    ///
    /// A second, smaller table than `mapped(_:name:)`, and deliberately not folded into it:
    /// `renamex_np` is a raw syscall handing back `errno`, while §6's table is Cocoa error codes.
    /// The two do not share a vocabulary, and mixing the numbering schemes is exactly how the
    /// 4-versus-260 trap already documented on `mapped(_:name:)` gets made.
    /// `internal`, not `private`, so the table can be asserted row by row. Measured: only the
    /// `EACCES` row is reachable through `copyIn`, and sabotaging each of the other five left all
    /// 2,051 checks green — including `ENAMETOOLONG`, which is the errno this whole function exists
    /// for. The same trade the tests already make with `digest(of:)`.
    static func mappedRename(_ code: Int32, name: String) -> ShelfError {
        switch code {
        case ENAMETOOLONG: return .nameTooLong(name)
        case ENOSPC: return .notEnoughSpace(name)
        case EACCES, EPERM, EROFS: return .sourceUnreadable(name)
        case ENOENT: return .sourceMissing(name)
        case EIO: return .volumeDisconnected(name)
        default: return .sourceUnreadable(name)
        }
    }

    /// Renames `source` onto `destination`, failing rather than overwriting.
    ///
    /// `FileManager.moveItem` cannot do this job, and the comment that used to sit in `copyIn`
    /// claiming it could was wrong. It does throw on an existing destination — but only because it
    /// tests for one *first* and then calls `rename(2)`, which is check-then-act with a window in
    /// between. Measured: two callers racing on one name announced two files and left one, in 182
    /// of 200 thread trials and in 11 of 20 trials with two real processes, silently destroying a
    /// file that had just been shelved while `AddOutcome` reported success to both callers. A bare
    /// `rename(2)` clobbers outright — measured, it returned 0 and the destination's bytes were
    /// replaced.
    ///
    /// `renamex_np` with `RENAME_EXCL` is the same syscall with the existence test inside the
    /// kernel, so it is genuinely atomic. The cost, stated plainly: this is not a `FileManager`
    /// call, so a stub can no longer intercept the rename. That is a real test seam given up,
    /// accepted because the seam was guarding behaviour that did not hold.
    ///
    /// Returns 0 on success, otherwise the `errno` — **not** a `Bool`, and that matters. With a
    /// bare `Bool` the caller could not tell "that name is taken" from "this can never work", so
    /// every failure was retried 999 times and then reported as `tooManyNames`. Measured, an
    /// `ENAMETOOLONG` came back as "too many names" after 998 futile syscalls.
    ///
    /// No filesystem was found that refuses the flag: measured, both APFS and an MS-DOS FAT disk
    /// image honour `RENAME_EXCL`, returning `EEXIST` onto an occupied name and succeeding onto a
    /// free one. Both sides of this rename are inside the shelf folder, which lives under
    /// `~/Library/Application Support`.
    private static func renameWithoutClobbering(_ source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { from -> Int32 in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return EINVAL }
                return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
    }

    /// Turns `FileManager`'s error into one Chakra can show.
    ///
    /// The codes are §6's table, and each constant was measured on 2026-09-22 rather than
    /// recalled: 640 `NSFileWriteOutOfSpaceError`, 512 `NSFileWriteUnknownError`,
    /// 513 `NSFileWriteNoPermissionError`, 260 `NSFileReadNoSuchFileError`. Note
    /// `NSFileNoSuchFileError` is **4** and is not what a failed read throws, so matching on it
    /// would never fire; and `NSFileReadNoPermissionError` is **257**, not 513, which is why
    /// both permission codes are listed.
    ///
    /// 516 `EEXIST` is deliberately absent: §6 says it is never surfaced, and in `copyIn` the
    /// occupied-name case never reaches here at all — it arrives as POSIX `EEXIST` from
    /// `renamex_np` and the naming loop consumes it, which is what `mappedRename(_:name:)` is for.
    /// A 516 out of `copyItem` is unreachable, because the destination is a freshly minted UUID.
    private static func mapped(_ error: Error, name: String) -> ShelfError {
        let code = (error as NSError).code
        switch code {
        case NSFileWriteOutOfSpaceError: return .notEnoughSpace(name)
        case NSFileReadNoSuchFileError: return .sourceMissing(name)
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .sourceUnreadable(name)
        case NSFileWriteUnknownError, NSFileReadUnknownError:
            return .volumeDisconnected(name)
        default: return .sourceUnreadable(name)
        }
    }

    // MARK: - Removal, sweeping and backup exclusion

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
            // Fails closed. This used to default an unreadable date to `Date.distantPast`, which
            // reads as "infinitely old" and deletes — fail-open, on the one path in this file that
            // removes a file without the user asking for it. The age check exists precisely
            // because the copy may still be in flight in another instance.
            //
            // Reachability is honestly unknown: four probe shapes — a fresh file, a live symlink,
            // a dangling symlink, and a symlink whose target sits behind a mode-0 directory — all
            // returned a date, so no fixture found drives the nil. Kept as a guard rather than
            // left as a default because the blast radius is a file Chakra is mid-way through
            // writing.
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            guard modified < cutoff else { continue }
            _ = try? fileManager.removeItem(at: url)
        }
    }

    /// Keeps the shelf out of Time Machine.
    ///
    /// Spotlight indexing is deliberately **not** disabled: finding a shelved file by search
    /// is useful. Excluding Spotlight would need a `.metadata_never_index` file in the folder,
    /// which is intentionally omitted per spec §2.16.
    func excludeFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Watching the folder

    /// Called on the main queue whenever the folder's contents change.
    var onChange: (() -> Void)?

    private var watchSource: DispatchSourceFileSystemObject?
    private var coalesceWork: DispatchWorkItem?

    /// Serialises `startWatching()` and `stopWatching()`.
    ///
    /// `guard watchSource == nil else { return }` is not enough on its own. Measured with four
    /// threads calling `startWatching()` at once: 300 of 300 trials had two descriptors open
    /// simultaneously, and the losing source was resumed and then never cancelled — its own event
    /// handler holds it strongly, so ARC cannot reclaim it and the descriptor survived both
    /// `stopWatching()` and deallocation. ThreadSanitizer additionally reported a write race on
    /// `watchSource`, which is an ARC reference: a torn retain count, not merely a lost value.
    ///
    /// `resume()` and `cancel()` are both called *outside* the lock, so a handler delivered on the
    /// main queue can take it without deadlocking against the thread that armed the source.
    private let watchLock = NSLock()

    /// There used to be a `watchDescriptor` field here as well. It was written and never read —
    /// the cancel handler deliberately captures the local `descriptor` instead, for the reason
    /// recorded in `startWatching()` — and `stopWatching()` never reset it, so it was dead state
    /// that read like a live invariant.

    /// Starts watching the folder so the hub stays honest when Finder changes it.
    ///
    /// `open(O_EVTONLY)` plus a `DispatchSource` rather than `FSEventStream`: measured, this
    /// needs **no entitlement and raises no permission prompt**, which `FSEventStream` on an
    /// arbitrary path does not guarantee. That is what makes it compatible with the
    /// never-prompt invariant.
    ///
    /// Adding or removing a child surfaces as `.write` on the parent — measured.
    func startWatching() {
        watchLock.lock()
        guard watchSource == nil else {
            watchLock.unlock()
            return
        }
        let descriptor = open(root.path, O_EVTONLY)
        guard descriptor >= 0 else {
            watchLock.unlock()
            return
        }

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
            //
            // Under the lock, because `coalesceWork` is the second field this handler shares with
            // `stopWatching()` and the first version of the lock covered only `watchSource`.
            // ThreadSanitizer reported three races here — a `DispatchWorkItem?` is an ARC
            // reference, so this is the torn-retain-count class the lock's own docstring names,
            // not merely a lost value. Found with 8 threads × ~33,000 start/stop calls against
            // 9,067 rounds of directory churn.
            //
            // `asyncAfter` is outside the locked region, and `stopWatching()` on the `.delete`
            // path above is called before any lock is taken — `NSLock` is not recursive, so
            // nesting either one would deadlock the main queue.
            let work = DispatchWorkItem { [weak self] in self?.onChange?() }
            self.watchLock.lock()
            self.coalesceWork?.cancel()
            self.coalesceWork = work
            self.watchLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        // Correction 1: capture the local `descriptor` value, not `self.watchDescriptor` through
        // weak self. With `[weak self]`, once `self` is deallocated the capture is nil and the
        // handler closes nothing, leaking the file descriptor. Measured: 40 descriptors leaked
        // across 40 deinits (5 open → 45 open, unchanged after draining the main queue). The
        // local value is what makes the cleanup work.
        source.setCancelHandler { close(descriptor) }
        watchSource = source
        watchLock.unlock()
        // Outside the lock: `stopWatching()` takes it, and the event handler calls that on the
        // `.delete` path.
        source.resume()
    }

    func stopWatching() {
        watchLock.lock()
        coalesceWork?.cancel()
        coalesceWork = nil
        let source = watchSource
        watchSource = nil
        watchLock.unlock()
        source?.cancel()
    }

    deinit {
        stopWatching()
    }

    // MARK: - Verifying a copy that moved real bytes

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
    ///
    /// Returns nil for a *directory* as well as for a missing file, because `FileHandle`
    /// refuses to open one. That nil is deliberate and must not be softened into the SHA-256
    /// of no bytes: a fake digest would make two unrelated directories compare equal. What it
    /// means for the copy path is spelled out at the call site in `copyIn`.
    func digest(of url: URL) -> String? {
        // Regular files only, and this guard is not hygiene. `FileHandle.read(upToCount:)`
        // **blocks forever** on a FIFO — measured, a direct `digest(of:)` on one had to be killed
        // after 15 s. It is unreachable through `add(_:)`, because `copyItem` refuses a FIFO
        // immediately with 512 / `ENOTSUP` in 0.0000 s whether or not a writer is attached, so
        // the digest is never asked for. But this method is `internal` rather than `private`
        // because the tests call it, so any future caller would inherit an unbounded block with
        // no timeout. A nil here is already the documented answer for "the bytes could not be
        // read", and `copyIn` treats nil as *not verified*, which is the safe direction.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
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

    /// Replaces the same-volume decision `copyIn` makes. nil means "ask `isSameVolume`", which
    /// is what every shipped caller leaves it as.
    ///
    /// It exists because the cross-volume branch is otherwise untestable, and an untested branch
    /// in the only code that decides whether a copy is trustworthy is not acceptable.
    /// `isSameVolume` reads `.volumeIdentifierKey` off the URL itself rather than through the
    /// injected `fileManager`, so no stub can reach that branch — and a second volume cannot be
    /// assumed to exist. Measured 2026-09-22 on this machine: `/`, `/System/Library`, `/Users`,
    /// `~`, `/tmp`, `/private/var/folders` and `/Volumes` all report the *same* 8-byte volume
    /// identifier, because firmlinks make the read-only System volume and the Data volume one
    /// volume to this API. So not even "copy from `/System/Library`" produces a cross-volume copy
    /// here. An attached disk image does — measured, a 20 MB APFS image reports a different
    /// identifier — but creating one costs 1.2 s, needs `hdiutil`, and mounts something that
    /// outlives a crashed test run. See `probes/second-volume.sh` for that measurement.
    ///
    /// A stored closure rather than an overridable method: `Shelf` is `final`. A stored closure
    /// must also never capture `self` — that retain cycle would stop `deinit` running and so
    /// leak the watch descriptor that `shelf/watch-no-descriptor-leak` guards, which is why the
    /// default is nil and not a closure wrapping `isSameVolume`.
    var sameVolumeOverride: ((URL, URL) -> Bool)?

    /// The question `copyIn` actually asks, honouring `sameVolumeOverride`.
    private func treatAsSameVolume(_ a: URL, _ b: URL) -> Bool {
        sameVolumeOverride?(a, b) ?? isSameVolume(a, b)
    }

    // MARK: - Pasteboard intake

    /// Saves the clipboard's image onto the shelf.
    ///
    /// Writes the bytes through a temporary file and then goes through `add`, so a paste gets
    /// exactly the same verification, cap check and collision naming as a drop. The
    /// alternative — writing straight into the shelf — would be a second, unverified code
    /// path doing the same job.
    ///
    /// The staging file's *name* is the pasted name rather than a UUID, because `copyIn` derives
    /// the shelf name from `lastPathComponent`. The name therefore cannot be made unique, so the
    /// *directory* holding it is: a fresh `.chakra-incoming-<UUID>` folder per paste.
    ///
    /// That is not tidiness. `pastedName` has one-second resolution, so two pastes in the same
    /// second previously staged to the same path, and `Data.write(to:)` truncates — the second
    /// write replaced the first's bytes before the first `copyIn` had read them. Measured across
    /// 30 concurrent rounds: 60 pastes announced, far fewer files on disk, **zero refusals**, and
    /// 13 rounds where two shelf files held the same image. That is exactly the miscount
    /// `AddOutcome`'s own docstring exists to prevent.
    ///
    /// The defence recorded here previously — "`add(pasteboard:)` is a main-thread response to a
    /// user action, so the race is not reachable" — was prose, not a guarantee. Nothing enforced
    /// the main thread: no `assert`, no `@MainActor`, no `dispatchPrecondition`. And the shipped
    /// staging path was fully predictable, so a symlink planted at it sent the write outside the
    /// temporary directory entirely, destroyed the target, and left those bytes behind because
    /// `removeItem` unlinks the link rather than the file. The UUID directory closes both.
    func add(pasteboard: NSPasteboard) -> AddOutcome {
        var outcome = AddOutcome()
        guard let picked = ShelfIntake.imageData(from: pasteboard) else {
            outcome.refusals.append(.nothingUsableOnClipboard)
            return outcome
        }
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(Self.incomingPrefix + UUID().uuidString, isDirectory: true)
        let staging = stagingDirectory
            .appendingPathComponent(ShelfIntake.pastedName(at: Date(),
                                                           extension: picked.extension))
        // Registered *before* the write, not after it. `Data.write(to:)` is not atomic by
        // default, so a write that fails on a full disk can leave a partial file behind — and
        // a `defer` placed after the `do`/`catch` never runs on that path, because the `catch`
        // returns first. This placement is the only one that cleans up on every exit: the
        // refusal, the throw, and the success after `add` has copied the file in. It removes the
        // whole staging directory, so nothing survives even if the write left a partial file.
        defer { _ = try? fileManager.removeItem(at: stagingDirectory) }
        do {
            try fileManager.createDirectory(at: stagingDirectory,
                                            withIntermediateDirectories: true)
            try picked.data.write(to: staging)
        } catch {
            // Mapped, not labelled. This reported `.notEnoughSpace` for *every* error code, and
            // `notEnoughSpace` is documented on its own case as 640 / `ENOSPC` alone — so five
            // measured non-ENOSPC failures all told the user to free disk space on a volume with
            // 790 GiB free: a read-only staging directory (513), a staging path under a regular
            // file (512), a 300-character component (514), an absent directory (4), and a
            // directory sitting at the staging path (512). `mapped(_:name:)` already held the
            // right table and simply was not called.
            outcome.refusals.append(Self.mapped(error, name: staging.lastPathComponent))
            return outcome
        }
        return add([staging])
    }
}

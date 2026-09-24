import Foundation

/// The rules for turning an arbitrary name into one the shelf can safely hold.
///
/// Pure and filesystem-free, so every rule can be tested directly. The interesting cases
/// are all measured rather than assumed, and each one is noted where it applies.
enum ShelfName {
    /// The filesystem's limit, in UTF-16 code units **of the canonically decomposed form**.
    ///
    /// **Not bytes, and not the UTF-16 count of the string as written.** Both of those were
    /// recorded here previously and both are wrong; the correction was measured on 2026-09-22 and
    /// the old claim — "255 × 'é' is 510 UTF-8 bytes and succeeds" — is false through every API
    /// Chakra uses:
    ///
    /// ```
    /// name                     nfcU16  nfdU16  Foundation   open(2) with NFC bytes
    /// 255 × "a"                   255     255  OK           OK
    /// 256 × "a"                   256     256  FAIL 514     FAIL ENAMETOOLONG
    /// 255 × "é" (precomposed)     255     510  FAIL 514     OK
    /// 128 × "é" + ".txt"          132     260  FAIL 514     OK
    /// 255 × "中"                  255     255  OK           OK
    /// 127 × "😀"                  254     254  OK           OK
    /// ```
    ///
    /// The kernel counts UTF-16 units of whatever spelling it is handed, and Foundation hands it a
    /// decomposed spelling — so a `URL`, a `Data.write(to:)` or a `FileManager.moveItem` is bound
    /// by the decomposed count even when the name was created outside Foundation with precomposed
    /// bytes. Precomposed names are exactly what `rsync`, `unzip` and SMB/NFS shares produce, so
    /// this is a shape the shelf really meets.
    ///
    /// **It is not plain NFD**, and an earlier version of this comment said it was. macOS excludes
    /// three scalar ranges from that decomposition; `fileSystemLength` is the predicate that gets
    /// it right, and the row that disproves the simpler rule is quoted there.
    ///
    /// Measuring the wrong count is not cosmetic: a perfectly readable 132-unit file passed
    /// `sanitize` untouched, every one of `copyIn`'s 999 rename attempts failed with 514, and the
    /// drop was refused as `sourceUnreadable` — "Chakra can't read it" — in 108 ms.
    static let maxUTF16Length = 255

    /// Scalar ranges macOS leaves **composed** when it normalises a filename.
    ///
    /// Apple TN1150 excludes these three ranges from the canonical decomposition HFS+ and APFS
    /// apply. `decomposedStringWithCanonicalMapping` knows nothing about the exclusions and
    /// decomposes them anyway, so a plain NFD count **under-counts** any name using them.
    ///
    /// Only the third range bites in practice: U+2000–U+2FFF and U+F900–U+FAFF have no canonical
    /// decomposition to begin with, so NFD leaves them alone regardless. U+2F800–U+2FA1F (the CJK
    /// compatibility ideographs) *do* decompose to unified ideographs — measured, one U+2F804 is
    /// two UTF-16 units raw and one decomposed — which is exactly the 2× under-count. All three
    /// are listed because the rule, not the shortcut, is what has to survive a future reader.
    private static let unnormalisedRanges: [ClosedRange<UInt32>] = [
        0x2000...0x2FFF, 0xF900...0xFAFF, 0x2F800...0x2FA1F,
    ]

    /// The length the filesystem will actually measure, for a name Foundation is about to write.
    ///
    /// Anything deciding whether a name fits must ask this rather than `utf16.count`, and it is
    /// not simply the NFD count either. Measured 2026-09-22, nine shapes, this function's answer
    /// against the real write every time:
    ///
    /// ```
    /// name                      raw   nfd   this   write
    /// 255 × "a"                 255   255    255   OK
    /// 255 × "é" precomposed     255   510    510   FAIL 514
    /// 127 × "é"                 127   254    254   OK
    /// 255 × U+2010              255   255    255   OK
    /// 255 × U+F900              255   255    255   OK
    /// 127 × U+2F804             254   127    254   OK
    /// 128 × U+2F804             256   128    256   FAIL 514
    /// 127 × U+2F804 + " 2"      256   129    256   FAIL 514      <-- the one NFD got wrong
    /// ```
    ///
    /// That last row is why this exists. Under a plain NFD count the collision candidate measured
    /// 129 units, passed the 251 budget untouched, and then every one of `copyIn`'s 999 renames
    /// failed with `ENAMETOOLONG` — 998 futile syscalls, ~40 ms, and a refusal reading "too many
    /// names" for a file that is perfectly readable and could be shelved once but never twice.
    /// An independent fuzz of 40,000 names put this predicate at **0 wrong answers in both
    /// directions**, against 6,134 false "it fits" for the NFD count and 6,593 for `utf16.count`.
    static func fileSystemLength(_ text: String) -> Int {
        // Fast path. With no scalar from an excluded range the whole-string decomposition is
        // already right, and it costs one allocation rather than one per scalar — which matters
        // because `clipped` calls this once per dropped `Character`.
        let hasExcluded = text.unicodeScalars.contains { scalar in
            unnormalisedRanges.contains { $0.contains(scalar.value) }
        }
        guard hasExcluded else { return text.decomposedStringWithCanonicalMapping.utf16.count }

        var length = 0
        for scalar in text.unicodeScalars {
            if unnormalisedRanges.contains(where: { $0.contains(scalar.value) }) {
                length += UTF16.width(scalar)
            } else {
                length += String(scalar).decomposedStringWithCanonicalMapping.utf16.count
            }
        }
        return length
    }

    /// Room kept free so the collision counter always fits: " 999" is four units.
    static let reservedForCounter = 4

    /// The most collision attempts before giving up. An unbounded loop on a hostile directory is
    /// a hang, not a retry.
    ///
    /// There is no UUID fallback, despite what this comment said for several rounds. The only
    /// `UUID` in the intake path is `copyIn`'s hidden temporary name. Exhaustion is reachable —
    /// measured, a shelf pre-loaded with `dup.txt` … `dup 999.txt` refuses the next `dup.txt` in
    /// 64 ms, clobbering nothing — and it surfaces as `ShelfError.tooManyNames`.
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
            //
            // `CharacterSet.controlCharacters` is Cc **∪ Cf**, so this also replaces *format*
            // characters — measured: ZWJ (U+200D), ZWNJ, soft hyphen, LRM/RLM and the BOM all
            // become "_", so `sanitize("👨‍👩‍👧‍👦 photo.jpg")` yields `👨_👩_👧_👦 photo.jpg`.
            // U+FE0F and U+00A0 are *not* in the set and survive. Whether to keep Cf is a
            // product decision and is recorded as one, not quietly changed here.
            if CharacterSet.controlCharacters.contains(scalar) { return "_" }
            return String(scalar)
        }.joined()

        // A leading dot hides the item from Finder and from any listing that uses
        // `.skipsHiddenFiles`. A renamed item is better than an invisible one.
        //
        // Per *unicode scalar*, not per `Character`. `hasPrefix(".")` compares grapheme clusters
        // canonically, so a name beginning with "." followed by any Extend or SpacingMark scalar
        // has a first cluster that is not "." — the loop never ran and the literal `0x2E`
        // survived as byte 1. Measured: 2,281 scalars in U+0000…U+2FFFF open that hole, including
        // U+0301 (combining acute), U+FE0F (variation selector), U+093E (Devanagari sign AA) and
        // the emoji skin-tone modifiers.
        //
        // The consequence was worse than an odd name. A file named "." + U+0301 + "tax-2026.pdf"
        // was reported in `AddOutcome.added`, was `isHidden = true` on disk, and so never came
        // back from `items()` — which passes `.skipsHiddenFiles` — leaving it unselectable,
        // unremovable, and counted as 0 bytes against the 1 GB cap.
        while name.unicodeScalars.first == "." { name.unicodeScalars.removeFirst() }

        // Trailing dots and whitespace are legal but display confusingly. Trim here for
        // efficiency — short names need no truncation and are done — but also after
        // truncation, because `clipped` cuts on a `Character` boundary that may itself be
        // whitespace. Without a post-truncation trim, 14% of realistic long names end in a
        // space, and `candidate(_, attempt: 2)` yields a double space.
        name = trimTrailing(name)

        guard !name.isEmpty else { return placeholder }
        // The placeholder guard has to run again here, not only before `truncate`. Truncation
        // can leave a name that is entirely trailing whitespace — 251 spaces followed by one
        // letter clips to 251 spaces, which `trimTrailing` then empties — and "" is never a
        // valid path component.
        let trimmed = trimTrailing(truncate(name))
        return trimmed.isEmpty ? placeholder : trimmed
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
    /// Every length here is a `fileSystemLength`, never `utf16.count`. See `maxUTF16Length`: a
    /// 132-unit precomposed name is 260 decomposed units and Foundation refuses to write it, so
    /// measuring the written form is what makes the budget mean anything.
    private static func truncate(_ name: String) -> String {
        let budget = maxUTF16Length - reservedForCounter
        guard fileSystemLength(name) > budget else { return name }

        let base = (name as NSString).deletingPathExtension
        var extensionPart = (name as NSString).pathExtension

        // An extension can itself be longer than the budget, in which case there is nothing
        // to preserve and it is truncated like anything else.
        if fileSystemLength(extensionPart) + 1 >= budget {
            extensionPart = String(clipped(extensionPart, toLength: budget))
            return extensionPart.isEmpty ? placeholder : extensionPart
        }

        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
        let baseBudget = budget - fileSystemLength(suffix)
        let clippedBase = clipped(base, toLength: baseBudget)
        guard !clippedBase.isEmpty else { return placeholder }
        return clippedBase + suffix
    }

    /// Drops whole `Character`s off the end until the name fits what the filesystem will measure.
    ///
    /// Per `Character`, not per UTF-16 unit: an emoji is two units, and cutting between
    /// them leaves an unpaired surrogate that renders as a replacement glyph.
    ///
    /// `fileSystemLength` is recomputed each turn rather than decomposing once and counting down,
    /// because one `Character` can contribute a different number of decomposed units than it does
    /// composed ones. That is quadratic in principle; in practice the loop runs at most a few
    /// hundred times on a name of at most 255 units, once per dropped file.
    private static func clipped(_ text: String, toLength limit: Int) -> String {
        var result = text

        // A coarse pass first, and the numbers are why. Each `removeLast()` reallocates and
        // re-breaks graphemes across the whole string, so the fine loop below is **super-quadratic**
        // — measured on Hangul LVT syllables: 1.283 ms at 255 characters, 20.917 ms at 1,000,
        // 465.501 ms at 4,000, 17.5 s at 16,000 and **966 s — 16.1 minutes — at 64,000**. A 4×
        // input costs 55×, not the 16× quadratic would predict.
        //
        // That curve is unreachable through `copyIn`, whose input is a `lastPathComponent` the
        // filesystem caps at 255 units. But `sanitize` is `internal`, so a future caller would
        // inherit a 16-minute single-threaded stall with nothing guarding it — the same exposure
        // `digest(of:)` has, recorded there too.
        //
        // The threshold is deliberately far above anything reachable so this cannot change a
        // realistic answer: every scalar contributes at least one unit to `fileSystemLength`, so
        // the optimum always lies within the first `limit` scalars, and `limit * 4` leaves ample
        // slack for a grapheme straddling the cut. At `limit` 251 that is 1,004 scalars, against a
        // real maximum of 255.
        if result.unicodeScalars.count > limit * 4 {
            result = String(result.unicodeScalars.prefix(limit * 4))
        }

        while fileSystemLength(result) > limit, !result.isEmpty {
            result.removeLast()
        }
        return result
    }

    /// Strips trailing whitespace and dots.
    ///
    /// Uses `CharacterSet.whitespaces`, not just `U+0020`, so that `U+00A0` (no-break space)
    /// and other whitespace characters are caught.
    private static func trimTrailing(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last,
              last == "." || CharacterSet.whitespaces.contains(last) {
            result.removeLast()
        }
        return result
    }
}

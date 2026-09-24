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
        expectEqual(ShelfName.sanitize("../escape.txt"), "_escape.txt",
                    "a traversal attempt cannot leave the shelf, and the leading dots go too")

        // Control characters are legal at the POSIX layer and produce unreadable names.
        expectEqual(ShelfName.sanitize("two\nlines.txt"), "two_lines.txt",
                    "a newline is replaced")
        expectEqual(ShelfName.sanitize("Icon\r"), "Icon_",
                    "the Finder Icon file's carriage return is replaced")

        // `CharacterSet.controlCharacters` is Cc **∪ Cf**, so format characters are replaced too.
        // The source records that as a product decision with a worked example, and it had no check
        // at all: measured, narrowing the set to `CharacterSet.newlines` — or to Cc only, dropping
        // Cf — left every check in this binary green.
        expectEqual(ShelfName.sanitize("a\u{200D}b"), "a_b", "a zero-width joiner is replaced")
        expectEqual(ShelfName.sanitize("a\u{00AD}b"), "a_b", "and a soft hyphen")
        expectEqual(ShelfName.sanitize("a\u{FEFF}b"), "a_b", "and a byte-order mark")
        // The other side of the same line, because "replace everything unusual" would also pass the
        // three above. These two are ordinary characters in real filenames and must survive.
        expectEqual(ShelfName.sanitize("a\u{FE0F}b"), "a\u{FE0F}b",
                    "a variation selector is not a control character and survives")
        expectEqual(ShelfName.sanitize("a\u{00A0}b"), "a\u{00A0}b",
                    "and neither is a no-break space")

        // A dot followed by a combining mark. `hasPrefix(".")` compares grapheme clusters
        // canonically, so the first cluster of this name is not "." and the literal `0x2E`
        // survived — measured, 2,281 scalars in U+0000…U+2FFFF open that hole, including U+0301,
        // U+FE0F, U+093E and the emoji skin-tone modifiers. The dropped file then landed hidden:
        // reported in `AddOutcome.added`, never returned by `items()`, unselectable, unremovable,
        // and counted as 0 bytes against the cap.
        //
        // Asserted on the first unicode *scalar*, because `hasPrefix(".")` is false here either
        // way and so cannot tell the two behaviours apart.
        let combining = ".\u{0301}tax-2026.pdf"
        let sanitizedCombining = ShelfName.sanitize(combining)
        expect(sanitizedCombining.unicodeScalars.first != ".",
               "a dot before a combining mark is stripped too, got scalars "
               + "\(sanitizedCombining.unicodeScalars.prefix(3).map { "U+\(String($0.value, radix: 16))" })")

        expectEqual(ShelfName.sanitize("trailing.  "), "trailing",
                    "trailing whitespace and dots are trimmed")
        expectEqual(ShelfName.sanitize(""), "Untitled", "an empty name gets a placeholder")
        expectEqual(ShelfName.sanitize("."), "Untitled",
                    "a name that sanitises away gets a placeholder")

        // A long name that truncates on a space. Without post-truncation trim, this would
        // end in a space, and `candidate(_, attempt: 2)` would yield a double space.
        let longWithSpace = String(repeating: "a", count: 250) + " " + String(repeating: "b", count: 100)
        let trimmedLong = ShelfName.sanitize(longWithSpace)
        expect(trimmedLong.unicodeScalars.last.map { !CharacterSet.whitespaces.contains($0) } ?? false,
               "a name truncated at whitespace does not end in any whitespace")

        // Truncation can consume everything except trailing whitespace, and "" is never a
        // valid path component. Reachable only with a deliberately structured name, but
        // reachable: a crafted archive entry is enough.
        expectEqual(ShelfName.sanitize(String(repeating: " ", count: 251) + "x"), "Untitled",
                    "a name that truncates away to whitespace gets the placeholder")
        expectEqual(ShelfName.sanitize(String(repeating: "\u{00A0}", count: 300) + "x"), "Untitled",
                    "the same holds for non-breaking whitespace")
    }

    suite("shelf-name/length") {
        // The limit is 255 UTF-16 code units **of the canonically decomposed form**, which is the
        // spelling Foundation hands the kernel. This suite asserted the wrong thing for several
        // rounds: it claimed "255 × 'é' is 510 UTF-8 bytes and succeeds on APFS", which is false
        // through every API Chakra uses. Measured 2026-09-22:
        //
        //   name                   nfcU16  nfdU16  Foundation  open(2) with NFC bytes
        //   255 × "a"                 255     255  OK          OK
        //   256 × "a"                 256     256  FAIL 514    FAIL ENAMETOOLONG
        //   255 × "é" precomposed     255     510  FAIL 514    OK
        //   128 × "é" + ".txt"        132     260  FAIL 514    OK
        //
        // So every length here is a `fileSystemLength`, and the suite ends by actually writing
        // the names — the check whose absence let the false measurement survive.
        let room = ShelfName.maxUTF16Length - ShelfName.reservedForCounter

        let longAscii = String(repeating: "a", count: 400) + ".txt"
        let trimmedAscii = ShelfName.sanitize(longAscii)
        expect(ShelfName.fileSystemLength(trimmedAscii) <= room,
               "a long ASCII name fits the budget, got "
               + "\(ShelfName.fileSystemLength(trimmedAscii))")
        expect(trimmedAscii.hasSuffix(".txt"), "the extension survives truncation")

        // A precomposed accented name: one UTF-16 unit per character as written, two once
        // decomposed. Measuring the written form let a 132-unit name through untouched, and
        // Foundation then refused to write it — which `copyIn` reported as "Chakra can't read it"
        // after 999 futile renames.
        let accented = String(repeating: "é", count: 300) + ".txt"
        let trimmedAccented = ShelfName.sanitize(accented)
        expect(ShelfName.fileSystemLength(trimmedAccented) <= room,
               "an accented name is measured decomposed, got "
               + "\(ShelfName.fileSystemLength(trimmedAccented))")
        expect(trimmedAccented.hasSuffix(".txt"), "the extension survives here too")

        // A lower bound as well as an upper one: clipping far more than necessary would satisfy
        // every upper bound above, and a check that cannot fail is not a check.
        expect(ShelfName.fileSystemLength(trimmedAccented) > room - 10,
               "and is not truncated far more than necessary, got "
               + "\(ShelfName.fileSystemLength(trimmedAccented))")
        // Pinned exactly, in both counts, so the decomposition is asserted rather than assumed:
        // 123 × "é" is 246 decomposed units, plus ".txt" is 250 — and only 127 units as written.
        // Measuring `utf16.count` here would read 127 and wrongly conclude the name was gutted.
        expectEqual(ShelfName.fileSystemLength(trimmedAccented), 250,
                    "the accented name fills the decomposed budget")
        expectEqual(trimmedAccented.utf16.count, 127,
                    "which is about half as many characters, because each one decomposes to two")

        // An emoji is two UTF-16 units and must not be split down the middle, which would
        // leave an unpaired surrogate.
        let emoji = String(repeating: "😀", count: 200) + ".txt"
        let trimmedEmoji = ShelfName.sanitize(emoji)
        expect(ShelfName.fileSystemLength(trimmedEmoji) <= room,
               "an emoji name fits, got \(ShelfName.fileSystemLength(trimmedEmoji))")
        expect(trimmedEmoji.unicodeScalars.allSatisfy { $0.value != 0xFFFD },
               "no grapheme was split into a replacement character")

        // Discriminating, unlike the U+FFFD check above: clipping per `Character` lands on an
        // even number of UTF-16 units, so 250. Clipping per UTF-16 unit would give 251 and
        // split the final emoji. This is the assertion that can actually fail. An emoji does not
        // decompose, so this number is the same read either way.
        expectEqual(trimmedEmoji.utf16.count, 250,
                    "the emoji name clips on a Character boundary, not a UTF-16 unit")

        // An extension so long there is no room for a base name at all.
        let absurdExtension = "a." + String(repeating: "x", count: 400)
        let trimmedAbsurd = ShelfName.sanitize(absurdExtension)
        expect(ShelfName.fileSystemLength(trimmedAbsurd) <= room,
               "an absurd extension is itself truncated rather than overflowing, got "
               + "\(ShelfName.fileSystemLength(trimmedAbsurd))")
        // The upper bound alone did not pin this branch. Measured: three separate value sabotages
        // of it — returning the placeholder instead of the clipped extension, moving the
        // threshold, and clipping 40 units short — all left this suite green. The branch discards
        // the base deliberately, so what is asserted is that what comes back is the clipped
        // extension, at the full budget.
        expectEqual(ShelfName.fileSystemLength(trimmedAbsurd), room,
                    "and is clipped to exactly the budget, not short and not to a placeholder")
        expectEqual(trimmedAbsurd, String(repeating: "x", count: room),
                    "and what survives is the extension itself")

        // The end-to-end budget: a fully truncated name plus the largest collision counter must
        // land on exactly 255 decomposed units — measured, 255 writes and 256 fails.
        let atLimit = ShelfName.candidate(trimmedAscii, attempt: ShelfName.maxAttempts)
        expect(ShelfName.fileSystemLength(atLimit) <= ShelfName.maxUTF16Length,
               "and never exceeds it, got \(ShelfName.fileSystemLength(atLimit))")
        expectEqual(ShelfName.fileSystemLength(atLimit), ShelfName.maxUTF16Length,
                    "the longest name plus the largest counter is exactly at the limit")

        // The predicate itself, on the scalar that disproves the simpler rules. One U+2F804 is two
        // UTF-16 units as written and one decomposed, and the filesystem counts the written pair —
        // so a plain NFD count halves it. These three assertions are what stop the simpler rule
        // being reintroduced by someone tidying up.
        let compatibility = String(repeating: "\u{2F804}", count: 127)
        expectEqual(compatibility.utf16.count, 254, "127 compatibility ideographs are 254 units")
        expectEqual(compatibility.decomposedStringWithCanonicalMapping.utf16.count, 127,
                    "a plain NFD count would call them 127, which the filesystem does not")
        expectEqual(ShelfName.fileSystemLength(compatibility), 254,
                    "and fileSystemLength counts what the filesystem counts")

        // The only checks in this suite that touch the filesystem, and the ones whose absence let
        // a false measurement stand for several rounds. Every arithmetic bound above is a proxy;
        // this is the thing that actually has to be true. Hangul is included because U+AC01
        // decomposes to three jamo, so it stresses the ratio harder than an accent does.
        let box = scratchDirectory("name-writes")
        // The last three shapes come from the ranges macOS leaves composed (TN1150). Before they
        // were here, a plain NFD count passed `127 × U+2F804 + " 2"` as 129 units and the real
        // write failed 514 — so the file could be shelved once and never twice, burning 998 futile
        // renames and reporting "too many names". Measured, this predicate answers all nine
        // shapes correctly; the NFD count got 6,134 of 40,000 fuzzed names wrong.
        let shapes: [(String, String)] = [
            ("ascii", longAscii),
            ("precomposed accented", accented),
            ("emoji", emoji),
            ("absurd extension", absurdExtension),
            ("cjk", String(repeating: "中", count: 300) + ".txt"),
            ("hangul", String(repeating: "\u{AC01}", count: 300) + ".txt"),
            ("cjk compatibility ideograph", String(repeating: "\u{2F804}", count: 300)),
            ("in-range hyphen", String(repeating: "\u{2010}", count: 300)),
            ("in-range compatibility", String(repeating: "\u{F900}", count: 300)),
        ]
        for (label, raw) in shapes {
            let name = ShelfName.candidate(ShelfName.sanitize(raw),
                                           attempt: ShelfName.maxAttempts)
            do {
                // The success arm asserts the file is really there, rather than `expect(true, …)`.
                // A literal `true` cannot fail and contributed nine of the suite's checks while
                // asserting nothing — the real check was only ever the `catch`.
                let url = box.appendingPathComponent(name)
                try Data([0x41]).write(to: url)
                expect(FileManager.default.fileExists(atPath: url.path),
                       "the longest \(label) name Chakra would write is really on disk")
            } catch {
                expect(false, "the longest \(label) name Chakra would write failed with "
                       + "\((error as NSError).code), at \(ShelfName.fileSystemLength(name)) "
                       + "decomposed units")
            }
        }

        // The constant pinned from **below** as well as above. Measured: `255 → 254` left every
        // check in this binary green, because every reference derives from the constant itself —
        // `room`, the `<= maxUTF16Length` bound, the `== maxUTF16Length` equality, and the nine
        // writes above all move with it. A silent downward drift was invisible. These two writes
        // are independent of the constant's use elsewhere: the first must succeed and the second
        // must fail, and only the true limit satisfies both.
        let atLimitName = String(repeating: "b", count: ShelfName.maxUTF16Length)
        do {
            let url = box.appendingPathComponent(atLimitName)
            try Data([0x41]).write(to: url)
            expect(FileManager.default.fileExists(atPath: url.path),
                   "a name of exactly maxUTF16Length units really writes")
        } catch {
            expect(false, "a name of exactly maxUTF16Length units must write, got "
                   + "\((error as NSError).code)")
        }
        let overLimitName = String(repeating: "b", count: ShelfName.maxUTF16Length + 1)
        do {
            try Data([0x41]).write(to: box.appendingPathComponent(overLimitName))
            expect(false, "one unit past maxUTF16Length must be refused, but it wrote")
        } catch {
            expectEqual((error as NSError).code, 514,
                        "and one unit past it is refused with ENAMETOOLONG")
        }
    }

    suite("shelf-name/an-absurd-name-is-bounded-work") {
        // `clipped` drops one `Character` at a time, and each `removeLast()` reallocates and
        // re-breaks graphemes across the whole string, so the fine loop is **super-quadratic**.
        // Measured on Hangul LVT syllables: 1.283 ms at 255 characters, 20.917 ms at 1,000,
        // 465.501 ms at 4,000, 17.5 s at 16,000 and 966 s — **16.1 minutes** — at 64,000. A 4×
        // input costs 55×, not the 16× quadratic would predict. A coarse prefix pass now bounds the
        // fine loop's input.
        //
        // Unreachable through `copyIn`, whose input is a `lastPathComponent` the filesystem caps at
        // 255 units. This suite exists because `ShelfName.sanitize` is `internal`, so a future
        // caller would otherwise inherit a 16-minute single-threaded stall with nothing guarding it.
        let room = ShelfName.maxUTF16Length - ShelfName.reservedForCounter
        let absurd = String(repeating: "\u{D55C}", count: 64_000)

        let started = Date()
        let trimmed = ShelfName.sanitize(absurd)
        let elapsed = Date().timeIntervalSince(started)

        // Correctness first. A coarse pass that cut too deep would be a worse bug than the stall.
        expect(ShelfName.fileSystemLength(trimmed) <= room,
               "an absurd name still fits the budget, got \(ShelfName.fileSystemLength(trimmed))")
        expect(trimmed.allSatisfy { $0 == "\u{D55C}" },
               "and is still made of the input's own characters")
        // Each Hangul LVT syllable is three decomposed units, so 83 of them is 249 units and 84 is
        // 252 — 83 is the most that fits 251. Pinned exactly, which is what catches a coarse pass
        // that trimmed one character too many.
        expectEqual(trimmed.count, room / 3,
                    "clipped to exactly as many syllables as fit, got \(trimmed.count)")

        // Then the bound. Deliberately generous — 2 s against a measured 966 s regression — because
        // a tight timing assertion on a shared machine is a flaky check, and what this guards is
        // three orders of magnitude away from the threshold.
        expect(elapsed < 2.0,
               "and the work is bounded rather than super-quadratic, took \(elapsed) s")
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

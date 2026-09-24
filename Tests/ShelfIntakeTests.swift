import AppKit

func runShelfIntakeTests() {
    /// A private pasteboard, so the tests never disturb the user's clipboard.
    ///
    /// The UUID and the registration are both load-bearing, and this helper had neither.
    /// `NSPasteboard.Name` is machine-global: measured with a fixed name and two test binaries at
    /// once, `setData` returned false 627 times in 4,000 and reads came back nil 1,116 times,
    /// against 0 and 0 solo. And an unreleased named board outlives the process, so every run leaked
    /// six of them.
    func board(_ label: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(
            "local.chakra.test.\(label).\(UUID().uuidString)"))
        pb.clearContents()
        registerScratchBoard(pb)
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

    /// A real JPEG, not a ten-byte header.
    ///
    /// The header-only fixture this suite used made `prefers-jpeg-over-tiff` unable to test its
    /// own name: measured, `data(forType: .tiff)` on that board was 0 bytes and
    /// `NSBitmapImageRep(data:)` refused it, so there was no decodable TIFF to prefer *over* — and
    /// moving the JPEG branch after the TIFF branch left all checks green. A real JPEG makes
    /// AppKit synthesise a decodable TIFF (3,584 bytes for this fixture), which is what makes the
    /// ordering assertion mean something. No alpha, because JPEG has none.
    func jpegData(_ side: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: side * 3, bitsPerPixel: 24)!
        return rep.representation(using: .jpeg, properties: [:]) ?? Data()
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
        // Verbatim, byte for byte. AppKit synthesises TIFF on demand, so a TIFF-first lookup
        // returns invented bytes rather than the image that was copied. No ratio is quoted
        // here on purpose: TIFF is uncompressed raw pixels, so the inflation is a property of
        // how compressible the source image is, not of AppKit. Measured on three images it
        // ranged from 12.5× to 192×, and on this suite's 8×8 fixture it is 152 → 3,664 bytes.
        expectEqual(picked.data.count, png.count, "the PNG bytes are taken verbatim")
        expectEqual(picked.data, png, "and are byte-identical")
    }

    suite("shelf-intake/prefers-jpeg-over-tiff") {
        // A JPEG must not be re-encoded to PNG: measured, a real photo grew 6.7× doing that.
        let jpeg = jpegData(16)
        expect(jpeg.count > 100, "the fixture is a real JPEG, not a header, got \(jpeg.count)")
        let pb = board("jpeg")
        // The UTI is written out in full here rather than reused from `ShelfIntake.jpegType`.
        // Measured: with the constant on both sides, changing it to `"public.jpegZ"` left all 2051
        // checks green — so the docstring's whole point, that `public.jpeg` has no
        // `NSPasteboard.PasteboardType` constant and has to be constructed correctly, was untested.
        // A wrong UTI would send every real JPEG down the TIFF re-encode path unnoticed.
        pb.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        expectEqual(ShelfIntake.jpegType.rawValue, "public.jpeg",
                    "and the constant the code uses really is that UTI")

        guard let picked = ShelfIntake.imageData(from: pb) else {
            expect(false, "a JPEG board yields image data")
            return
        }
        expectEqual(picked.extension, "jpg", "JPEG keeps its own format")
        expectEqual(picked.data, jpeg, "and its own bytes")
    }

    suite("shelf-intake/prefers-png-over-jpeg") {
        // `imageData`'s docstring says "**The order of this lookup is the whole feature**", and only
        // TIFF-last was pinned. Measured: swapping the PNG and JPEG branches left all 2051 checks
        // green, because no board in this file carried both. A board carrying both is exactly what a
        // screenshot tool or a browser puts up.
        let png = pngData(8)
        let jpeg = jpegData(16)
        expect(png.count != jpeg.count,
               "the two fixtures differ in size, or this suite proves nothing")

        let pb = board("png-and-jpeg")
        // Both types declared up front: `setData` only works for a declared type, so two separate
        // `setData` calls after `clearContents()` would drop the first.
        pb.declareTypes([.png, NSPasteboard.PasteboardType("public.jpeg")], owner: nil)
        expect(pb.setData(png, forType: .png), "the board takes the PNG")
        expect(pb.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")),
               "and the JPEG")

        guard let picked = ShelfIntake.imageData(from: pb) else {
            expect(false, "a board carrying both yields image data")
            return
        }
        expectEqual(picked.extension, "png", "PNG wins when both are present")
        expectEqual(picked.data, png, "and the bytes are the PNG's, verbatim")
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
        // `&&`, not `||`. With `||` both operands were measured true — `data(forType: .png)` is
        // nil and `types` contains `public.tiff` — so the check could never be false, and worse,
        // both operands are `NSPasteboard` facts that never touch `ShelfIntake`, so no change to
        // the unit under test could falsify it. It survived all nine sabotages of this file,
        // including the one that reddened two other checks. The `&&` form measures the same thing
        // and can go false: on a PNG-carrying board it is false.
        expect(pb.data(forType: .png) == nil && pb.types?.contains(.tiff) == true,
               "the board offers TIFF and no PNG, so the TIFF branch is what runs")

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
        // A web URL in the middle, which is what pins `.urlReadingFileURLsOnly`. Without it the
        // fixture was two file URLs and nothing else: measured, flipping that option from `true`
        // to `false` left all 1938 checks green, because both spellings return 2 for a board
        // carrying only file URLs. With the web URL present, `false` returns 3.
        let web = URL(string: "https://example.com/x.png")
        pb.writeObjects([one as NSURL, (web ?? one) as NSURL, two as NSURL])
        // Every URL, not just the first. WheelView's existing reader takes `urls.first`,
        // which would shelve one file out of five and silently discard the rest.
        expectEqual(ShelfIntake.fileURLs(from: pb).count, 2,
                    "every dropped file URL is read, and only the file URLs")
    }

    suite("shelf-message/every-error-has-text") {
        // Before `ShelfMessage` existed, `ShelfError` had no user-facing text at all: a UI would have
        // shown "The operation couldn’t be completed. (ShelfError error 7.)" for a cap refusal. These
        // checks live in the unit binary rather than in smoke because `ShelfIntake.swift` is already
        // compiled into it, so they need no screen.
        //
        // Every case, named explicitly rather than looped, so adding a case to `ShelfError` fails the
        // compiler here as well as in `text(for:)` — a new refusal cannot ship with no words.
        let all: [ShelfError] = [
            .blockedByFile(URL(fileURLWithPath: "/tmp/Shelf")),
            .shelfNotWritable(URL(fileURLWithPath: "/tmp/Shelf")),
            .shelfUnusable(URL(fileURLWithPath: "/tmp/Shelf"), code: 513),
            .notEnoughSpace("report.pdf"),
            .sourceMissing("report.pdf"),
            .sourceUnreadable("report.pdf"),
            .volumeDisconnected("report.pdf"),
            .wouldExceedCap(dropBytes: 900, existingBytes: 800, capBytes: 1000),
            .isApplication("Fake.app"),
            .nothingUsableOnClipboard,
            .tooManyNames("report.pdf"),
            .nameTooLong("report.pdf"),
        ]
        expectEqual(all.count, 12, "every ShelfError case is covered here")
        for error in all {
            let text = ShelfMessage.text(for: error)
            expect(!text.isEmpty, "every refusal has words, \(error) gave none")
            // §6 forbids surfacing `FileManager`'s own text, which names the *destination* for a
            // source it cannot read. Nothing here may leak it.
            expect(!text.contains("permission to access"),
                   "and no FileManager text leaks through, got \(text)")
        }

        // The code in `shelfUnusable` is carried for a bug report and must never reach the user —
        // that is the whole reason the case carries it rather than rethrowing FileManager's error.
        expect(!ShelfMessage.text(for: .shelfUnusable(URL(fileURLWithPath: "/tmp/x"), code: 513))
            .contains("513"),
               "the diagnostic code is not shown to the user")

        // The cap refusal does the arithmetic rather than stating three numbers, which is what makes
        // it actionable. Sizes are Finder's, so 1 GB reads as the user's 1 GB.
        let capped = ShelfMessage.text(for: .wouldExceedCap(dropBytes: 900_000_000,
                                                           existingBytes: 800_000_000,
                                                           capBytes: 1_073_741_824))
        expect(capped.contains("900 MB"), "the drop size is formatted, got \(capped)")
        expect(capped.contains("1.07 GB"), "and so is the cap, got \(capped)")

        // The two cases whose wording says what to do, not just what happened.
        expect(ShelfMessage.text(for: .tooManyNames("report.pdf")).contains("rename it"),
               "a name collision tells the user how to fix it")
        expect(ShelfMessage.text(for: .nameTooLong("report.pdf")).contains("shorten it"),
               "and so does a name that is too long")
        expect(ShelfMessage.text(for: .isApplication("Fake.app")).contains("wheel"),
               "and an app points at the wheel, which is where it belongs")
    }

    suite("shelf-message/hub-forecast") {
        // The words the hub shows while a drag is over it. Both sides of the plural, because a
        // forecast that says "+1 files" is the kind of thing nobody notices until a screenshot.
        expectEqual(ShelfMessage.dropForecast(count: 1), "+1 file", "one file is singular")
        expectEqual(ShelfMessage.dropForecast(count: 3), "+3 files", "and three are plural")
        // Zero is unreachable through `draggingEntered`, which requires a non-empty URL list, but
        // the string must still read as English rather than "+0 file".
        expectEqual(ShelfMessage.dropForecast(count: 0), "+0 files", "and zero reads as plural")

        // The refusal says only what has been cheaply measured. Naming the drop's own size would
        // need the exact total, which walks every source in full — up to ~3.6 s on a hostile tree,
        // paid while the user is mid-drag.
        expect(!ShelfMessage.dropRefused.isEmpty, "the refusal has a headline")
        let forecast = ShelfMessage.capForecast(existing: 6_300_000, cap: 1_073_741_824)
        expect(forecast.contains("6.3 MB"), "the forecast names what is already there, got \(forecast)")
        expect(forecast.contains("1.07 GB"), "and the cap, got \(forecast)")
        // Same vocabulary as the refusal the user would see on release, so the two are one family.
        let released = ShelfMessage.text(for: .wouldExceedCap(dropBytes: 2_000_000_000,
                                                            existingBytes: 6_300_000,
                                                            capBytes: 1_073_741_824))
        expect(released.contains("6.3 MB") && released.contains("1.07 GB"),
               "and the post-release refusal uses the same numbers, got \(released)")
    }

    suite("shelf-message/summary") {
        let box = scratchDirectory("shelf-message")
        let shelf = Shelf(root: box.appendingPathComponent("Shelf", isDirectory: true))
        do { try shelf.ensureExists() } catch { expect(false, "setup: \(error)") }

        var one = AddOutcome()
        one.added = ["report.pdf"]
        expectEqual(ShelfMessage.summary(one, shelf: shelf), "Added report.pdf to the shelf",
                    "one file is named")

        var many = AddOutcome()
        many.added = ["a.txt", "b.txt", "c.txt"]
        expectEqual(ShelfMessage.summary(many, shelf: shelf), "Added 3 items to the shelf",
                    "several are counted rather than listed")

        // A partial drop must say so. "Added 2" with three unaccounted for is the bug `AddOutcome`
        // exists to prevent, and the summary is where the user finally sees it.
        var mixed = AddOutcome()
        mixed.added = ["a.txt"]
        mixed.refusals = [.sourceMissing("b.txt"), .isApplication("C.app")]
        expectEqual(ShelfMessage.summary(mixed, shelf: shelf),
                    "Added a.txt to the shelf — skipped 2",
                    "a partial drop reports what was skipped")

        // Nothing added: the refusal itself is the message, not a count of zero.
        var refused = AddOutcome()
        refused.refusals = [.isApplication("Fake.app")]
        expectEqual(ShelfMessage.summary(refused, shelf: shelf),
                    "Fake.app is an app — drop it on the wheel to pin it instead",
                    "a whole-drop refusal speaks for itself")

        // Neither added nor refused — what `add([])` returns. The plan's version indexed
        // `outcome.added[0]` here and would have trapped.
        expectEqual(ShelfMessage.summary(AddOutcome(), shelf: shelf), "Nothing to add",
                    "an empty outcome does not crash and says something true")

        // The ten-item note, which is `Shelf.itemNoteThreshold`'s first and only consumer. Below the
        // threshold it must stay silent, at it it must speak — both sides, or the check is one-sided.
        for index in 0..<(Shelf.itemNoteThreshold - 1) {
            try? Data(repeating: 0x41, count: 4)
                .write(to: shelf.root.appendingPathComponent("f\(index).txt"))
        }
        expectEqual(shelf.total().count, Shelf.itemNoteThreshold - 1, "one short of the threshold")
        expectEqual(ShelfMessage.summary(one, shelf: shelf), "Added report.pdf to the shelf",
                    "below the threshold the note stays silent")

        try? Data(repeating: 0x41, count: 4)
            .write(to: shelf.root.appendingPathComponent("last.txt"))
        expectEqual(shelf.total().count, Shelf.itemNoteThreshold, "now exactly at the threshold")
        expectEqual(ShelfMessage.summary(one, shelf: shelf),
                    "Added report.pdf to the shelf — shelf now holds \(Shelf.itemNoteThreshold)",
                    "and at the threshold it mentions the count")
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

        // A 24-hour clock, asserted on an afternoon time. Measured: switching the format to
        // `hh.mm.ss a` left every check in this binary green — the comparison above uses two times
        // an hour apart on the same morning, which sorts correctly under a 12-hour clock too. The
        // docstring's claim that a 12-hour locale "would append AM and break the sort" was untested.
        var afternoon = DateComponents()
        afternoon.year = 2026; afternoon.month = 9; afternoon.day = 22
        afternoon.hour = 17; afternoon.minute = 5; afternoon.second = 3
        let pm = Calendar(identifier: .gregorian).date(from: afternoon) ?? Date()
        let pmName = ShelfIntake.pastedName(at: pm, extension: "png")
        expectEqual(pmName, "Pasted 2026-09-22 at 17.05.03.png",
                    "the clock is 24-hour with zero-padded fields, got \(pmName)")
        expect(!pmName.contains("AM") && !pmName.contains("PM"),
               "and carries no meridiem, which would break the sort")

        // The sort across the noon boundary, which is the case a 12-hour clock gets wrong: under
        // `hh` it would render 05 and 05, and the ordering would become a coin toss.
        var morning = afternoon
        morning.hour = 5
        let am = Calendar(identifier: .gregorian).date(from: morning) ?? Date()
        expect(ShelfIntake.pastedName(at: am, extension: "png") < pmName,
               "05:05 sorts before 17:05, which a 12-hour clock would not guarantee")
    }
}

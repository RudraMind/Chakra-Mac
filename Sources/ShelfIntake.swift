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
    /// array order, and **AppKit synthesises TIFF on demand**: a board carrying only a PNG
    /// still answers `data(forType: .tiff)`, with bytes it invented. So a TIFF-first lookup —
    /// or anything that goes through `NSImage(pasteboard:)` — writes a re-encoded file
    /// instead of the image the user copied.
    ///
    /// No inflation ratio is quoted, deliberately. TIFF here is uncompressed raw pixels, so
    /// the ratio is a property of **how compressible the source image is**, not of AppKit:
    /// measured across three images it was 12.5×, 30.6× and 192×, and on this project's 8×8
    /// test fixture 152 bytes became 3,664. Any single number would be wrong for the next
    /// image. The load-bearing fact is that the bytes are invented, not how many of them
    /// there are.
    ///
    /// PNG and JPEG are taken **verbatim**, never re-encoded. Measured: a screenshot as
    /// JPEG is only 6% smaller than PNG while being lossy, and a photo as PNG is 6.7×
    /// larger than its JPEG. Passing through whatever arrived is optimal in both directions.
    ///
    /// The sequential `if let` lookup is safe rather than lucky: measured, a `public.jpeg`
    /// board returns **nil** for `data(forType: .png)`, so the PNG branch cannot steal a
    /// JPEG. Only TIFF is synthesised from the other two, which is exactly why it is last.
    ///
    /// **Callers must not run this on the main thread when the TIFF branch can be reached.**
    /// §2.9 measured TIFF→PNG conversion of a 3456×2234 retina grab at up to 414 ms. This
    /// function is synchronous by design — it is pure, so it is testable — and moving the
    /// work off the main thread is the caller's job, not something this type can enforce.
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
    /// as `/` — measured, a file genuinely named `… at 08:59:49.png` is created successfully
    /// and then displays in Finder as `… at 08/59/49.png`.
    static func pastedName(at date: Date, extension pathExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pasted \(formatter.string(from: date)).\(pathExtension)"
    }
}

/// The words Chakra shows for a shelf outcome.
///
/// One place, so the orb, the hub and any future entry point cannot drift apart.
///
/// `FileManager`'s own `localizedDescription` is unusable and that is why every string here is
/// Chakra's own: measured, for a *source* file it cannot read it says "…you don't have permission to
/// access 'dst'", naming the **destination**.
///
/// Until this type existed, `ShelfError` had no user-facing text at all — a UI would have shown
/// "The operation couldn’t be completed. (ShelfError error 7.)" for a cap refusal.
enum ShelfMessage {
    /// What to say about a whole drop.
    static func summary(_ outcome: AddOutcome, shelf: Shelf) -> String {
        // `.first`, not `[0]`, at both sites. An unguarded subscript here would trap on an outcome
        // that is empty in both arrays, and a message builder is the last place that should be able
        // to crash the app.
        if outcome.added.isEmpty, let first = outcome.refusals.first {
            return text(for: first)
        }
        guard let onlyName = outcome.added.first else {
            // Neither added nor refused anything: a drop of nothing, which `add([])` returns.
            return "Nothing to add"
        }
        let head = outcome.added.count == 1
            ? "Added \(onlyName) to the shelf"
            : "Added \(outcome.added.count) items to the shelf"
        guard outcome.refusals.isEmpty else {
            return head + " — skipped \(outcome.refusals.count)"
        }
        // Informational, never a warning, and the count is read rather than written. This is the
        // first and only consumer of `Shelf.itemNoteThreshold`; before it, the constant was declared
        // and read by nothing, so spec §2.12's ten-item note did not exist.
        let count = shelf.total().count
        return count >= Shelf.itemNoteThreshold
            ? head + " — shelf now holds \(count)"
            : head
    }

    /// What to say about one refusal. Every case of `ShelfError`, exhaustively — the compiler
    /// enforces that, which is why a new case cannot ship without text.
    static func text(for error: ShelfError) -> String {
        switch error {
        case .blockedByFile:
            return "A file named Shelf is in the way — Chakra can't use its shelf folder"
        case .notEnoughSpace(let name):
            return "Not enough space to add \(name)"
        case .sourceMissing(let name):
            return "\(name) is no longer there"
        case .sourceUnreadable(let name):
            return "Chakra can't read \(name)"
        case .volumeDisconnected(let name):
            return "The disk holding \(name) was disconnected — nothing was added"
        case .wouldExceedCap(let drop, let existing, let cap):
            // The message does the arithmetic, which is what turns a refusal into something the
            // user can act on rather than a fact they have to interpret.
            return "That's \(bytes(drop)) and the shelf holds \(bytes(existing)) "
                + "— the limit is \(bytes(cap))"
        case .isApplication(let name):
            return "\(name) is an app — drop it on the wheel to pin it instead"
        case .nothingUsableOnClipboard:
            return "Nothing on the clipboard Chakra can save as a file"
        case .shelfNotWritable:
            return "Chakra can't write to its Shelf folder"
        case .shelfUnusable:
            // The code is deliberately not shown. It is carried for a bug report, which is the
            // whole reason that case exists rather than rethrowing `FileManager`'s misleading text.
            return "Chakra can't set up its Shelf folder"
        // The two cases below say what to do, not just what happened, because unlike every other
        // refusal here both are fixable by the user in one step.
        case .tooManyNames(let name):
            return "Too many files named \(name) are already on the shelf "
                + "— rename it and try again"
        case .nameTooLong:
            return "That file's name is too long for the shelf — shorten it and try again"
        }
    }

    // MARK: - What the hub says while a drag is over it

    /// The headline when a drop will not fit.
    ///
    /// Deliberately not "That's 1.4 GB", which an earlier mockup promised. Naming the drop's size
    /// needs the *exact* total, and the exact total walks every source in full — the cost `add(_:)`
    /// documents as ~3.6 s on a hostile tree, paid only on its refusal path. Paying it while the
    /// user is mid-drag would stall the drag. So the hub says only what it has cheaply measured.
    static let dropRefused = "Won't fit"

    /// Released over the hub with nothing usable on the drag.
    static let nothingDroppable = "Nothing there Chakra can put on the shelf"

    /// What a drag over the hub is about to add.
    ///
    /// The change, not the destination. "Drop files here" is what every app shows and says nothing
    /// a pointer over a highlighted circle has not already said; the number of files about to land
    /// is information the user does not otherwise have.
    static func dropForecast(count: Int) -> String {
        count == 1 ? "+1 file" : "+\(count) files"
    }

    /// Why a drop will not fit, in the numbers the hub already knows.
    ///
    /// Both terms are cheap: `existing` comes from the `total()` the hub reads anyway, and the cap
    /// is a constant. Same vocabulary as `wouldExceedCap`'s own message, so the sentence the user
    /// sees while hovering and the one they would see on release belong to the same family.
    static func capForecast(existing: Int64, cap: Int64) -> String {
        "the shelf holds \(bytes(existing)) of \(bytes(cap))"
    }

    /// Sizes the way Finder writes them, so 1 GB reads as the user's 1 GB.
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

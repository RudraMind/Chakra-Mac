import AppKit

private let slackPath = "/Applications/Slack.app"

func runModelTests() {
    suite("model/resolution") {
        // Safari ships with every Mac, so this holds on a clean CI runner too.
        let safari = RingItem.make(path: "/Applications/Safari.app")
        expectEqual(safari.isMissing, false, "an installed app is not missing")
        expectEqual(safari.name, "Safari", "the display name drops the .app extension")
        expectEqual(safari.path, "/Applications/Safari.app", "the path round-trips")
        expect(safari.icon.size.width > 0, "an installed app has a real icon")

        // A localised system app keeps its Finder-visible name.
        let settings = RingItem.make(path: "/System/Applications/System Settings.app")
        expectEqual(settings.isMissing, false, "a system app resolves")
        expectEqual(settings.name, "System Settings", "system app name")

        // Spaces in the bundle name must survive.
        let outlook = RingItem.make(path: "/Applications/Microsoft Outlook.app")
        expectEqual(outlook.name, "Microsoft Outlook", "a name with a space is preserved")
    }

    suite("model/missing") {
        // A deleted app must still produce a usable item so the slot can show
        // the user which entry broke, rather than silently disappearing.
        let gone = RingItem.make(path: "/Applications/DefinitelyNotInstalled.app")
        expectEqual(gone.isMissing, true, "an absent app is flagged missing")
        expectEqual(gone.name, "DefinitelyNotInstalled", "an absent app still gets a name")
        expect(gone.icon.size.width > 0, "an absent app gets a placeholder icon")

        // Degenerate input must not trap.
        let empty = RingItem.make(path: "")
        expectEqual(empty.isMissing, true, "an empty path is missing")
        expect(!empty.name.isEmpty, "an empty path still yields a non-empty name")

        let weird = RingItem.make(path: "/")
        expect(!weird.name.isEmpty, "the root path yields a non-empty name")
    }

    suite("model/normalize-path") {
        let canonical = RingItem.normalizePath(slackPath)
        expectEqual(canonical, slackPath, "an installed app is already canonical")
        // Every spelling of one file has to collapse to the same string, or the
        // same app could occupy two slots or sit on both rings at once.
        expectEqual(RingItem.normalizePath(slackPath + "/"), canonical,
                    "a trailing slash is dropped")
        expectEqual(RingItem.normalizePath(slackPath + "///"), canonical,
                    "repeated trailing slashes are dropped")
        expectEqual(RingItem.normalizePath("/Applications//Slack.app"), canonical,
                    "a doubled separator is collapsed")
        expectEqual(RingItem.normalizePath("/Applications/../Applications/Slack.app"), canonical,
                    "a .. segment is resolved")
        expectEqual(RingItem.normalizePath("/Applications/./Slack.app"), canonical,
                    "a . segment is resolved")
        // The filesystem, not the string, decides identity: a case variant on a
        // case-insensitive volume is the same file. Skipped where it is not.
        let lowered = "/system/applications/calendar.app"
        if FileManager.default.fileExists(atPath: lowered) {
            expectEqual(RingItem.normalizePath(lowered), "/System/Applications/Calendar.app",
                        "a case variant resolves to the real name")
        }
        // A symlinked ancestor is resolved, so two spellings of the same folder do
        // not look like two different apps.
        expectEqual(RingItem.normalizePath("/etc/hosts"), "/private/etc/hosts",
                    "a symlinked parent directory resolves to its real path")
        // The last component's own symlink is deliberately left alone — see the
        // note in normalizePath. /tmp is itself a link to /private/tmp.
        expectEqual(RingItem.normalizePath("/tmp"), "/tmp",
                    "a path that is itself a symlink is kept as the user spelled it")

        expectEqual(RingItem.normalizePath(""), "", "an empty path stays empty")
        expectEqual(RingItem.normalizePath("/"), "/", "the volume root is left alone")
        // A path that does not exist cannot be resolved by the filesystem, so it
        // gets string canonicalisation and nothing more.
        expectEqual(RingItem.normalizePath("/Applications/../Applications/NoSuchApp.app"),
                    "/Applications/NoSuchApp.app", "an absent path is still tidied up")
        expect(RingItem.normalizePath("relative.app").hasPrefix("/"),
               "a relative path comes back absolute, which is why callers refuse it first")
    }

    suite("model/item-cache") {
        // Reopening the wheel rebuilds thirteen items. Reading each icon off disk
        // every time is the difference between the ring appearing at once and the
        // ring appearing in a moment.
        RingItem.clearCache()
        let first = RingItem.make(path: slackPath)
        expectEqual(RingItem.cacheMisses, 1, "the first build is a miss")
        expectEqual(RingItem.cacheHits, 0, "the first build cannot be a hit")
        let second = RingItem.make(path: slackPath)
        expectEqual(RingItem.cacheHits, 1, "the second build is a hit")
        expectEqual(RingItem.cacheMisses, 1, "the second build did not rebuild")
        expect(first.icon === second.icon, "the hit hands back the same icon")
        expectEqual(second.name, first.name, "the hit hands back the same name")
        // A different spelling of the same file is the same cache entry.
        _ = RingItem.make(path: slackPath + "/")
        expectEqual(RingItem.cacheHits, 2, "a trailing slash hits the same entry")

        // A missing app is cached too, but existence is re-checked every time, so
        // reinstalling it shows up without a relaunch.
        RingItem.clearCache()
        let absent = "/Applications/DefinitelyNotInstalled.app"
        expectEqual(RingItem.make(path: absent).isMissing, true, "an absent app is missing")
        expectEqual(RingItem.make(path: absent).isMissing, true, "and still missing on a hit")
        expectEqual(RingItem.cacheHits, 1, "an absent app is cached rather than re-read")

        // An app updated in place keeps its path but may change its icon and name,
        // so the bundle's modification date is what makes an entry reusable.
        RingItem.clearCache()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("chakra-cache-test-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        let bundle = root.appendingPathComponent("Fake.app", isDirectory: true)
        try? fm.removeItem(at: root)
        do {
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        } catch {
            expect(false, "the test bundle could be created: \(error)")
            return
        }
        defer { try? fm.removeItem(at: root) }

        let before = RingItem.make(path: bundle.path)
        expectEqual(before.isMissing, false, "the test bundle exists")
        _ = RingItem.make(path: bundle.path)
        expectEqual(RingItem.cacheHits, 1, "an unchanged bundle is served from the cache")
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                              ofItemAtPath: bundle.path)
        _ = RingItem.make(path: bundle.path)
        expectEqual(RingItem.cacheHits, 1, "a changed bundle is not served from the cache")
        expectEqual(RingItem.cacheMisses, 2, "a changed bundle is rebuilt")

        // Deleting the app has to flip `isMissing`, cache or no cache.
        try? fm.removeItem(at: bundle)
        expectEqual(RingItem.make(path: bundle.path).isMissing, true,
                    "a deleted app stops being served as present")
    }

    suite("model/cache-validity") {
        // The rule on its own, away from the filesystem.
        let now = Date()
        expectEqual(RingItem.isCacheEntryValid(cachedStamp: now, currentStamp: now,
                                              cachedMissing: false, currentlyMissing: false),
                    true, "the same date on a present file is reusable")
        expectEqual(RingItem.isCacheEntryValid(cachedStamp: now,
                                              currentStamp: now.addingTimeInterval(1),
                                              cachedMissing: false, currentlyMissing: false),
                    false, "a newer date is not reusable")
        expectEqual(RingItem.isCacheEntryValid(cachedStamp: nil, currentStamp: nil,
                                              cachedMissing: true, currentlyMissing: true),
                    true, "two missing files are interchangeable")
        expectEqual(RingItem.isCacheEntryValid(cachedStamp: nil, currentStamp: nil,
                                              cachedMissing: false, currentlyMissing: false),
                    false, "a present file with no date is never trusted")
        expectEqual(RingItem.isCacheEntryValid(cachedStamp: nil, currentStamp: now,
                                              cachedMissing: true, currentlyMissing: false),
                    false, "an app that came back is rebuilt")
        expectEqual(RingItem.isCacheEntryValid(cachedStamp: now, currentStamp: nil,
                                              cachedMissing: false, currentlyMissing: true),
                    false, "an app that went away is rebuilt")
    }

    suite("model/boot-volume") {
        expectEqual(RingItem.isOnBootVolume(URL(fileURLWithPath: "/Applications/Safari.app")),
                    true, "an app in /Applications is on the boot volume")
        expectEqual(RingItem.isOnBootVolume(URL(fileURLWithPath: "/System/Applications/System Settings.app")),
                    true, "a system app is on the boot volume")
        // An unresolvable path has no volume, so it must not be claimed as local.
        expectEqual(RingItem.isOnBootVolume(URL(fileURLWithPath: "/Volumes/NoSuchDisk/Foo.app")),
                    false, "a path on an absent volume is not on the boot volume")
    }

    suite("model/dominant-colour") {
        // Music's icon is strongly coloured, so the extractor must not fall back
        // to grey. Exact values are not asserted; saturation is the property
        // that matters for a halo to look like the app it belongs to.
        let icon = RingItem.make(path: "/System/Applications/Music.app").icon
        let colour = RingItem.dominantColor(of: icon)
        expectClose(colour.alphaComponent, 1, "the halo colour is opaque")
        if let rgb = colour.usingColorSpace(.deviceRGB) {
            expect(rgb.saturationComponent > 0.15,
                   "a colourful icon yields a saturated colour, got \(rgb.saturationComponent)")
        } else {
            expect(false, "the halo colour converts to RGB")
        }

        // A blank image has nothing to extract and must degrade, not crash.
        let blank = NSImage(size: NSSize(width: 16, height: 16))
        let fallback = RingItem.dominantColor(of: blank)
        expectClose(fallback.alphaComponent, 1, "the fallback colour is opaque")

        // A zero-sized image is the pathological case.
        let zero = NSImage(size: .zero)
        _ = RingItem.dominantColor(of: zero)
        expect(true, "a zero-sized image does not crash the extractor")
    }

    // The extractor has to return the same colour every time, and proving that needs a
    // deliberate tie rather than a repeated call.
    //
    // `Dictionary.values.max` returns the first maximal element in iteration order, and
    // Swift seeds hashing randomly **per process** — so calling the extractor twice in one
    // process always agreed even while it was broken. The bug only showed across launches:
    // measured on real icons, 4 of 83 installed apps tie exactly, and Passwords.app
    // alternated between #FFD61F and #0C77F3 while Safari, which has no tie, never moved.
    //
    // So this builds an exact tie — half pure red, half pure blue, 512 pixels each — and
    // asserts which one wins. Blue does, because the tie is broken on the bucket key and
    // blue's is 7 against red's 7168. Before the fix this assertion failed on roughly half
    // of all runs; the flakiness *was* the defect.
    suite("model/dominant-colour-is-deterministic") {
        let side = 64
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side / 2, height: side).fill()
        NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(x: side / 2, y: 0, width: side / 2, height: side).fill()
        image.unlockFocus()

        guard let colour = RingItem.dominantColor(of: image).usingColorSpace(.sRGB) else {
            expect(false, "the tie-break colour converts to sRGB")
            return
        }
        // Pure blue survives the saturation boost as #0000FF: the mean of (0, 0, 255) is
        // 85, and 85 + (255 - 85) * 1.45 clamps to 255 while the other two clamp to 0.
        expect(colour.blueComponent > 0.9,
               "an exact tie resolves to the lower bucket key, which is blue — "
                   + "got blue \(colour.blueComponent)")
        expect(colour.redComponent < 0.1,
               "the losing bucket does not bleed into the result — got red \(colour.redComponent)")

        // And the result must not depend on how many times it is asked for.
        let again = RingItem.dominantColor(of: image).usingColorSpace(.sRGB)
        expectClose(again?.blueComponent ?? 0, colour.blueComponent,
                    "the same image yields the same colour on a second call")
    }

    // The string half of the recents filter, which is what stops the inner ring
    // pointing at something that is not an app or will not exist tomorrow. Kept
    // separate from `isEligibleForRecents` so it can be tested without needing
    // each of these paths to actually be on this machine.
    suite("model/plausible-app-path") {
        expect(RingItem.isPlausibleAppPath("/Applications/Slack.app"),
               "an installed app is plausible")
        expect(RingItem.isPlausibleAppPath("/System/Applications/Utilities/Terminal.app"),
               "a system app is plausible")

        // Observed in a real preferences file: the wheel recorded its own test
        // binary, because anything that activates is an app as far as the
        // workspace notification is concerned.
        expect(!RingItem.isPlausibleAppPath("/Users/someone/build/chakra-smoke"),
               "a bare executable is not an app")
        expect(!RingItem.isPlausibleAppPath("/bin/ls"), "a unix tool is not an app")
        expect(!RingItem.isPlausibleAppPath("/Applications"),
               "the applications folder is not an app")
        expect(!RingItem.isPlausibleAppPath("/Users/someone/Documents/notes.txt"),
               "a document is not an app")

        // Also observed: an app run from a quarantined download is translocated to
        // a random read-only mount that is destroyed when it quits, so a slot
        // pointing there is broken by the time the user looks at it.
        expect(!RingItem.isPlausibleAppPath(
                "/private/var/folders/pb/8vr9c/T/AppTranslocation/8ECCDF04/d/DockDoor.app"),
               "a translocated app is not plausible")
        expect(!RingItem.isPlausibleAppPath("/private/var/folders/pb/8vr9c/T/Thing.app"),
               "an app in the temporary folder is not plausible")
        expect(!RingItem.isPlausibleAppPath("/private/tmp/Thing.app"),
               "an app in /private/tmp is not plausible")
        expect(!RingItem.isPlausibleAppPath("/Volumes/Installer/Thing.app"),
               "an app on another volume is not plausible")

        // Every prefix has to be rejected whatever its case. The suffix test was
        // case-insensitive while the prefix test was not, so `/Volumes/Foo.app` was
        // rejected and `/volumes/Foo.app` sailed through — along with `/TMP/`,
        // `/private/TMP/` and `/private/VAR/folders/`.
        //
        // `normalizePath` hides this for a path that exists, because it canonicalises the
        // case. It cannot help for a path that does not — and those are exactly the ones
        // this filter is for: an unmounted disk image, a destroyed translocation copy, a
        // dead network share. A leaked entry reached `fileExists`, which is the stall the
        // filter's own docstring says must never happen.
        expect(!RingItem.isPlausibleAppPath("/volumes/Installer/Thing.app"),
               "a lower-cased /volumes/ prefix is still not plausible")
        expect(!RingItem.isPlausibleAppPath("/VOLUMES/Installer/Thing.app"),
               "an upper-cased /VOLUMES/ prefix is still not plausible")
        expect(!RingItem.isPlausibleAppPath("/TMP/Thing.app"),
               "an upper-cased /TMP/ prefix is still not plausible")
        expect(!RingItem.isPlausibleAppPath("/private/TMP/Thing.app"),
               "an upper-cased /private/TMP/ prefix is still not plausible")
        expect(!RingItem.isPlausibleAppPath("/private/VAR/folders/x/Thing.app"),
               "an upper-cased /private/VAR/folders/ prefix is still not plausible")
        // The suffix stays case-insensitive, which it always was.
        expect(RingItem.isPlausibleAppPath("/Applications/Thing.APP"),
               "an upper-cased .APP extension is still an app")

        expect(!RingItem.isPlausibleAppPath(""), "an empty path is not plausible")
        expect(!RingItem.isPlausibleAppPath("Slack.app"),
               "a relative path is not plausible")
        expect(!RingItem.isPlausibleAppPath("/"), "the volume root is not plausible")
        // A path is normalised before it is stored, which strips the trailing
        // slash, but the check must not depend on that having happened.
        expect(RingItem.isPlausibleAppPath("/Applications/Slack.app/"),
               "a trailing slash does not make an app implausible")

        // And the production test has to actually apply it.
        expect(!RingItem.isEligibleForRecents("/bin/ls"),
               "the recents filter rejects a unix tool that really exists")
        expect(RingItem.isEligibleForRecents("/System/Applications/Utilities/Terminal.app"),
               "the recents filter accepts a real system app")
    }
}

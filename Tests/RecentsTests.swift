import Foundation

private var recentsCounter = 0

private func scratchDefaults() -> UserDefaults {
    recentsCounter += 1
    let name = "local.chakra.tests.recents.\(recentsCounter)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    registerScratchDomain(name)
    return UserDefaults(suiteName: name)!
}

private let selfPath = "/Applications/Chakra.app"
private let all: (String) -> Bool = { _ in true }

func runRecentsTests() {
    suite("recents/record") {
        let r = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        expectEqual(r.queue.count, 0, "a fresh queue is empty")
        r.record("/a.app")
        r.record("/b.app")
        expectEqual(r.queue, ["/b.app", "/a.app"], "the newest activation is first")
        // Re-activating an app moves it to the front instead of duplicating it.
        r.record("/a.app")
        expectEqual(r.queue, ["/a.app", "/b.app"], "re-activation promotes without duplicating")
        expectEqual(r.queue.count, 2, "no duplicate entry was created")
        // Activating the app that is already first changes nothing.
        r.record("/a.app")
        expectEqual(r.queue, ["/a.app", "/b.app"], "re-activating the head is a no-op")
    }

    suite("recents/rejections") {
        let r = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        r.record(selfPath)
        expectEqual(r.queue.count, 0, "Chakra never records itself")
        r.record("")
        expectEqual(r.queue.count, 0, "an empty path is ignored")
        r.record(selfPath + "/")
        expectEqual(r.queue.count, 0, "a trailing slash does not smuggle Chakra in")

        // Anything that activates looks like an application to the workspace
        // notification, so the queue has to reject what is not a real app bundle.
        // All three of these turned up in a real preferences file.
        r.record("/Users/someone/build/chakra-smoke")
        expectEqual(r.queue.count, 0, "a bare executable is not recorded")
        r.record("/private/var/folders/pb/x/T/AppTranslocation/ABC/d/Thing.app")
        expectEqual(r.queue.count, 0, "a translocated app is not recorded")
        r.record("/Volumes/Installer/Thing.app")
        expectEqual(r.queue.count, 0, "an app on another volume is not recorded")
    }

    suite("recents/repairs-stored-junk") {
        let defaults = scratchDefaults()
        defaults.set(["/Applications/Real.app",
                      "/Users/someone/build/chakra-smoke",
                      "/private/var/folders/pb/x/T/AppTranslocation/ABC/d/Gone.app",
                      "/Applications/Other.app"],
                     forKey: "recents")
        let r = Recents(defaults: defaults, selfPath: selfPath)
        expectEqual(r.queue, ["/Applications/Real.app", "/Applications/Other.app"],
                    "junk recorded by an older build is dropped on load")
        // And the repair is written through, so it does not have to be redone.
        expectEqual(defaults.stringArray(forKey: "recents") ?? [],
                    ["/Applications/Real.app", "/Applications/Other.app"],
                    "the repaired queue is saved")
    }

    suite("recents/capacity") {
        let r = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        for i in 0..<45 { r.record("/app\(i).app") }
        expectEqual(r.queue.count, Recents.capacity, "the queue is capped")
        expectEqual(r.queue.first, "/app44.app", "the newest entry is retained")
        expectEqual(r.queue.contains("/app0.app"), false, "the oldest entries are dropped")
        expectEqual(r.queue.last, "/app\(45 - Recents.capacity).app", "the oldest survivor is correct")
    }

    suite("recents/persistence") {
        let defaults = scratchDefaults()
        let r = Recents(defaults: defaults, selfPath: selfPath)
        r.record("/a.app")
        r.record("/b.app")
        // Surviving a restart is the whole point: the ring must not come back
        // blank after a reboot.
        let reloaded = Recents(defaults: defaults, selfPath: selfPath)
        expectEqual(reloaded.queue, ["/b.app", "/a.app"], "the queue survives a reload")

        let corrupt = scratchDefaults()
        corrupt.set(42, forKey: "recents")
        expectEqual(Recents(defaults: corrupt, selfPath: selfPath).queue.count, 0,
                    "a corrupt stored value is repaired to an empty queue")
        let mixed = scratchDefaults()
        mixed.set([1, "/a.app"], forKey: "recents")
        expectEqual(Recents(defaults: mixed, selfPath: selfPath).queue.count, 0,
                    "an array of the wrong element type is repaired")
    }

    suite("recents/substitution") {
        let r = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        for p in ["/j.app", "/i.app", "/h.app", "/g.app", "/f.app",
                  "/e.app", "/d.app", "/c.app", "/b.app", "/a.app"] { r.record(p) }
        expectEqual(r.queue.first, "/a.app", "the queue is newest-first")

        // Nothing excluded: the five most recent apps.
        expectEqual(r.inner(excluding: [], limit: 5, isEligible: all),
                    ["/a.app", "/b.app", "/c.app", "/d.app", "/e.app"],
                    "with nothing pinned the five newest appear")

        // The user's rule: an app already on the outer ring is not hidden behind
        // a gap — the next eligible app is pulled up to keep five distinct items.
        expectEqual(r.inner(excluding: ["/c.app"], limit: 5, isEligible: all),
                    ["/a.app", "/b.app", "/d.app", "/e.app", "/f.app"],
                    "a pinned app is replaced by the next one, not blanked")

        expectEqual(r.inner(excluding: ["/a.app", "/c.app", "/e.app"], limit: 5, isEligible: all),
                    ["/b.app", "/d.app", "/f.app", "/g.app", "/h.app"],
                    "three pinned apps pull three replacements up")

        // Normalisation: the outer ring may store a path with a trailing slash.
        expectEqual(r.inner(excluding: ["/c.app/"], limit: 5, isEligible: all),
                    ["/a.app", "/b.app", "/d.app", "/e.app", "/f.app"],
                    "exclusion normalises paths before comparing")

        // Uninstalled or unmounted apps are skipped the same way.
        let eligible: (String) -> Bool = { $0 != "/b.app" && $0 != "/d.app" }
        expectEqual(r.inner(excluding: [], limit: 5, isEligible: eligible),
                    ["/a.app", "/c.app", "/e.app", "/f.app", "/g.app"],
                    "ineligible apps are skipped and replaced")

        // Chakra itself can never appear, even if somehow stored.
        let withSelf = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        withSelf.record("/a.app")
        withSelf.forceQueueForTesting([selfPath, "/a.app"])
        expectEqual(withSelf.inner(excluding: [], limit: 5, isEligible: all), ["/a.app"],
                    "Chakra is filtered out of its own ring")
    }

    suite("recents/scarcity") {
        let r = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        expectEqual(r.inner(excluding: [], limit: 5, isEligible: all), [],
                    "an empty queue yields no inner items")

        for p in ["/c.app", "/b.app", "/a.app"] { r.record(p) }
        expectEqual(r.inner(excluding: [], limit: 5, isEligible: all),
                    ["/a.app", "/b.app", "/c.app"],
                    "fewer than five candidates yields fewer items rather than repeats")
        expectEqual(r.inner(excluding: ["/a.app", "/b.app", "/c.app"], limit: 5, isEligible: all), [],
                    "when everything is pinned the inner ring is empty")
        expectEqual(r.inner(excluding: [], limit: 0, isEligible: all), [],
                    "a zero limit yields nothing")
        expectEqual(r.inner(excluding: [], limit: -1, isEligible: all), [],
                    "a negative limit is safe")
        // The result must never contain a duplicate, whatever the queue holds.
        r.forceQueueForTesting(["/a.app", "/a.app", "/b.app"])
        expectEqual(r.inner(excluding: [], limit: 5, isEligible: all), ["/a.app", "/b.app"],
                    "a duplicated queue entry appears once")
    }

    suite("recents/spotlight") {
        // Environment-dependent, but the seeding path is the difference between
        // a useful first launch and an empty ring, so it is worth asserting.
        let ranking = Recents.spotlightRanking(limit: 30)
        expect(!ranking.isEmpty, "Spotlight returns a recency ranking on this machine")
        expectEqual(ranking.allSatisfy { $0.hasSuffix(".app") }, true,
                    "every ranked path is an app bundle")
        expectEqual(ranking.count, Set(ranking).count, "the ranking has no duplicates")
        expect(ranking.count <= 30, "the ranking respects its limit")
        expectEqual(ranking.allSatisfy { FileManager.default.fileExists(atPath: $0) }, true,
                    "every ranked app actually exists")
    }

    suite("recents/seeding") {
        let r = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        r.seedFromSpotlight()
        expect(!r.queue.isEmpty, "seeding fills an empty queue")
        expect(r.queue.count <= Recents.capacity, "seeding respects the cap")
        expectEqual(r.queue.contains(selfPath), false, "seeding never includes Chakra")

        // Seeding must not clobber a queue that already has real history in it.
        let existing = Recents(defaults: scratchDefaults(), selfPath: selfPath)
        existing.record("/kept.app")
        existing.seedFromSpotlight()
        expectEqual(existing.queue.first, "/kept.app", "a live queue keeps its head")
    }
}

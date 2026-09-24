import Foundation

private var suiteCounter = 0

/// Each test gets its own defaults domain so nothing leaks between cases or
/// into the user's real preferences.
private func scratchDefaults() -> UserDefaults {
    suiteCounter += 1
    let name = "local.chakra.tests.outer.\(suiteCounter)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    registerScratchDomain(name)
    return UserDefaults(suiteName: name)!
}

private let slack = "/Applications/Slack.app"
private let chrome = "/Applications/Google Chrome.app"
private let teams = "/Applications/Microsoft Teams.app"

func runOuterRingTests() {
    suite("outer/empty") {
        let ring = OuterRing(defaults: scratchDefaults())
        expectEqual(ring.slots.count, OuterRing.capacity, "a fresh ring has exactly `capacity` slots")
        expectEqual(ring.slots.allSatisfy { $0.isEmpty }, true, "a fresh ring is empty")
        expectEqual(ring.isFull, false, "a fresh ring is not full")
        expectEqual(ring.firstEmpty, 0, "the first empty slot of a fresh ring is 0")
        expect(ring.item(at: 0) == nil, "an empty slot has no item")
        expectEqual(ring.occupiedPaths.count, 0, "a fresh ring occupies nothing")
    }

    suite("outer/fixed-positions") {
        let ring = OuterRing(defaults: scratchDefaults())
        // Assigning slot 5 must not shuffle anything into slots 0 through 4.
        // Positions are muscle memory; they never compact.
        expectEqual(ring.set(slack, at: 5), true, "assigning slot 5 succeeds")
        expectEqual(ring.slots[5], slack, "slot 5 holds the app")
        expectEqual(ring.slots[0].isEmpty, true, "slot 0 stays empty")
        expectEqual(ring.firstEmpty, 0, "the first empty slot is still 0")
        expect(ring.item(at: 5) != nil, "slot 5 has an item")
        expectEqual(ring.item(at: 5)?.name, "Slack", "slot 5 resolves to the right app")
    }

    suite("outer/duplicates") {
        let ring = OuterRing(defaults: scratchDefaults())
        expectEqual(ring.set(slack, at: 0), true, "the first add succeeds")
        expectEqual(ring.set(slack, at: 3), false, "the same app cannot occupy two slots")
        expectEqual(ring.slots[3].isEmpty, true, "the refused add changed nothing")
        // A trailing slash is the same app; normalisation must catch it.
        expectEqual(ring.set(slack + "/", at: 3), false, "a trailing slash is still a duplicate")
        expectEqual(ring.contains(slack), true, "contains finds the app")
        expectEqual(ring.contains(slack + "/"), true, "contains normalises its argument")
        expectEqual(ring.contains(chrome), false, "contains rejects an app that is absent")
        // Re-assigning an app to the slot it already occupies is a no-op, not a
        // duplicate error.
        expectEqual(ring.set(slack, at: 0), true, "re-assigning the same slot succeeds")
        expectEqual(ring.slots[0], slack, "the slot is unchanged")
    }

    suite("outer/replace-and-remove") {
        let ring = OuterRing(defaults: scratchDefaults())
        ring.set(slack, at: 2)
        expectEqual(ring.set(chrome, at: 2), true, "dropping onto an occupied slot replaces it")
        expectEqual(ring.slots[2], chrome, "the slot holds the replacement")
        expectEqual(ring.contains(slack), false, "the replaced app is gone")

        // Add enough apps so the removal can succeed without breaching the floor.
        ring.set("/Applications/Calendar.app", at: 0)
        ring.set("/Applications/Notes.app", at: 1)
        ring.set(teams, at: 4)
        ring.remove(at: 2)
        expectEqual(ring.slots[2].isEmpty, true, "the removed slot is empty")
        expectEqual(ring.slots[4], teams, "removal does not disturb other slots")
        expect(ring.item(at: 2) == nil, "the removed slot has no item")
    }

    suite("outer/first-empty") {
        let ring = OuterRing(defaults: scratchDefaults())
        ring.set(slack, at: 0)
        ring.set(chrome, at: 1)
        expectEqual(ring.addToFirstEmpty(teams), 2, "the next app lands in slot 2")
        expectEqual(ring.slots[2], teams, "slot 2 holds it")
        // A duplicate must not consume a slot.
        expect(ring.addToFirstEmpty(slack) == nil, "a duplicate is refused rather than added")
        expectEqual(ring.slots[3].isEmpty, true, "the refused duplicate took no slot")
        // Gaps are filled lowest-first. Needs a fourth app so the removal succeeds.
        ring.set("/Applications/Calendar.app", at: 3)
        ring.remove(at: 1)
        expectEqual(ring.addToFirstEmpty(chrome), 1, "a freed slot is reused")
    }

    suite("outer/full") {
        let ring = OuterRing(defaults: scratchDefaults())
        for i in 0..<8 { ring.set("/Applications/Fake\(i).app", at: i) }
        expectEqual(ring.isFull, true, "eight apps fill the ring")
        expect(ring.firstEmpty == nil, "a full ring has no empty slot")
        expect(ring.addToFirstEmpty(slack) == nil, "a full ring refuses new apps")
        expectEqual(ring.occupiedPaths.count, Settings.defaultOuterSlots,
                    "every visible slot is occupied")
        // Replacing still works when full — that is the escape hatch.
        expectEqual(ring.set(slack, at: 3), true, "an explicit slot assignment still replaces")
        expectEqual(ring.slots[3], slack, "the replacement took effect")
    }

    suite("outer/bounds") {
        let ring = OuterRing(defaults: scratchDefaults())
        // Out-of-range indices must be refused, never trapped on.
        expectEqual(ring.set(slack, at: OuterRing.capacity), false, "an index past the capacity is out of range")
        expectEqual(ring.set(slack, at: -1), false, "a negative index is out of range")
        expectEqual(ring.set(slack, at: 99), false, "a large index is out of range")
        expect(ring.item(at: OuterRing.capacity) == nil, "reading out of range yields nothing")
        expect(ring.item(at: -1) == nil, "reading a negative index yields nothing")
        ring.remove(at: OuterRing.capacity)
        ring.remove(at: -3)
        expect(true, "removing out of range does not crash")
        // An empty path is not a valid app.
        expectEqual(ring.set("", at: 0), false, "an empty path is refused")
    }

    suite("outer/persistence") {
        let defaults = scratchDefaults()
        let ring = OuterRing(defaults: defaults)
        ring.set(slack, at: 1)
        ring.set(chrome, at: 6)
        // A second store reading the same domain must see the same ring.
        let reloaded = OuterRing(defaults: defaults)
        expectEqual(reloaded.slots[1], slack, "slot 1 survived a reload")
        expectEqual(reloaded.slots[6], chrome, "slot 6 survived a reload")
        expectEqual(reloaded.slots.count, OuterRing.capacity, "the reloaded ring still has `capacity` slots")
    }

    suite("outer/defensive-decoding") {
        // A short array is padded rather than discarded, so a partial write does
        // not cost the user their whole ring.
        let short = scratchDefaults()
        short.set([slack, chrome], forKey: "outerSlots")
        let padded = OuterRing(defaults: short)
        expectEqual(padded.slots.count, OuterRing.capacity, "a short array is padded to `capacity`")
        expectEqual(padded.slots[0], slack, "padding preserves existing entries")
        expectEqual(padded.slots[7].isEmpty, true, "the padded tail is empty")

        // An over-long array is truncated.
        let long = scratchDefaults()
        long.set(Array(repeating: slack, count: 20), forKey: "outerSlots")
        expectEqual(OuterRing(defaults: long).slots.count, OuterRing.capacity, "a long array is truncated to `capacity`")

        // Values of the wrong type must not crash the app on launch.
        let wrongType = scratchDefaults()
        wrongType.set("not an array", forKey: "outerSlots")
        let repaired = OuterRing(defaults: wrongType)
        expectEqual(repaired.slots.count, OuterRing.capacity, "a string value is repaired to `capacity` slots")
        expectEqual(repaired.slots.allSatisfy { $0.isEmpty }, true, "the repaired ring is empty")

        let wrongElements = scratchDefaults()
        wrongElements.set([1, 2, 3], forKey: "outerSlots")
        expectEqual(OuterRing(defaults: wrongElements).slots.count, OuterRing.capacity,
                    "an array of numbers is repaired to `capacity` slots")

        // A stored duplicate becomes an empty slot. Keeping both copies would give
        // the user a ring `set` then refuses to rearrange.
        let dupes = scratchDefaults()
        dupes.set([slack, slack, chrome], forKey: "outerSlots")
        let deduped = OuterRing(defaults: dupes)
        expectEqual(deduped.slots[0], slack, "the first copy of a duplicate is kept")
        expectEqual(deduped.slots[1].isEmpty, true, "the second copy becomes an empty slot")
        expectEqual(deduped.slots[2], chrome, "a duplicate does not displace later entries")

        // A relative path resolves against the process's working directory, which
        // is not a stable thing to point a slot at.
        let relative = scratchDefaults()
        relative.set(["Slack.app", "", "/"], forKey: "outerSlots")
        let cleaned = OuterRing(defaults: relative)
        expectEqual(cleaned.slots.allSatisfy { $0.isEmpty }, true,
                    "a relative path and the volume root are both refused")
    }

    suite("outer/repair-write-back") {
        // A repair that stays in memory would be redone on every launch, and the
        // broken value would outlive the app.
        let defaults = scratchDefaults()
        defaults.set([slack, slack, "Slack.app"], forKey: "outerSlots")
        let ring = OuterRing(defaults: defaults)
        expectEqual(defaults.object(forKey: "outerSlots") as? [String] ?? [], ring.slots,
                    "the repaired ring is written back to disk")
        expectEqual((defaults.object(forKey: "outerSlots") as? [String])?.count ?? 0,
                    OuterRing.capacity,
                    "the written-back value has every stored slot")
        // A second launch over the repaired value must find nothing left to fix.
        let again = OuterRing(defaults: defaults)
        expectEqual(again.slots, ring.slots, "the repair is stable across a reload")
    }

    suite("outer/assign") {
        let ring = OuterRing(defaults: scratchDefaults())
        ring.set(slack, at: 0)
        ring.set(chrome, at: 1)
        // In the settings window, choosing an app that is already on the ring
        // means "it belongs here now", so the old slot is vacated rather than the
        // change being refused.
        expectEqual(ring.assign(slack, at: 5), true, "assigning an app already on the ring works")
        expectEqual(ring.slots[5], slack, "the app moved to its new slot")
        expectEqual(ring.slots[0].isEmpty, true, "the slot it came from was cleared")
        expectEqual(ring.slots[1], chrome, "the move disturbed nothing else")
        expectEqual(ring.occupiedPaths.count, 2, "moving an app does not duplicate it")

        // Assigning where it already is must not clear the slot it is in.
        expectEqual(ring.assign(slack, at: 5), true, "assigning the same slot again succeeds")
        expectEqual(ring.slots[5], slack, "the app is still there")

        // Assigning over an occupied slot replaces the occupant.
        expectEqual(ring.assign(teams, at: 1), true, "assigning over an occupied slot works")
        expectEqual(ring.slots[1], teams, "the new app took the slot")
        expectEqual(ring.contains(chrome), false, "the app it displaced is off the ring")

        expectEqual(ring.assign("", at: 2), false, "an empty path is refused")
        expectEqual(ring.assign("Slack.app", at: 2), false, "a relative path is refused")
        expectEqual(ring.assign(slack, at: OuterRing.capacity), false, "an out-of-range index is refused")
        expectEqual(ring.assign(slack, at: -1), false, "a negative index is refused")
        expectEqual(ring.slots[5], slack, "a refused assignment changed nothing")
    }

    suite("outer/replace-all") {
        let defaults = scratchDefaults()
        let ring = OuterRing(defaults: defaults)
        ring.set(teams, at: 7)
        ring.replaceAll([slack, "", chrome])
        expectEqual(ring.slots.count, OuterRing.capacity, "a short list still leaves `capacity` slots")
        expectEqual(ring.slots[0], slack, "the first app takes slot 0")
        expectEqual(ring.slots[1].isEmpty, true, "a gap in the list stays a gap")
        expectEqual(ring.slots[2], chrome, "the order given is the order kept")
        expectEqual(ring.contains(teams), false,
                    "an app the new list omits is gone, not left where it was")

        // Duplicates and rubbish are the settings window's problem to avoid, but
        // the ring must survive them either way.
        ring.replaceAll([slack, slack, "not a path", "/", chrome])
        expectEqual(ring.slots[0], slack, "the first copy survives")
        expectEqual(ring.slots[1].isEmpty, true, "the duplicate is dropped")
        expectEqual(ring.slots[2].isEmpty, true, "a non-path is dropped")
        expectEqual(ring.slots[3].isEmpty, true, "the volume root is dropped")
        expectEqual(ring.slots[4], chrome, "positions after the rubbish are preserved")

        ring.replaceAll(Array(repeating: "/Applications/Fake0.app", count: 30))
        expectEqual(ring.slots.count, OuterRing.capacity, "an over-long list is truncated")

        ring.replaceAll([])
        expectEqual(ring.slots.allSatisfy { $0.isEmpty }, true, "an empty list clears the ring")
        expectEqual(defaults.object(forKey: "outerSlots") as? [String] ?? ["x"],
                    Array(repeating: "", count: OuterRing.capacity), "clearing is persisted")
    }

    suite("outer/change-notification") {
        // The settings window and the wheel both hold the same ring; whichever one
        // changes it, the others have to catch up without knowing who is open.
        let ring = OuterRing(defaults: scratchDefaults())
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: OuterRing.didChangeNotification, object: ring, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        ring.set(slack, at: 0)
        expectEqual(count, 1, "assigning a slot announces the change")
        ring.assign(chrome, at: 1)
        expectEqual(count, 2, "moving an app announces the change")
        ring.assign(teams, at: 2)
        expectEqual(count, 3, "adding a third app announces the change")
        // Removal needs at least four apps to succeed without breaching the floor.
        ring.assign("/Applications/Calendar.app", at: 3)
        expectEqual(count, 4, "adding a fourth app announces the change")
        ring.remove(at: 0)
        expectEqual(count, 5, "removing an app announces the change")
        ring.replaceAll([teams])
        expectEqual(count, 6, "replacing the ring announces the change")
        ring.remove(at: 6)
        expectEqual(count, 6, "removing from an already-empty slot announces nothing")
        ring.set("", at: 3)
        expectEqual(count, 6, "a refused assignment announces nothing")
        ring.reload()
        expectEqual(count, 6, "re-resolving icons is not a change to the ring")
    }

    suite("outer/visible-count") {
        let defaults = scratchDefaults()
        let settings = Settings(defaults: defaults)
        let ring = OuterRing(defaults: defaults)

        expectEqual(ring.visibleCount, Settings.defaultOuterSlots,
                    "the ring starts at the default count")
        expectEqual(ring.slots.count, OuterRing.capacity,
                    "storage is the capacity whatever is shown")

        // Fill the first three visible slots and one that only exists at full size.
        let apps = ["/a.app", "/b.app", "/c.app"]
        for (index, path) in apps.enumerated() { ring.assign(path, at: index) }
        ring.assign("/tail.app", at: OuterRing.capacity - 1)

        // The smallest the ring is allowed to be, so the assertions below are about
        // the clamp's own boundary rather than a value inside the range.
        settings.outerSlotCount = Settings.minOuterSlots
        expectEqual(ring.visibleCount, Settings.minOuterSlots, "the count follows the setting")
        expectEqual(ring.occupiedPaths, apps, "only the visible slots are on the ring")
        expectEqual(ring.isFull, false, "three apps do not fill four visible slots")
        expectEqual(ring.firstEmpty, 3, "the fourth slot is the free one")
        ring.assign("/d.app", at: 3)
        expectEqual(ring.isFull, true, "four of four visible slots is full")
        expect(ring.firstEmpty == nil, "a full visible ring has no free slot")
        // The hidden app has not been touched, and must not be added a second time.
        expectEqual(ring.contains("/tail.app"), true,
                    "an app parked in a hidden slot is still on file")
        expect(ring.addToFirstEmpty("/tail.app") == nil,
               "an app already stored is not added again")
        expect(ring.addToFirstEmpty("/new.app") == nil,
               "nothing fits while the visible slots are full")

        settings.outerSlotCount = Settings.maxOuterSlots
        expectEqual(ring.slots[OuterRing.capacity - 1], "/tail.app",
                    "turning the count back up brings the hidden app back")
        expectEqual(ring.isFull, false, "the wider ring has room again")
        expectEqual(ring.firstEmpty, 4, "the next free slot is the first empty one")

        // Out-of-range settings must not produce a range that traps.
        settings.outerSlotCount = 99
        expectEqual(ring.visibleCount, Settings.maxOuterSlots, "an absurd count is clamped")
        expect(ring.visibleRange.upperBound <= ring.slots.count,
               "the visible range never runs past storage")
        settings.outerSlotCount = -5
        expectEqual(ring.visibleCount, Settings.minOuterSlots, "a negative count is clamped")
        expectEqual(ring.occupiedPaths.count, Settings.minOuterSlots,
                    "only the slots still visible are reported")
    }

    suite("outer/three-app-floor") {
        // No `Settings` binding here: nothing in this suite reads one, and every build
        // script runs with -warnings-as-errors, so an unused `let` is a build failure.
        let ring = OuterRing(defaults: scratchDefaults())

        expectEqual(Settings.minOuterApps, 3, "the floor is three apps")

        // Four apps: one may go, and then no more.
        for (index, path) in ["/a.app", "/b.app", "/c.app", "/d.app"].enumerated() {
            ring.assign(path, at: index)
        }
        expectEqual(ring.occupiedCount, 4, "four apps are on the ring")
        expectEqual(ring.canRemove(at: 3), true, "the fourth app may be removed")
        expectEqual(ring.remove(at: 3), true, "removing the fourth app succeeds")
        expectEqual(ring.occupiedCount, 3, "three apps are left")

        expectEqual(ring.canRemove(at: 2), false, "the third app may not be removed")
        expectEqual(ring.remove(at: 2), false, "removing the third app is refused")
        expectEqual(ring.occupiedCount, 3, "the refused removal changed nothing")
        expectEqual(ring.slots[2], "/c.app", "the refused slot still holds its app")

        // Replacing is never refused, which is the escape from the floor.
        expectEqual(ring.set("/e.app", at: 2), true, "a slot at the floor can be replaced")
        expectEqual(ring.occupiedCount, 3, "replacing does not change the count")

        // An empty slot is not removable, and neither is one out of range.
        expectEqual(ring.canRemove(at: 3), false, "an empty slot cannot be removed")
        expectEqual(ring.canRemove(at: -1), false, "a negative index cannot be removed")
        expectEqual(ring.canRemove(at: OuterRing.capacity), false,
                    "an index past capacity cannot be removed")

        // A ring already below the floor still refuses, because allowing it is how a
        // ring reaches zero.
        let sparseDefaults = scratchDefaults()
        let sparse = OuterRing(defaults: sparseDefaults)
        sparse.assign("/a.app", at: 0)
        sparse.assign("/b.app", at: 1)
        expectEqual(sparse.occupiedCount, 2, "two apps on the ring")
        expectEqual(sparse.canRemove(at: 1), false,
                    "a ring below the floor still refuses a removal")
        expectEqual(sparse.set("/c.app", at: 1), true,
                    "but replacing still works, so a mistake is fixable")

        // A slot hidden by a low slot count is not on the wheel, so it may be emptied
        // even when the visible ring is at the floor.
        //
        // The layout matters. `minOuterSlots` is 4, so the narrowest visible ring is
        // four slots; filling all four would give an occupied count of 4, and removing
        // one of those would leave 3, which the floor permits. To put the VISIBLE ring
        // exactly at the floor the apps have to sit at 0, 1, 2 and 4 — three visible,
        // one parked out of sight.
        let hiddenDefaults = scratchDefaults()
        let hiddenSettings = Settings(defaults: hiddenDefaults)
        let hiddenRing = OuterRing(defaults: hiddenDefaults)
        for index in [0, 1, 2, 4] { hiddenRing.assign("/app\(index).app", at: index) }
        hiddenSettings.outerSlotCount = Settings.minOuterSlots
        expectEqual(hiddenRing.occupiedCount, 3, "only the visible slots count")
        expectEqual(hiddenRing.canRemove(at: 4), true,
                    "a hidden slot may be emptied, since it is not on the wheel")
        expectEqual(hiddenRing.canRemove(at: 0), false,
                    "a visible slot may not, because the visible ring is at the floor")
        // And with one more app visible, the same slot becomes removable again.
        hiddenSettings.outerSlotCount = 5
        expectEqual(hiddenRing.occupiedCount, 4, "raising the count reveals the fourth app")
        expectEqual(hiddenRing.canRemove(at: 0), true,
                    "four visible apps means one may go")
    }

    suite("outer/assign-swaps-rather-than-clears") {
        // `assign` used to clear whichever other slot held the app. Moving an app onto
        // an occupied slot therefore lost an app: it broke the three-app floor, and it
        // silently discarded whatever the user was displacing.
        let ring = OuterRing(defaults: scratchDefaults())
        ring.assign("/a.app", at: 0)
        ring.assign("/b.app", at: 1)
        ring.assign("/c.app", at: 2)
        expectEqual(ring.occupiedCount, 3, "three apps to start")

        expectEqual(ring.assign("/a.app", at: 2), true, "moving A onto C's slot succeeds")
        expectEqual(ring.occupiedCount, 3, "the count is unchanged by a move")
        expectEqual(ring.slots[2], "/a.app", "A is where it was dropped")
        expectEqual(ring.slots[0], "/c.app", "C took A's old slot rather than vanishing")
        expectEqual(ring.slots[1], "/b.app", "B was not touched")

        // Moving onto an empty slot still just moves, leaving the old slot empty.
        expectEqual(ring.assign("/b.app", at: 5), true, "moving B to an empty slot succeeds")
        expectEqual(ring.slots[1], "", "B's old slot is empty")
        expectEqual(ring.slots[5], "/b.app", "B is in its new slot")

        // Assigning an app to the slot it already occupies is a no-op, not a swap
        // with itself.
        expectEqual(ring.assign("/a.app", at: 2), true, "assigning in place succeeds")
        expectEqual(ring.slots[2], "/a.app", "and leaves the app where it was")
        expectEqual(ring.occupiedCount, 3, "with the count unchanged")
    }

    suite("outer/slot-count-cannot-hide-below-the-floor") {
        // Lowering the slot count deletes nothing, but it can put apps out of reach,
        // which leaves the user with a wheel of fewer than three apps just the same.
        let defaults = scratchDefaults()
        let settings = Settings(defaults: defaults)
        let ring = OuterRing(defaults: defaults)
        // Apps clustered at the far end of the ring: slots 0, 5, 6, 7.
        ring.assign("/a.app", at: 0)
        ring.assign("/b.app", at: 5)
        ring.assign("/c.app", at: 6)
        ring.assign("/d.app", at: 7)
        settings.outerSlotCount = 8
        expectEqual(ring.occupiedCount, 4, "four apps are reachable at eight slots")

        expectEqual(ring.canSetVisibleCount(to: 8), true, "staying put is allowed")
        expectEqual(ring.canSetVisibleCount(to: 10), true, "widening is always allowed")
        expectEqual(ring.canSetVisibleCount(to: 7), true,
                    "seven slots still reach three apps")
        expectEqual(ring.canSetVisibleCount(to: 6), false,
                    "six slots would reach only two apps")
        expectEqual(ring.canSetVisibleCount(to: 4), false,
                    "four slots would reach only one app")

        // A ring that is already below the floor must not freeze the slider: hiding
        // empty slots takes nothing away.
        let sparseDefaults = scratchDefaults()
        let sparseRing = OuterRing(defaults: sparseDefaults)
        sparseRing.assign("/a.app", at: 0)
        expectEqual(sparseRing.canSetVisibleCount(to: Settings.minOuterSlots), true,
                    "hiding empty slots is allowed even below the floor")

        // Out-of-range requests are judged on the value that would actually be stored.
        expectEqual(ring.canSetVisibleCount(to: 99), true, "an absurd widening is allowed")
        expectEqual(ring.canSetVisibleCount(to: -5), false,
                    "an absurd narrowing is judged as the clamped minimum")
    }
}

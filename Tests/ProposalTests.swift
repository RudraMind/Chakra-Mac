import Foundation

/// The candidate filter is asked about paths that do not exist on this machine, so
/// eligibility is stubbed. What is under test is which candidates survive and in
/// what order, not whether an app is installed.
private let anything: (String) -> Bool = { _ in true }

private func tile(_ raw: String) -> [String: Any] {
    ["tile-data": ["file-data": ["_CFURLString": raw, "_CFURLStringType": 15]]]
}

func runProposalTests() {
    suite("proposal/order") {
        let out = RingProposal.compute(dock: ["/Applications/A.app", "/Applications/B.app"],
                                       spotlight: ["/Applications/C.app"],
                                       pinned: [], selfPath: "/Applications/Chakra.app",
                                       freeSlots: 8, isEligible: anything)
        expectEqual(out, ["/Applications/A.app", "/Applications/B.app", "/Applications/C.app"],
                    "the Dock comes first, then recency")
    }

    suite("proposal/free-slots") {
        // Every app offered must have a slot to go into. Proposing more than will
        // fit is what used to leave the last rows of the confirmation list doing
        // nothing at all.
        let out = RingProposal.compute(dock: (1...9).map { "/Applications/A\($0).app" },
                                       spotlight: [], pinned: [], selfPath: "/x.app",
                                       freeSlots: 3, isEligible: anything)
        expectEqual(out.count, 3, "the proposal is capped at the number of empty slots")
        expectEqual(out.first, "/Applications/A1.app", "the cap keeps the highest-ranked apps")
        expectEqual(RingProposal.compute(dock: ["/Applications/A.app"], spotlight: [],
                                         pinned: [], selfPath: "/x.app", freeSlots: 0,
                                         isEligible: anything),
                    [], "a full ring proposes nothing")
        expectEqual(RingProposal.compute(dock: ["/Applications/A.app"], spotlight: [],
                                         pinned: [], selfPath: "/x.app", freeSlots: -1,
                                         isEligible: anything),
                    [], "a negative slot count proposes nothing")
    }

    suite("proposal/exclusions") {
        // An app already on the ring cannot be added a second time, so offering it
        // would mean a row the user confirms and nothing happens.
        let pinned = RingProposal.compute(dock: ["/Applications/A.app", "/Applications/B.app"],
                                          spotlight: [], pinned: ["/Applications/A.app/"],
                                          selfPath: "/x.app", freeSlots: 8,
                                          isEligible: anything)
        expectEqual(pinned, ["/Applications/B.app"],
                    "an app already on the ring is not proposed, trailing slash and all")

        let mine = RingProposal.compute(dock: ["/Applications/Chakra.app"], spotlight: [],
                                        pinned: [], selfPath: "/Applications/Chakra.app",
                                        freeSlots: 8, isEligible: anything)
        expectEqual(mine, [], "Chakra never proposes itself")

        let boring = RingProposal.compute(
            dock: ["/System/Library/CoreServices/Finder.app",
                   "/System/Applications/Launchpad.app",
                   "/Applications/Chakra.app",
                   "/Applications/Real.app"],
            spotlight: [], pinned: [], selfPath: "/elsewhere/Chakra.app", freeSlots: 8,
            isEligible: anything)
        expectEqual(boring, ["/Applications/Real.app"],
                    "apps that are always there are not worth a fixed slot")

        let dupes = RingProposal.compute(dock: ["/Applications/A.app", "/Applications/A.app/"],
                                         spotlight: ["/Applications/A.app"], pinned: [],
                                         selfPath: "/x.app", freeSlots: 8, isEligible: anything)
        expectEqual(dupes, ["/Applications/A.app"], "the same app is proposed only once")

        let blank = RingProposal.compute(dock: ["", "  ", "/Applications/A.app"], spotlight: [],
                                         pinned: [""], selfPath: "", freeSlots: 8,
                                         isEligible: anything)
        expectEqual(blank.contains(""), false, "an empty path is never proposed")
        expectEqual(blank.contains("/Applications/A.app"), true,
                    "an empty pinned entry does not block everything")

        let ineligible = RingProposal.compute(dock: ["/Applications/A.app"], spotlight: [],
                                              pinned: [], selfPath: "/x.app", freeSlots: 8,
                                              isEligible: { _ in false })
        expectEqual(ineligible, [], "an app the eligibility rule rejects is not proposed")
    }

    suite("proposal/dock-parsing") {
        // The Dock's own preference format. It has changed before, so anything
        // shaped unexpectedly has to be skipped rather than crash a first launch.
        // The Dock stores a directory URL, whose trailing slash `URL.path` drops.
        expectEqual(RingProposal.parse(tiles: [tile("file:///Applications/Slack.app/")]),
                    ["/Applications/Slack.app"], "a file URL is turned back into a path")
        expectEqual(RingProposal.parse(tiles: [tile("/Applications/Slack.app")]),
                    ["/Applications/Slack.app"], "a bare path is taken as it is")
        expectEqual(RingProposal.parse(tiles: [tile("file:///Applications/Google%20Chrome.app/")]),
                    ["/Applications/Google Chrome.app"], "a percent-escaped space is decoded")
        expectEqual(RingProposal.parse(tiles: [tile("/Users/me/Documents")]), [],
                    "a folder in the Dock is not an app")
        expectEqual(RingProposal.parse(tiles: [tile("")]), [], "an empty entry is skipped")
        expectEqual(RingProposal.parse(tiles: [[:]]), [], "a tile with no data is skipped")
        expectEqual(RingProposal.parse(tiles: [["tile-data": "wrong type"]]), [],
                    "a tile whose data is not a dictionary is skipped")
        expectEqual(RingProposal.parse(tiles: [["tile-data": ["file-data": [String: Any]()]]]), [],
                    "a tile with no URL is skipped")
        expectEqual(RingProposal.parse(tiles: [tile("/A.app"), [:], tile("/B.app")]),
                    ["/A.app", "/B.app"], "one bad tile does not lose the good ones")

        // Reading the real Dock must never throw or hang, whatever is in it.
        let real = RingProposal.dockApps()
        expectEqual(real.allSatisfy { $0.hasSuffix(".app") || $0.hasSuffix(".app/") }, true,
                    "every path read from the real Dock is an app bundle")
    }
}

// `AppKit` for `NSPasteboard`, which the scratch-pasteboard registry below hands back. Not a UI
// object and needs no window server, so the binary still runs without one.
import AppKit
import Foundation

// A dependency-free assertion harness. XCTest needs an Xcode test bundle, and
// this project builds with bare swiftc, so the tests are just a binary that
// exits non-zero when something is wrong.

var failures: [String] = []
var checks = 0
var currentSuite = ""

func expect(_ condition: Bool, _ label: String, line: UInt = #line) {
    checks += 1
    if !condition { failures.append("[\(currentSuite)] \(label)  (line \(line))") }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String, line: UInt = #line) {
    checks += 1
    if got != want {
        failures.append("[\(currentSuite)] \(label): got \(got), want \(want)  (line \(line))")
    }
}

func expectClose(_ got: CGFloat, _ want: CGFloat, _ label: String,
                 tolerance: CGFloat = 0.001, line: UInt = #line) {
    checks += 1
    if abs(got - want) > tolerance {
        failures.append("[\(currentSuite)] \(label): got \(got), want \(want)  (line \(line))")
    }
}

func expectPoint(_ got: CGPoint, _ want: CGPoint, _ label: String,
                 tolerance: CGFloat = 0.001, line: UInt = #line) {
    checks += 1
    if abs(got.x - want.x) > tolerance || abs(got.y - want.y) > tolerance {
        failures.append("[\(currentSuite)] \(label): got \(got), want \(want)  (line \(line))")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    currentSuite = name
    body()
}

// MARK: - Scratch preference domains

/// Every scratch defaults domain the tests have created.
///
/// The suites deliberately never touch the user's real preferences, so each one asks for
/// a throwaway domain of its own. Those domains used to be cleared on the way in but never
/// on the way out, which left one small plist per suite sitting in `~/Library/Preferences`
/// — 52 of them by the time anyone looked. Harmless, but it is litter in a directory the
/// tests do not own, and it made the user's own `local.chakra.plist` hard to find by hand.
private var scratchDomains: [String] = []

/// Records a scratch domain so `removeScratchDomains()` can bin it at the end of the run.
func registerScratchDomain(_ name: String) {
    scratchDomains.append(name)
}

/// Deletes every scratch domain the run created.
///
/// Called from `main()` before it exits, on both the passing and the failing path: a failed
/// run is exactly when someone is most likely to go looking in that directory by hand.
func removeScratchDomains() {
    let defaults = UserDefaults()
    for name in scratchDomains { defaults.removePersistentDomain(forName: name) }
    scratchDomains.removeAll()
}

// MARK: - Scratch directories

/// Every throwaway directory the tests have created.
///
/// The same discipline as `scratchDomains`: a test that leaves directories behind is
/// littering somewhere it does not own, and `/tmp` fills up over a long session.
private var scratchDirectories: [URL] = []

/// A fresh empty directory under the system temporary directory, removed at the end of
/// the run. `label` only exists to make a stray directory identifiable if a crash skips
/// the cleanup.
func scratchDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chakra-test-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    scratchDirectories.append(url)
    return url
}

// MARK: - Scratch pasteboards

/// Every private pasteboard the tests have created.
///
/// The same discipline as `scratchDomains` and `scratchDirectories`, and for a sharper reason:
/// `NSPasteboard.Name` is **machine-global** and a named board outlives the process until it is
/// released. Measured across 4,000 trials per process, with a fixed name and two test binaries
/// running at once: `setData` returned false 627 times and a read came back nil 1,116 times, against
/// 0 and 0 solo — the pasteboard suites failed 10 runs in 30 under six-way process load and never
/// once solo. So every board carries a UUID and is handed back here.
private var scratchBoards: [NSPasteboard] = []

/// Records a private pasteboard so `releaseScratchBoards()` can hand it back at the end of the run.
func registerScratchBoard(_ board: NSPasteboard) {
    scratchBoards.append(board)
}

/// Releases every private pasteboard the run created.
func releaseScratchBoards() {
    for board in scratchBoards { board.releaseGlobally() }
    scratchBoards.removeAll()
}

/// Deletes every scratch directory the run created.
func removeScratchDirectories() {
    for url in scratchDirectories {
        _ = try? FileManager.default.removeItem(at: url)
    }
    scratchDirectories.removeAll()
}

@main
struct TestMain {
    static func main() {
        runGeometryTests()
        runOrbPlacementTests()
        runOrbGeometryTests()
        runModelTests()
        runOuterRingTests()
        runRecentsTests()
        runSettingsTests()
        runProposalTests()
        runShortcutTests()
        runShelfNameTests()
        runShelfIntakeTests()
        runShelfTests()

        // Before either exit, so a failing run leaves the directory as clean as a passing one.
        removeScratchDomains()
        removeScratchDirectories()
        // Named pasteboards are machine-global and outlive the process until released, so the
        // shelf suites' private boards are handed back for the same reason the domains are.
        releaseScratchBoards()

        if failures.isEmpty {
            print("✓ \(checks) checks passed")
            exit(0)
        }
        print("✗ \(failures.count) of \(checks) checks failed\n")
        for f in failures { print("  " + f) }
        exit(1)
    }
}

#!/bin/bash
# Runs the pure-logic test binary.
#
# There is no XCTest here on purpose: XCTest needs a test bundle and a runner,
# which needs Xcode. Instead the tests are their own executable that links only
# the files with no UI in them. Sources/main.swift is excluded because top-level
# code cannot coexist with the tests' @main.
set -euo pipefail

cd "$(dirname "$0")"

BIN="build/chakra-tests"
mkdir -p build
# Never let a stale binary from a previous run stand in for a build that just
# failed to compile.
rm -f "$BIN"

swiftc \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -warnings-as-errors \
  -o "$BIN" \
  Sources/Geometry.swift \
  Sources/OrbPlacement.swift \
  Sources/OrbGeometry.swift \
  Sources/Models.swift \
  Sources/Shortcut.swift \
  Sources/HotKey.swift \
  Sources/Defaults.swift \
  Sources/OuterRing.swift \
  Sources/Recents.swift \
  Sources/Proposal.swift \
  Sources/Shelf.swift \
  Sources/ShelfName.swift \
  Sources/ShelfIntake.swift \
  Tests/TestMain.swift \
  Tests/GeometryTests.swift \
  Tests/OrbPlacementTests.swift \
  Tests/OrbGeometryTests.swift \
  Tests/ModelTests.swift \
  Tests/OuterRingTests.swift \
  Tests/RecentsTests.swift \
  Tests/SettingsTests.swift \
  Tests/ProposalTests.swift \
  Tests/ShortcutTests.swift \
  Tests/ShelfTests.swift \
  Tests/ShelfNameTests.swift \
  Tests/ShelfIntakeTests.swift

# The scratch preference domains are emptied by the test binary itself, but an empty plist
# is still left behind in ~/Library/Preferences: merely asking `UserDefaults(suiteName:)`
# for a domain creates the file, so nothing inside the process can stop it existing. The
# files can only be removed once nothing is asking for them, which means after the binary
# has exited — hence here rather than in the test code.
#
# The exit status is preserved deliberately: a failing run must still fail the script, and
# the cleanup has to happen on the failing path too.
set +e
"$BIN"
status=$?
set -e

# `rm` alone is not enough. macOS keeps preference domains cached in `cfprefsd`, which
# rewrites the file from that cache later — deleting only the file means the next process to
# touch preferences brings all of them back. `defaults delete` goes through `cfprefsd` and
# makes it forget the domain, so the removal sticks.
#
# The `.tests.` infix is what keeps this off the user's own `local.chakra.plist`.
for plist in "$HOME/Library/Preferences/local.chakra.tests."*.plist; do
  [ -e "$plist" ] || continue
  domain="$(basename "$plist" .plist)"
  defaults delete "$domain" 2>/dev/null || true
  rm -f "$plist"
done

exit $status

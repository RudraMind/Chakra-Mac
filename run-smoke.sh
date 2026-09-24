#!/bin/bash
# Builds and runs the AppKit smoke test: constructs the real windows and fires
# the real target-action of every control in them.
#
# Separate from run-tests.sh because this one links AppKit and puts windows
# together, so it is slower and needs a window server. run-tests.sh stays a pure
# logic run that works anywhere.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build
rm -f build/chakra-smoke

swiftc \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -warnings-as-errors \
  -o build/chakra-smoke \
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
  Sources/WheelView.swift \
  Sources/OrbView.swift \
  Sources/OrbController.swift \
  Sources/WheelWindow.swift \
  Sources/StatusItem.swift \
  Sources/SettingsWindow.swift \
  Sources/Onboarding.swift \
  Tools/Smoke.swift

# Same as run-tests.sh: the smoke tool already calls `removePersistentDomain` on each of its
# scratch domains, but an empty plist is still left in ~/Library/Preferences because asking
# for a named domain is itself what creates the file. Removed here, after the process is
# gone, with the exit status preserved so a failing smoke run still fails the script.
set +e
./build/chakra-smoke
status=$?
set -e

# `defaults delete` as well as `rm`, for the reason spelled out in run-tests.sh: `cfprefsd`
# caches the domain and rewrites the file from that cache if only the file is removed.
#
# The `.smoke` infix keeps this off the user's own `local.chakra.plist`.
for plist in "$HOME/Library/Preferences/local.chakra.smoke"*.plist; do
  [ -e "$plist" ] || continue
  domain="$(basename "$plist" .plist)"
  defaults delete "$domain" 2>/dev/null || true
  rm -f "$plist"
done

exit $status

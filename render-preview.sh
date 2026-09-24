#!/bin/bash
# Renders the wheel to build/preview-*.png without opening a window.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build
rm -f build/chakra-preview

swiftc \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -warnings-as-errors \
  -o build/chakra-preview \
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
  Sources/WheelView.swift \
  Sources/OrbView.swift \
  Sources/OrbController.swift \
  Sources/WheelWindow.swift \
  Sources/StatusItem.swift \
  Sources/SettingsWindow.swift \
  Sources/Onboarding.swift \
  Tools/Preview.swift

./build/chakra-preview build

#!/bin/bash
# Builds Chakra.app with nothing but the Swift compiler: no Xcode project, no
# SwiftPM, no dependencies.
#
#   ./build.sh            build into ./build/Chakra.app
#   ./build.sh --install  build, then replace /Applications/Chakra.app
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Chakra.app"
BIN="$APP/Contents/MacOS/Chakra"

SOURCES=(
  Sources/Geometry.swift
  Sources/OrbPlacement.swift
  Sources/OrbGeometry.swift
  Sources/Models.swift
  Sources/Shortcut.swift
  Sources/HotKey.swift
  Sources/Defaults.swift
  Sources/OuterRing.swift
  Sources/Recents.swift
  Sources/Proposal.swift
  Sources/Shelf.swift
  Sources/ShelfName.swift
  Sources/ShelfIntake.swift
  Sources/WheelView.swift
  Sources/OrbView.swift
  Sources/OrbController.swift
  Sources/WheelWindow.swift
  Sources/StatusItem.swift
  Sources/SettingsWindow.swift
  Sources/Onboarding.swift
  Sources/main.swift
)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal, because Info.plist advertises macOS 14 as the minimum and macOS 14
# still runs on Intel Macs. An arm64-only binary in a bundle making that promise
# simply fails to launch there.
#
# -warnings-as-errors: the ring is small enough that no warning is acceptable.
# The deployment target is deliberately older than the SDK so that using an API
# newer than macOS 14 is a compile error rather than a crash on someone's Mac.
SLICES=()
for arch in arm64 x86_64; do
  swiftc \
    -swift-version 5 \
    -target "$arch-apple-macos14.0" \
    -O \
    -warnings-as-errors \
    -o "build/Chakra-$arch" \
    "${SOURCES[@]}"
  SLICES+=("build/Chakra-$arch")
done
lipo -create -output "$BIN" "${SLICES[@]}"
rm -f "${SLICES[@]}"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is generated, not committed. Rebuild it when it is missing or older
# than the code that draws it, so a build never quietly ships a stale icon — and
# never pays for iconutil when nothing has changed.
if [[ ! -f Resources/Chakra.icns || Tools/MakeIcon.swift -nt Resources/Chakra.icns ]]; then
  ./make-icon.sh
fi
cp Resources/Chakra.icns "$APP/Contents/Resources/Chakra.icns"

# Ad-hoc signature: enough for macOS to load the bundle and for SMAppService to
# accept it at all.
#
# It does NOT give a stable identity. An ad-hoc signature has no signing identity,
# so its designated requirement is a bare cdhash, which changes on every
# recompile. macOS therefore treats each build as a different program, and an
# "Open at login" registration made by an earlier build drops back to needing the
# user's approval. Settings says so when that happens. A real Developer ID is the
# only fix, and this project deliberately has no signing identity to require one.
codesign --force --sign - "$APP" >/dev/null 2>&1 || \
  echo "warning: could not ad-hoc sign the bundle"

echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # pkill rather than AppleScript: telling another app to quit through
  # AppleScript would trigger an Automation permission prompt, and Chakra's whole
  # premise is that it never asks for one.
  pkill -x Chakra >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Chakra.app
  cp -R "$APP" /Applications/Chakra.app
  echo "installed /Applications/Chakra.app"
fi

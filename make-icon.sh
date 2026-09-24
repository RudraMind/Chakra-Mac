#!/bin/bash
# Renders Resources/Chakra.icns from Tools/MakeIcon.swift.
#
# The icon is generated rather than committed as a binary: iconutil ships with
# macOS, so the whole thing stays inside the repository as readable code.
set -euo pipefail

cd "$(dirname "$0")"

ICONSET="build/Chakra.iconset"
OUT="Resources/Chakra.icns"

mkdir -p build Resources
rm -rf "$ICONSET" build/chakra-makeicon

# -parse-as-library: a lone Swift file is otherwise treated as top-level code,
# which cannot coexist with the @main attribute.
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -warnings-as-errors \
  -parse-as-library \
  -o build/chakra-makeicon \
  Tools/MakeIcon.swift

./build/chakra-makeicon "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$OUT"
echo "wrote $OUT"

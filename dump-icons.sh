#!/bin/bash
# Dumps application icons for the HTML design mockups.
#
# The mockups need the real icons so they show the colours the app will actually draw.
# Output goes to /tmp by default because it is regenerable and large; the mockup
# scripts call this themselves when the directory is missing, which is what makes them
# rebuildable from a fresh checkout.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build

# Tools/DumpIcons.swift is deliberately absent from build.sh's source list: it has its
# own @main and cannot be linked into the app.
#
# -parse-as-library is required because this is a single-file compile. swiftc otherwise
# treats the only file as a script and allows top-level code in it, which cannot coexist
# with @main. The other tools escape this by being compiled alongside the app's sources.
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -O \
  -warnings-as-errors \
  -parse-as-library \
  -o build/chakra-dumpicons \
  Tools/DumpIcons.swift

./build/chakra-dumpicons "${1:-/tmp/chakra-icons}"

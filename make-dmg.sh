#!/bin/bash
# Packages build/Chakra.app into a downloadable disk image.
#
# The image contains the app and a shortcut to /Applications, so the whole
# install is one drag. Nothing here needs a third-party tool: hdiutil ships
# with macOS, which is why this can also run on a clean CI runner.
#
# Deliberately plain — no background art and no icon positioning. Both of those
# require either an AppleScript conversation with Finder (which prompts for
# Automation on whatever machine runs the build, so it cannot run headlessly) or
# a hand-arranged .DS_Store committed to the repository. Neither cost is worth
# paying for decoration.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Chakra.app"

if [ ! -d "$APP" ]; then
  echo "error: $APP does not exist." >&2
  echo "       Run ./build.sh first." >&2
  exit 1
fi

# The file name is deliberately versionless — Chakra.dmg, every release — so the
# download link never changes.
#
# The trade-off, stated because it is real: three downloads leave a Downloads
# folder holding Chakra.dmg, Chakra-1.dmg and Chakra-2.dmg with no way to tell
# them apart. That is mitigated, not solved, by putting the version in the
# VOLUME name instead: mounting the image shows "Chakra 1.0" in the window title,
# so an old copy can still be identified. It is also recorded in the .sha256
# sidecar written at the end.

# Both of these are guarded explicitly because PlistBuddy's own failure text is
# actively misleading: with Info.plist absent entirely it still reports
#   Print: Entry, ":CFBundleShortVersionString", Does Not Exist
# which blames a missing key for a missing file, and sends whoever hits it
# looking in the wrong place.
if [ ! -f Info.plist ]; then
  echo "error: Info.plist not found in $(pwd)." >&2
  echo "       Run this script from the repository root." >&2
  exit 1
fi

if ! VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null); then
  echo "error: Info.plist has no CFBundleShortVersionString key." >&2
  echo "       The disk image takes its volume name from that value, so it cannot" >&2
  echo "       be built without one. Add it to Info.plist, e.g.:" >&2
  echo "         <key>CFBundleShortVersionString</key><string>1.0</string>" >&2
  exit 1
fi

if [ -z "$VERSION" ]; then
  echo "error: CFBundleShortVersionString in Info.plist is empty." >&2
  exit 1
fi

DMG="build/Chakra.dmg"
VOLUME="Chakra $VERSION"

# A volume left mounted from an interrupted earlier run makes hdiutil fail with
# "resource busy", which reads as a permissions problem and is not one.
if [ -d "/Volumes/$VOLUME" ]; then
  echo "detaching a stale mount at /Volumes/$VOLUME"
  hdiutil detach "/Volumes/$VOLUME" -quiet || true
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"

# UDZO is zlib-compressed and read-only. Read-only matters: a writable image
# would let a user modify the app in place and then wonder why the signature
# no longer matched.
hdiutil create \
  -volname "$VOLUME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -quiet \
  "$DMG"

# Verify the image is readable rather than trusting that create succeeded. An
# image that cannot be mounted is worse than no image, because the failure only
# appears on the user's machine.
hdiutil verify "$DMG" -quiet

# NOTE: disk images are NOT byte-reproducible. Two builds of an identical app
# produce different checksums, because the image records creation timestamps.
# Measured: the same Chakra.app packaged twice gave 710625…  then  cc4ae1… .
#
# Consequences worth knowing:
#   - Never hardcode a checksum in a document. Publish the one computed at
#     release time; release.yml reads it from this step's output.
#   - A checksum mismatch between two locally built images means nothing. Only a
#     mismatch against the checksum published alongside a specific download is
#     evidence of a problem.
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
# The version goes in the sidecar because it is not in the file name. Without it
# a loose checksum file cannot be matched to a release.
{
  echo "$SHA  $(basename "$DMG")"
  echo "version $VERSION"
} > "$DMG.sha256"

SIZE=$(du -h "$DMG" | cut -f1)

echo "built $DMG  ($SIZE)  volume name: $VOLUME"
echo "sha256 $SHA"
echo
echo "Reminder: this image is ad-hoc signed, not notarized. macOS will block the"
echo "first launch. The install instructions in README.md explain how to proceed."

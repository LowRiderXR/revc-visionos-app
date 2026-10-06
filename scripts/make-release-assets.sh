#!/bin/bash
# make-release-assets.sh -- maintainer script: pack the prebuilt binaries currently in
# ThirdParty/ into release assets with a SHA256SUMS file, ready to attach to a GitHub
# release. setup.sh downloads exactly these names.
#
# Usage: scripts/make-release-assets.sh [out-dir]   (default: ./release-assets)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/release-assets}"
THIRD="$HERE/ThirdParty"
mkdir -p "$OUT"
rm -f "$OUT"/*.zip "$OUT"/*.a "$OUT/SHA256SUMS" "$OUT"/*.md

for z in ANGLE_libEGL ANGLE_libGLESv2; do
  [ -d "$THIRD/ANGLE/$z.xcframework" ] || { echo "missing $THIRD/ANGLE/$z.xcframework" >&2; exit 1; }
  ( cd "$THIRD/ANGLE" && zip -q -r -X "$OUT/$z.xcframework.zip" "$z.xcframework" -x "*/.DS_Store" )
done
cp "$THIRD/openal-soft/lib/libopenal.a" "$THIRD/openal-soft/lib/libalsoft.fmt.a" "$OUT/"
cp "$HERE/THIRD_PARTY_NOTICES.md" "$HERE/LICENSE" "$OUT/"
( cd "$OUT" && shasum -a 256 ANGLE_libEGL.xcframework.zip ANGLE_libGLESv2.xcframework.zip libopenal.a libalsoft.fmt.a > SHA256SUMS )

echo "release assets in $OUT:"
ls -la "$OUT"
echo
cat "$OUT/SHA256SUMS"
echo
echo "Provenance to put in the release notes:"
echo "  ANGLE   : chromium angle @ e4499e6b2835a6996507f1b99920bc56f0122573 + visionos-angle-kit patches (klepton, angle-metal-fixes, multiview-stage2..5)"
echo "  OpenAL  : kcat/openal-soft @ 75a0d1beb33fc4b28a6262f737d764167c216a44 + ThirdParty/openal-soft/0001-*.patch (see BUILD.md)"

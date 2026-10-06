#!/bin/bash
# setup.sh -- prepare a fresh checkout of revc-visionos-app for building in Xcode.
#
#   1. clones the engine repo (revc-visionos + submodules) as a SIBLING of this repo,
#   2. downloads the prebuilt binaries (ANGLE xcframeworks, OpenAL Soft archives) from the
#      GitHub release and verifies their SHA-256 sums,
#   3. places everything where the Xcode project expects it.
#
# Expected layout afterwards (the Xcode project uses relative paths, nothing else works):
#
#   <root>/
#     AvpViceCity/                  this repo (revc-visionos-app)
#       ThirdParty/ANGLE/*.xcframework
#       ThirdParty/openal-soft/lib/*.a
#     Source/reVC/                  revc-visionos (+ vendor/librw, ogg, opus, opusfile)
#
# Usage:  ./setup.sh [--tag vX.Y] [--check]
#   --tag    release tag (default DEFAULT_TAG below). The SAME tag exists in all four repos;
#            the engine is checked out at this tag so the sources match the binaries of the
#            release (librw and the other submodules are pinned by the engine commit).
#   --check  only verify the layout and checksums, download/clone nothing
set -euo pipefail

DEFAULT_TAG="v1.0-rc1"      # <- bump for the next release (same tag in all four repos)
APP_REPO="LowRiderXR/revc-visionos-app"
ENGINE_REPO="https://github.com/LowRiderXR/revc-visionos.git"
ASSETS=(ANGLE_libEGL.xcframework.zip ANGLE_libGLESv2.xcframework.zip libopenal.a libalsoft.fmt.a)

TAG="$DEFAULT_TAG"; CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENGINE="$ROOT/Source/reVC"
THIRD="$HERE/ThirdParty"
BASE_URL="https://github.com/$APP_REPO/releases/download/$TAG"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

echo "reVC for visionOS -- setup (release $TAG)"
echo "root: $ROOT"

# --- 1. toolchain -------------------------------------------------------------------
if command -v xcodebuild >/dev/null 2>&1; then
  XV=$(xcodebuild -version 2>/dev/null | head -1)
  MAJOR=$(echo "$XV" | sed -E 's/Xcode ([0-9]+).*/\1/')
  if [ "${MAJOR:-0}" -ge 27 ]; then ok "$XV"; else warn "$XV found, Xcode 27 or newer is required (visionOS 26.5 SDK)"; fi
else
  warn "xcodebuild not found -- install Xcode 27 or newer"
fi
for t in git curl shasum unzip zip; do command -v $t >/dev/null 2>&1 || die "missing tool: $t"; done

# --- 2. engine sources -------------------------------------------------------------
if [ -f "$ENGINE/src/core/main.cpp" ]; then
  ok "engine present: $ENGINE"
elif [ $CHECK_ONLY = 1 ]; then
  die "engine missing: $ENGINE (run without --check to clone it)"
else
  echo "  cloning $ENGINE_REPO @ $TAG -> $ENGINE"
  mkdir -p "$ROOT/Source"
  git clone --branch "$TAG" --recurse-submodules "$ENGINE_REPO" "$ENGINE"
  ok "engine cloned at $TAG"
fi
# The engine must sit on the release tag (detached HEAD is fine). A checkout that is not on
# the tag is a developer tree: reported, not touched.
if [ -d "$ENGINE/.git" ] || [ -f "$ENGINE/.git" ]; then
  AT=$(git -C "$ENGINE" describe --tags --exact-match 2>/dev/null || true)
  if [ "$AT" = "$TAG" ]; then
    ok "engine at tag $TAG"
  elif [ $CHECK_ONLY = 1 ]; then
    warn "engine is not at $TAG (HEAD: $(git -C "$ENGINE" rev-parse --short HEAD), $(git -C "$ENGINE" status --short | wc -l | tr -d ' ') local changes) -- developer tree?"
  elif [ -z "$(git -C "$ENGINE" status --short)" ]; then
    git -C "$ENGINE" fetch --tags origin
    git -C "$ENGINE" checkout --quiet "$TAG"
    ok "engine switched to tag $TAG"
  else
    warn "engine has local changes, leaving it at $(git -C "$ENGINE" rev-parse --short HEAD) (expected tag $TAG)"
  fi
  if [ ! -f "$ENGINE/vendor/librw/src/gl/gl3device.cpp" ]; then
    [ $CHECK_ONLY = 1 ] && die "submodules missing in $ENGINE"
    git -C "$ENGINE" submodule update --init --recursive
    ok "submodules initialised"
  fi
fi
[ -d "$ENGINE/gamefiles" ] || die "$ENGINE/gamefiles missing (the Run Script phase packs it into the app)"

# --- 3. prebuilt binaries ----------------------------------------------------------
mkdir -p "$THIRD/ANGLE" "$THIRD/openal-soft/lib"
DL="$THIRD/.downloads/$TAG"
mkdir -p "$DL"

fetch() {  # fetch <asset>
  if [ -s "$DL/$1" ]; then return 0; fi
  [ $CHECK_ONLY = 1 ] && die "$1 not downloaded (run without --check)"
  echo "  downloading $1"
  curl -fL --progress-bar -o "$DL/$1.part" "$BASE_URL/$1" || die "download failed: $BASE_URL/$1"
  mv "$DL/$1.part" "$DL/$1"
}

fetch SHA256SUMS
for a in "${ASSETS[@]}"; do fetch "$a"; done
( cd "$DL" && grep -E "$(IFS='|'; echo "${ASSETS[*]}" | sed 's/\./\\./g')" SHA256SUMS | shasum -a 256 -c - ) \
  || die "checksum mismatch -- delete $DL and run again"
ok "checksums verified"

if [ $CHECK_ONLY = 0 ]; then
  for z in ANGLE_libEGL ANGLE_libGLESv2; do
    rm -rf "$THIRD/ANGLE/$z.xcframework"
    unzip -q -o "$DL/$z.xcframework.zip" -d "$THIRD/ANGLE/"
  done
  cp "$DL/libopenal.a" "$DL/libalsoft.fmt.a" "$THIRD/openal-soft/lib/"
fi
for p in ANGLE/ANGLE_libEGL.xcframework/Info.plist ANGLE/ANGLE_libGLESv2.xcframework/Info.plist \
         openal-soft/lib/libopenal.a openal-soft/lib/libalsoft.fmt.a openal-soft/include/AL/al.h; do
  [ -e "$THIRD/$p" ] || die "missing: ThirdParty/$p"
done
ok "ThirdParty complete"

cat <<EOF

Done. Next steps:
  1. open $HERE/AvpViceCity.xcodeproj
  2. Signing & Capabilities: select your team; change the bundle identifier prefix
     (com.lowriderxr.AvpViceCity -> your own reverse-DNS prefix)
  3. scheme "AvpViceCity-Release", destination: your Apple Vision Pro, Run
  4. in the app: install the game data from a ZIP of your original PC copy (see README)
EOF

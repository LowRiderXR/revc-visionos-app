# OpenAL Soft for visionOS (libopenal.a + libalsoft.fmt.a)

The app links two static archives built from kcat/openal-soft. Without the patch below,
a **Release** build of the app shows missing glyphs (S s a g 6 8) in every SwiftUI text:
openal-soft replaces the process-global aligned `operator new/delete` with a
`posix_memalign` shim intended for macOS < 10.13, and the version check is accidentally
true under the visionOS SDK (`MAC_OS_X_VERSION_MIN_REQUIRED` = 1050 there). dyld then binds
every image in the process -- including Apple's font parser -- to that shim, which rejects
alignments below `sizeof(void*)` where libc++ rounds them up. Found 2026-09-30 with Address
Sanitizer (`invalid-posix-memalign-alignment`, stack libFontParser -> `operator new` in the
app binary). Debug builds were unaffected only because the linker did not pull `almalloc.o`
from the archive there.

## Source

| | |
|---|---|
| Repository | https://github.com/kcat/openal-soft.git |
| Commit | `75a0d1beb33fc4b28a6262f737d764167c216a44` (tag `latest`, 2026-08-15 "Add missing include") |
| Patch | `0001-visionos-restrict-aligned-new-shim-to-macos.patch` (this directory) |
| fmt dependency | fmt 11.2.0, fetched by openal-soft's CMake into `fmt-11.2.0/` next to the sources; builds as `libalsoft.fmt.a`, which must be linked too |

## Build

```bash
git clone https://github.com/kcat/openal-soft.git
cd openal-soft
git checkout 75a0d1beb33fc4b28a6262f737d764167c216a44
git apply <app-repo>/ThirdParty/openal-soft/0001-visionos-restrict-aligned-new-shim-to-macos.patch

cmake -S . -B build-xros -G Xcode \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=1.0 \
  -DLIBTYPE=STATIC \
  -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL=OFF \
  -DALSOFT_EAX=OFF -DALSOFT_EMBED_HRTF_DATA=ON

cmake --build build-xros --config Release --target OpenAL
```

Backends that end up active on visionOS: CoreAudio, WaveFile, Null (the other backend
options stay at their defaults and are simply not found on this platform).

Outputs, and where the Xcode project expects them inside the app repo (since 2026-10-06;
`lib/*.a` is git-ignored and normally downloaded from the GitHub release by `setup.sh`,
the headers in `include/AL/` are versioned):

```
build-xros/Release-xros/libopenal.a                              -> ThirdParty/openal-soft/lib/libopenal.a
build-xros/build/alsoft.fmt.build/Release-xros/libalsoft.fmt.a   -> ThirdParty/openal-soft/lib/libalsoft.fmt.a
include/AL/*.h                                                   -> ThirdParty/openal-soft/include/AL/
```

## Verify

The shim must be gone from the archive **and** from the linked app binary:

```bash
nm -gU build-xros/Release-xros/libopenal.a | grep align_val_t          # expect: nothing
nm -gU <build>/AvpViceCity.app/AvpViceCity   | grep align_val_t          # expect: nothing
```

If either line prints `__ZnwmSt11align_val_t` / `__ZdlPvSt11align_val_t`, the patch is not
in the build and the Release launcher will lose glyphs again.

## Upstream status (checked 2026-09-30)

`origin/master` at `6d39f8f` (2026-09-29, "Export filesystem bitwise ops") still has the
unguarded condition in `common/almalloc.cpp`; no commit has touched that file since our
pinned commit, so the patch applies to master unchanged. Not fixed upstream -- worth an
issue/PR to kcat/openal-soft: "aligned operator new shim for macOS < 10.13 is active on
iOS/tvOS/visionOS because AvailabilityMacros.h defines MAC_OS_X_VERSION_MIN_REQUIRED=1050
there; gate with TARGET_OS_OSX". Minimal reproduction: any Release iOS/visionOS app linking
the static library and rendering system text.

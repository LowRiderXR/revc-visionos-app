# reVC for visionOS

A port of **reVC**, the reverse-engineered Grand Theft Auto: Vice City engine of the re3
project, to Apple Vision Pro: true stereo rendering in a full immersive space, head
tracking, foveated rendering, game-controller input, and a small launcher for settings,
save games and the game data.

The app contains **no game content**. You need your own copy of the **original PC
version** of GTA Vice City; the launcher installs the data from a ZIP of that
installation. The Definitive Edition does not work.

## Status

Release candidate. Tested on Apple Vision Pro (M5) with visionOS 26.5; the M2 model is
supported with conservative defaults but has had less testing. Known limitations:

- Pause menu, HUD and loading screens are flat panels in front of you; the world is 3D.
- Streaming does not run while the pause menu is open (look around freely, but areas you
  never faced may be missing models until you resume).
- The first game start after installing the data converts the textures once (progress bar,
  a few minutes).

## Requirements

| | |
|---|---|
| Device | Apple Vision Pro, visionOS 26.5 or newer |
| Mac | Xcode 27 or newer (visionOS 26.5 SDK), free Apple developer account for signing |
| Game | GTA Vice City, original PC version (Rockstar Store "Grand Theft Auto: The Trilogy" classic bundle, or retail disc). Not the Definitive Edition. |
| Controller | Any game controller supported by visionOS (Xbox, PlayStation) |

## Build

Every release carries the same tag in all four repositories; check out that tag, not the
branch tip, so sources and prebuilt binaries match (`setup.sh` does this for the engine).

```bash
mkdir revc && cd revc
git clone --branch v1.0-rc1 https://github.com/LowRiderXR/revc-visionos-app.git AvpViceCity
cd AvpViceCity
./setup.sh            # engine at the same tag next to this repo, binaries downloaded + verified
open AvpViceCity.xcodeproj
```

In Xcode: *Signing & Capabilities* → choose your team and change the bundle identifier
prefix to your own (`com.lowriderxr.AvpViceCity` → `com.yourname.AvpViceCity`). Select the
scheme **AvpViceCity-Release** and your Vision Pro as destination, then Run.

`setup.sh` produces this layout; the Xcode project refers to the engine with relative
paths, so the two folders must be siblings:

```
revc/
  AvpViceCity/                 this repo (revc-visionos-app)
    ThirdParty/ANGLE/          ANGLE xcframeworks  (release asset, git-ignored)
    ThirdParty/openal-soft/    headers + patch versioned, lib/*.a from the release
  Source/reVC/                 revc-visionos: engine, vendor/librw-visionos, ogg, opus, opusfile
```

`./setup.sh --check` verifies an existing layout without downloading. To rebuild the
binaries yourself instead of using the release assets, see `ThirdParty/openal-soft/BUILD.md`
and [visionos-angle-kit](https://github.com/LowRiderXR/visionos-angle-kit).

### About the name

The Xcode project, target, folder and bundle identifier are called `AvpViceCity` for
historical reasons (the project started under that working title). They are only visible to
people building the app; the app itself is shown as *reVC for visionOS*. Since you have to
change the bundle identifier to your own prefix anyway, there is no reason to rename the rest.

## Installing the game data

1. On your PC, locate the Vice City installation folder (Rockstar Games Launcher: Settings →
   My installed games → Grand Theft Auto: Vice City → View installation folder; retail:
   usually `C:\Program Files\Rockstar Games\Grand Theft Auto Vice City`).
2. Compress that folder into a ZIP and bring it to the Vision Pro via iCloud Drive or AirDrop.
3. In the app tap **Install…** and select the ZIP. Only the game data (anim, audio, data,
   models, TEXT, txd) is copied into the app's Documents/Game folder; installers, executables
   and videos are skipped. All nine radio stations must be present.
4. The first start converts the textures once; afterwards the game starts directly.

Save games and settings live in `Documents/GTA Vice City User Files` and survive a
**Replace…** of the game data. The launcher can export them to a folder and import them
again (useful when moving to another headset).

## Repositories

| Repository | Content | License |
|---|---|---|
| [revc-visionos-app](https://github.com/LowRiderXR/revc-visionos-app) | this app: launcher, renderer, visionOS glue | MIT (own code) |
| [revc-visionos](https://github.com/LowRiderXR/revc-visionos) | reVC engine with the visionOS skeleton | no license (see below) |
| [librw-visionos](https://github.com/LowRiderXR/librw-visionos) | librw with the GLES/ANGLE/stereo changes | MIT |
| [visionos-angle-kit](https://github.com/LowRiderXR/visionos-angle-kit) | patches and build recipe for ANGLE on visionOS | per patch (Klepton: MIT) |

## License

The code written for this repository is MIT-licensed (`LICENSE`).

**reVC itself has no license.** The re3 project's authors state that they do not feel in a
position to give the reverse-engineered engine a license, and this port does not grant one
either: `revc-visionos` is published as-is, like upstream, for personal porting work. Third-
party libraries (ANGLE, OpenAL Soft, librw, Klepton, fmt, dr_mp3, ogg/opus/opusfile) are
listed with their licenses in `THIRD_PARTY_NOTICES.md`, which is also attached to every
release. Grand Theft Auto and Vice City are trademarks of Take-Two Interactive; this project
is not affiliated with or endorsed by Rockstar Games or Take-Two.

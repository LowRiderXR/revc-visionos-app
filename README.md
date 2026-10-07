# reVC for visionOS

A port of **reVC**, the reverse-engineered Grand Theft Auto: Vice City engine of the re3
project, to Apple Vision Pro: stereo rendering in a full immersive space, head tracking,
foveated rendering, game-controller input, and a launcher for settings, save games and
the game data.

The app contains **no game content**. You install the data from your own copy of the
classic PC version of GTA Vice City.

## Requirements

- Apple Vision Pro with visionOS 27 or newer
- A Mac with Xcode 27 or newer
- An Apple account for signing. A free account works, but the app then has to be
  rebuilt every 7 days; a paid developer account extends this to one year.
- A game controller (Xbox or PlayStation) — required
- GTA Vice City, classic PC version: "Grand Theft Auto: The Trilogy" in the
  [Rockstar Store](https://store.rockstargames.com/game/buy-grand-theft-auto-the-trilogy).
  Older classic Steam copies also work. The Definitive Edition does not.

## 1. Prepare Vision Pro and Xcode (once)

1. Put the Vision Pro and the Mac on the same Wi‑Fi network.
2. On the Vision Pro, open Settings → General → Remote Devices and leave that screen open.
3. In Xcode, open the run destination pop-up in the toolbar and choose Manage Devices…
   (this opens Device Hub). Click the Add Device button (+) → Pair Nearby Device…, choose
   Apple Vision Pro, select your headset and enter the PIN shown on the device.
4. When asked, turn on Developer Mode on the Vision Pro: Settings → Privacy & Security →
   Developer Mode, then restart the device. The switch only appears once pairing has begun.
5. If Xcode has no visionOS support yet: Xcode → Settings → Components → install the
   visionOS platform support (or click Get next to "Any visionOS Device" in the run
   destination pop-up).

## 2. Get the code

    mkdir revc && cd revc
    git clone --branch v1.0-rc1 https://github.com/LowRiderXR/revc-visionos-app.git AvpViceCity
    cd AvpViceCity
    ./setup.sh

`setup.sh` downloads the engine and the prebuilt libraries. This takes a few minutes.

## 3. Build and install the app

1. Open `AvpViceCity.xcodeproj`.
2. Select the target AvpViceCity → Signing & Capabilities: choose your team and change
   the bundle identifier to something of your own, for example `com.yourname.revc`.
3. In the toolbar, choose the scheme AvpViceCity-Release and your Vision Pro as destination.
4. Press Run (⌘R). The app appears on the Vision Pro as "reVC for visionOS".

## 4. Install the game data (once)

1. On your PC, open the Vice City installation folder.
   Rockstar Games Launcher: Settings → My installed games → Grand Theft Auto: Vice City →
   View installation folder. Retail: `C:\Program Files\Rockstar Games\Grand Theft Auto Vice City`.
2. Compress the whole folder into a ZIP file.
3. Put the ZIP into iCloud Drive (recommended), or send it to the Vision Pro with AirDrop.
4. On the Vision Pro, open the app, tap Install… and choose the ZIP. You need about 4 GB of
   free space during installation.
5. Start the game. The first start prepares the textures once, with a progress bar.

## Save games

Use Export… and Import… in the launcher to back up your saves. Deleting the app also deletes
saves and game data — export first.

## Tips

Aiming with the gamepad is hard in VR. It is much easier with a rifle: press R1 for the
scope, then aim with your head and just look at the target.

## For developers

Every release carries the same tag in all four repositories (`v1.0-rc1` today); `setup.sh`
checks the engine out at that tag so sources and prebuilt binaries match. The Xcode project
refers to the engine with relative paths, so the folders must be siblings:

```
revc/
  AvpViceCity/                 this repo (revc-visionos-app)
    ThirdParty/ANGLE/          ANGLE xcframeworks  (release asset, git-ignored)
    ThirdParty/openal-soft/    headers + patch versioned, lib/*.a from the release
  Source/reVC/                 revc-visionos: engine, vendor/librw-visionos, ogg, opus, opusfile
```

`./setup.sh --check` verifies an existing layout and the checksums without downloading or
touching anything. `scripts/make-release-assets.sh` packs the binaries in `ThirdParty/` into
the release assets with `SHA256SUMS`.

To build the binaries yourself instead of using the release assets: OpenAL Soft per
`ThirdParty/openal-soft/BUILD.md` (pinned commit + one patch, CMake), ANGLE per
[visionos-angle-kit](https://github.com/LowRiderXR/visionos-angle-kit) (pinned commit,
patch chain, gn args, retarget to visionOS).

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
party libraries (ANGLE, OpenAL Soft under the LGPL v2 or later, librw, Klepton, fmt, dr_mp3,
ogg/opus/opusfile) are listed with their licenses in `THIRD_PARTY_NOTICES.md`, which is also
attached to every release. Grand Theft Auto and Vice City are trademarks of Take-Two Interactive; this project
is not affiliated with or endorsed by Rockstar Games or Take-Two.

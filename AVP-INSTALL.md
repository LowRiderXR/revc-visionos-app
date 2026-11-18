# reVC for visionOS — install guide

This is the install guide for the [AVP Ports Index](https://github.com/edgytoast/avp-ports-index).
The full documentation, including the complete controller layout, is in [README.md](README.md).

## 1. What this is

reVC for visionOS is a native Apple Vision Pro port of **reVC**, the reverse-engineered
Grand Theft Auto: Vice City engine of the re3 project. The game runs in a full immersive
space with stereo rendering (third-person), head tracking, foveated rendering and
game-controller input. A launcher window handles settings, save games and the game data.

The app contains **no game content**. You install the data from your own copy of the
classic PC version of GTA Vice City.

## 2. Requirements

- Apple Vision Pro with visionOS 27 or newer.
- A Mac with Xcode 27 or newer. visionOS platform support must be installed in Xcode
  (Xcode → Settings → Components, or click Get next to "Any visionOS Device").
- An Apple account for signing. A free account works, but the app then has to be rebuilt
  and reinstalled every 7 days; a paid developer account extends this to one year.
- A game controller (Xbox or PlayStation). It is required; there is no hand or eye input.
- Grand Theft Auto: Vice City, **classic PC version**. It is sold as "Grand Theft Auto: The
  Trilogy" in the [Rockstar Store](https://store.rockstargames.com/game/buy-grand-theft-auto-the-trilogy).
  Older classic Steam copies also work. The Definitive Edition does **not** work.

## 3. Game files

This repository contains no game data, and nothing is downloaded or redistributed by the
project. You bring the data from your own PC installation:

1. On your PC, open the Vice City installation folder.
   Rockstar Games Launcher: Settings → My installed games → Grand Theft Auto: Vice City →
   View installation folder. Retail: `C:\Program Files\Rockstar Games\Grand Theft Auto Vice City`.
2. Compress the **whole folder** into a ZIP file. The app looks for the data folders
   `anim`, `audio`, `data`, `models`, `movies`, `TEXT` and `txd` inside it.
3. Put the ZIP into iCloud Drive (recommended), or send it to the Vision Pro with AirDrop.
4. After the app is installed (sections 5 and 6), open it on the Vision Pro, tap **Install…**
   and choose the ZIP. You need about 4 GB of free space during installation.

The data is stored in the app's Documents folder on the Vision Pro. Deleting the app also
deletes the game data and the save games.

## 4. Getting the code

Skip this step if the index tooling has already checked out the repository for you.

    mkdir revc && cd revc
    git clone --branch v1.0.2 https://github.com/LowRiderXR/revc-visionos-app.git AvpViceCity
    cd AvpViceCity

Git's note about a "detached HEAD" is expected: you are checking out a release tag, not a
branch. The folder name `AvpViceCity` is not required, but the checkout must live in a
folder whose **parent** is writable: the setup script places the engine next to it.

## 5. Build

Start inside the checkout (the folder that contains `AvpViceCity.xcodeproj`).

1. Prepare the Vision Pro and Xcode once: put both on the same Wi‑Fi network, open
   Settings → General → Remote Devices on the Vision Pro, and in Xcode choose
   Manage Devices… → Add Device (+) → Pair Nearby Device…. When asked, turn on Developer
   Mode on the Vision Pro (Settings → Privacy & Security → Developer Mode) and restart it.
2. Run the setup script:

       ./setup.sh

   It clones the engine repository (revc-visionos with its submodules) at the same release
   tag into `../Source/reVC`, downloads the prebuilt ANGLE and OpenAL Soft binaries from the
   GitHub release of this repository, verifies their SHA-256 checksums and places them under
   `ThirdParty/`. This takes a few minutes. `./setup.sh --check` verifies an existing layout
   without downloading anything.
3. Open `AvpViceCity.xcodeproj` in Xcode.
4. Select the target **AvpViceCity** → Signing & Capabilities: choose **your** team and
   change the bundle identifier to something of your own, for example `com.yourname.revc`.
   The project ships with the author's team and bundle identifier, which will not sign for you.
5. In the toolbar, choose the scheme **AvpViceCity-Release** (Release configuration) and
   your Apple Vision Pro as the run destination.
6. Press Run (⌘R). The app appears on the Vision Pro as "reVC for visionOS".

## 6. Run

1. Open the app. The launcher window offers the render settings, save-game export and
   import, and the game-data installer.
2. Install the game data from your ZIP (section 3), then tap **Start Vice City**.
   The first start prepares the textures once, with a progress bar.
3. Play with the controller. The game uses its original PlayStation 2 layout; buttons cannot
   be remapped in this version. The layout, with a picture of your controller, is shown in
   the game under Options → Controller Setup. The most important buttons (Xbox names first,
   PlayStation names in parentheses):

| Action | Button |
|---|---|
| Move / steer | Left stick or D-pad |
| Look around, first-person camera | Right stick |
| Run / accelerate | A (Cross) |
| Attack, fire / vehicle weapon | B (Circle) |
| Jump / brake, reverse | X (Square) |
| Enter or exit vehicle | Y (Triangle) |
| Target, lock on / hand brake | RB (R1) |
| Camera mode | View (Create / Share) |
| Pause | Menu (Options) |

The complete on-foot and in-vehicle tables are in the README.

Use **Export…** and **Import…** in the launcher to back up your saves before deleting or
replacing the app.

## 7. Troubleshooting

- **Signing fails in Xcode.** Make sure you selected your own team and changed the bundle
  identifier (section 5, step 4).
- **No visionOS run destination.** Install the visionOS platform support in Xcode
  (Xcode → Settings → Components) and finish pairing with Developer Mode enabled.
- **The app stops launching after a week.** With a free Apple account the signature expires
  after 7 days; build and run again from Xcode.
- **Brief stutters right after a fresh install.** The game may stutter the first time
  something new appears (rain, explosions, interiors) while shaders are compiled. This
  happens only once; afterwards it runs smoothly.
- **Aiming is hard.** It is much easier with a rifle: press RB (R1) for the scope, then aim
  with your head and look at the target.
- **"Definitive Edition" data does not install.** Only the classic PC version works.

Anything else: see the README.

## 8. Legal

- This project contains and distributes no Grand Theft Auto: Vice City game data. Players
  install the data from their own copy of the original PC version.
- Grand Theft Auto and Vice City are trademarks of Take-Two Interactive. This project is
  not affiliated with or endorsed by Rockstar Games or Take-Two.
- The code written for this repository (launcher, renderer, scripts) is MIT-licensed, see
  `LICENSE`.
- **The reVC engine itself has no license.** The re3 project's authors state that they do
  not feel in a position to give the reverse-engineered engine a license, and this port
  does not grant one either; the engine repository `revc-visionos` is published as-is for
  personal porting work.
- Third-party libraries (ANGLE, OpenAL Soft, librw, Klepton, fmt, dr_mp3, ogg/opus/opusfile)
  are listed with their licenses in `THIRD_PARTY_NOTICES.md`.
- The project is provided "as is", without warranty of any kind. Use it at your own risk.

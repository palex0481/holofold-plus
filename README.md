# Holofold

**English** | [简体中文](README.zh-CN.md)

**3DS emulation for Apple Vision Pro, in real stereoscopic 3D.**

![Holofold running on Apple Vision Pro: stereoscopic top screen, bottom screen in its own window, played with PS VR2 Sense controllers](docs/images/holofold-vision-pro.jpg)

Holofold runs 3DS software natively on Apple Vision Pro. The top screen is shown in true stereo (each eye gets its own image, just like turning up the 3D slider), optionally bent into a curved "cinema" screen, and the bottom screen floats in its own tilted window that you touch by looking and pinching.

Holofold is a fork of [Bifold](https://github.com/Bifold-Emu/Bifold) (an iOS front end for Azahar) and is built on the [Azahar](https://github.com/azahar-emu/azahar) emulator core.

> **Not affiliated with Nintendo or Apple.** Holofold does not include, link to, or distribute any games, ROMs, BIOS, firmware, or encryption keys. You must use game files dumped from cartridges you own.

## Features

- **Stereoscopic 3D**: the core renders both eyes side by side, and a RealityKit material shows each eye its own half. Adjustable depth.
- **Curved screen**: optionally wraps the top screen around you (20°–90°).
- **Bottom screen in its own window**: tilted like the lower half of the handheld; gaze + pinch to tap, pinch + drag to slide.
- **Controllers**: PS VR2 Sense, DualSense / DualShock 4, Xbox, Switch Pro and other MFi controllers; controller gyro for motion controls.
- **HD texture packs** in Azahar's format (see [HD texture packs](#hd-texture-packs)).
- **Auto-save**: leaving the game saves a state, and the next launch resumes from it.
- **Full speed on M5**: about 60 fps with the interpreter alone in our tests (no JIT needed), at up to 4× internal resolution (1600×960 per eye).
- **Boots straight into the game**: no launcher UI.
- **Runs in the Shared Space**: the game and bottom screen are regular windows you can place next to other apps, and the 3D works there. There's no immersive mode yet.

## Status

Early and experimental.

Tested games (Vision Pro M5, interpreter, no JIT):

| Game | Status |
|---|---|
| Super Mario 3D Land | Plays well at about 60 fps; HD texture pack works |
| The Legend of Zelda: Ocarina of Time 3D | Boots and starts a new game (name entry works); longer play not tested yet |

Tested another game? Please open an issue with the result.

Known issues:

- A game can freeze after several minutes of play (the game stops drawing while the emulator keeps running). We're investigating. The **interpreter compatibility mode** (see [Configuration](#configuration)) helps narrow it down, and reports with the diagnostics described below are very welcome.
- The Vision Pro screen recorder captures one eye only, so recordings look flat. The 3D is in the headset.
- The `Bifold` iOS target is kept from upstream and is not the focus of this fork.

## Requirements

| | |
|---|---|
| Headset | Apple Vision Pro, visionOS 26 or later (tested on M5, visionOS 27) |
| Mac | Apple silicon, Xcode 27 or later with the visionOS SDK |
| Tools | `brew install cmake ninja xcodegen` (CMake 3.28 or later), Python 3 |
| Apple account | A **free Apple ID works** (Xcode › Settings › Accounts › add it, then use its "Personal Team"). A paid developer account additionally unlocks the Increased Memory Limit entitlement (higher default resolution) and 1-year signing. |
| Disk | About 5 GB free. The first core build takes 10–20 minutes. |

### Free vs paid developer account

| | Free Apple ID | Paid account |
|---|---|---|
| Build and install on your own Vision Pro | ✅ | ✅ |
| Increased Memory Limit (`HOLOFOLD_INCREASED_MEMORY`) | ❌ leave it `NO` | ✅ |
| Default internal resolution | chosen automatically from available memory (2×–4×) | up to 4× |
| App stays installed | 7 days, then Run again from Xcode (your games and saves are kept) | 1 year |
| Apps installed at once with this account | 3 | unlimited |
| New app IDs | 10 per 7 days | unlimited |
| Optional JIT (e.g. StikDebug) | ✅ | ✅ |

## Build and install

```bash
# 1. Get the code
git clone https://github.com/zlinoliver/Holofold.git
cd Holofold

# 2. Fetch Azahar 2126.2 and its submodules (about 1.5 GB) and apply the patches
./scripts/bootstrap.sh

# 3. Build the emulator core for the headset (the first build takes a while)
./scripts/build-core-ios.sh --sdk xros

# 4. Signing: copy the template and fill in your Team ID and a bundle ID of your own
cp App/Config/Local.xcconfig.example App/Config/Local.xcconfig
#    DEVELOPMENT_TEAM = ABCDE12345
#    HOLOFOLD_BUNDLE_ID = com.yourname.holofold
#    HOLOFOLD_INCREASED_MEMORY = NO   # YES only with a paid developer account

# 5. Generate the Xcode project and run
xcodegen generate
open Holofold.xcodeproj   # select the "Holofold" scheme and your Vision Pro, then Run
```

`App/Config/Local.xcconfig` is ignored by git. Without it the project still builds: pick your team in Xcode's Signing & Capabilities instead.

### First-time setup on the headset

1. **Pair** the headset with your Mac: on the headset open Settings › General › Remote Devices; in Xcode open Window › Devices and Simulators and pair.
2. **Enable Developer Mode**: on the headset open Settings › Privacy & Security › Developer Mode, turn it on, and restart.
3. **Bundle ID**: it must be unique to you. `com.example.holofold` will not sign; use something like `com.yourname.holofold`.
4. After the first install with a **free** account, **trust your certificate**: Settings › General › VPN & Device Management › your Apple ID › Trust. Otherwise the app won't open.
5. Free-account builds expire after 7 days. Just Run again from Xcode; reinstalling over the old app keeps your games and saves.

You can also build and install from the command line:

```bash
xcodebuild -project Holofold.xcodeproj -scheme Holofold -destination "generic/platform=visionOS" \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build
xcrun devicectl device install app --device <headset UDID> \
  build/DerivedData/Build/Products/Debug-xros/Holofold.app
```

The visionOS Simulator works for UI and layout checks only (`./scripts/build-core-ios.sh --sdk xrsimulator` first). It uses the software renderer (slow), and the stereo material shows a single eye there.

## Add your games

1. **Dump your own cartridges** with your own 3DS (see Azahar's documentation for dumping guides). Holofold only supports **decrypted** dumps (`.cia`, `.3ds`, `.cci`, `.cxi`, `.3dsx`).
2. Check that a dump is decrypted:
   ```bash
   python3 scripts/tools/ciacheck.py your-game.cia
   ```
   Every content should report `decrypted`, and the file `✅ usable`. Dumps that are still encrypted inside (NCCH) are rejected by Azahar.
3. Copy it to the headset, either:
   - in the Files app: **On My Apple Vision Pro › Holofold**, or
   - from your Mac: `./scripts/push-game.sh your-game.cia`. It copies into the app's Documents folder with `devicectl` and never deletes anything.
4. Open Holofold. `.cia` files install automatically, then the game starts.

Which game starts:

1. `HOLOFOLD_AUTOBOOT_TITLE_ID` in `App/Config/Local.xcconfig` (the 16-digit title ID, or a file name), if set;
2. otherwise your first game (by title);
3. with no game of your own, the bundled open-source homebrew **StarCruiser7**, which also uses the stereoscopic top screen. A fresh build always has something to show.

## HD texture packs

Holofold loads custom texture packs in Azahar's format (a folder of `tex1_…png` files with a `pack.json`).

1. Find the pack's texture folder, usually `user/load/textures/<title ID>/`.
2. If the pack was made for another region, rename that folder to your copy's title ID (`python3 scripts/tools/ciacheck.py your-game.cia` prints it). Region-specific textures such as menu text may then not match and stay original.
3. Copy it to the headset as `Documents/Azahar/load/textures/<title ID>/`:
   ```bash
   ./scripts/push-game.sh --textures path/to/<title ID>
   ```
4. Start the game. Textures load in the background, so the first visit to an area may briefly show the originals.

Prefer a pack's 1080p (4×) version: 4K (8×) packs need much more memory. Only the textures are used; ReShade presets and other PC tools in a pack don't apply.

## Playing

- **Top screen (3D)** fills the game window. Resize the window to make it bigger.
- **Bottom screen** sits in its own window below. Look at it and pinch to tap; pinch and drag to slide.
- **Control bar** above the game window: Pause/Resume, 3D Depth, Curved, frame rate, Bottom Screen (reopen it), Exit Game.
- **Exit**: hold **Options / Menu** for about one second, use **Exit Game**, or press the Digital Crown. The game auto-saves first, and the next launch resumes from there.

### Controls

| 3DS | PS VR2 Sense | DualSense / Xbox / Switch Pro |
|---|---|---|
| Circle Pad | left stick | left stick |
| D-Pad | right stick | D-pad |
| C-Stick | — | right stick |
| A / B | ○ / ✕ | east / south button |
| X / Y | △ / □ (R2 also = Y) | north / west button |
| L / R | L1 / R1 | L1 / R1 (LB / RB) |
| ZL / ZR | L2 / — | L2 / R2 (LT / RT) |
| START | Options (hold to exit) | Menu (hold to exit) |
| SELECT | Create | Options / View |
| Gyro | — | controller gyro (lay the pad flat = holding the handheld upright) |

The PS button and the Xbox / Home button are reserved by visionOS and don't reach the app.

## Configuration

Build settings (in `App/Config/Local.xcconfig`):

| Setting | Default | Meaning |
|---|---|---|
| `HOLOFOLD_BUNDLE_ID` | `com.example.holofold` | Your bundle ID (required) |
| `HOLOFOLD_INCREASED_MEMORY` | `NO` | Increased Memory Limit entitlement (paid accounts) |
| `HOLOFOLD_AUTOBOOT_TITLE_ID` | empty | Game to boot (title ID or file name) |
| `HOLOFOLD_AUTO_RESUME` | `YES` | Resume from the auto-save |

Launch arguments (Xcode › Edit Scheme › Run › Arguments, for example `-resolutionFactor 3`):

| Argument | Default | Meaning |
|---|---|---|
| `-resolutionFactor N` | automatic (from available memory) | Internal resolution, 1–6. High values may get the app closed without the Increased Memory Limit entitlement. |
| `-visionStereoDepth N` | `100` | 3D depth, 10–100 |
| `-visionCurvedScreen YES/NO` | `YES` | Curved top screen |
| `-visionCurveDegrees N` | `50` | Curve angle, 20–90 |
| `-motionControls YES/NO` | `YES` | Controller gyro |
| `-customTextures YES/NO` | `YES` | Load HD texture packs |
| `-interpreterCompat YES` | `NO` | Interpreter compatibility mode: disables the newer interpreter speed-ups, for diagnosing freezes (slower) |
| `-autoboot <title ID or file>` | — | Same as `HOLOFOLD_AUTOBOOT_TITLE_ID`, for one run |

**JIT (optional)**: on visionOS, JIT needs a debugger-style helper such as StikDebug's universal script. Without it the interpreter is used, which runs most games at full speed on M5.

## Troubleshooting and diagnostics

Holofold writes diagnostics into its Documents folder:

| File | Contents |
|---|---|
| `vision-diag.log` | Boot choice, controllers found, memory and resolution, a perf line every 30 s, exits, hangs |
| `hang-game-*.txt` / `hang-emu-*.txt` | Written automatically when the game stops drawing or the emulator stalls: emulation-thread samples including the emulated CPU's PC |
| `Azahar/log/azahar_log.txt` | Emulator core log |

Fetch them with:

```bash
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier <your bundle ID> --source Documents/vision-diag.log --destination ./vision-diag.log
```

Remove personal paths from the logs before posting them in an issue.

## Contributing

**Pull requests are welcome!** Holofold is young and there is a lot to improve. Areas where help is especially appreciated:

- tracking down the freeze (interpreter correctness, HLE services)
- performance and frame pacing (60 fps content on a 90 Hz display)
- an immersive mode (Compositor Services) and better curved-screen geometry
- controller remapping, haptics
- localization, documentation, testing on M2 headsets

How to contribute:

1. Fork, create a branch from `main` (`feature/…` or `fix/…`), and keep each PR focused on one change.
2. Changes to the Azahar core go into `patches/azahar/` (regenerate the patch with `git diff` inside `external/azahar`). Never commit `external/` or `build/`.
3. Test with the bundled open-source homebrew (StarCruiser7, Craftus …) and describe how you tested.
4. Sign off your commits (`git commit -s`, [Developer Certificate of Origin](https://developercertificate.org/)). Contributions are accepted under GPL-2.0-or-later.
5. Install the pre-commit check: `ln -sf ../../scripts/check-private.sh .git/hooks/pre-commit`. The same check runs on every pull request.

**Never** put games, ROMs, BIOS / firmware, encryption keys, or links to them (or to tools that obtain them) in issues, pull requests or discussions. Such content is removed, and requests for it are closed. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Acknowledgements

Holofold exists thanks to these projects and the people behind them:

- **[Azahar](https://github.com/azahar-emu/azahar)**, the 3DS emulator Holofold is built on, and its predecessor **Citra**. GPL-2.0-or-later.
- **[Bifold](https://github.com/Bifold-Emu/Bifold)**, the iOS front end Holofold forked from: the AzaharCore C API, the iOS JIT work, the interpreter speed-ups and the controller layer. GPL-2.0-or-later. Its original README is kept in [docs/BIFOLD.md](docs/BIFOLD.md).
- **[CitraVR](https://github.com/amwatson/CitraVR)** by Amanda M. Watson. Its stereo panels and curved-screen mode inspired Holofold's presentation design (no CitraVR code is used).
- **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)** (Apache 2.0), which brings Vulkan to Metal, plus **dynarmic**, **oaknut**, **openal-soft** and the other libraries Azahar builds on, each under its own license.
- The authors of the bundled homebrew: **2048** by Carlos "0rientd" Henrique (MIT), **Anarch** by Miloslav Číž and blitzdoughnuts (CC0), **Craftus Reloaded** by Kemal Afzal "RSDuck" (MIT; textures by XSSheep, CC BY-SA), **HexIsoPath** and **Yahtzee3DS** by LiquidFenrir (MIT / GPL-3.0), **StarCruiser7** by dotMizi (MIT). Licenses are in `App/Bundled/licenses/`.

See [CREDITS.md](CREDITS.md) for the full list.

## License

Holofold is licensed under the **GNU General Public License v2.0 or later** (see [LICENSE.txt](LICENSE.txt)), the same as Azahar and Bifold. Third-party components keep their own licenses (see [CREDITS.md](CREDITS.md)). If you distribute a build, you must make the corresponding source available.

## Disclaimer

Holofold is an independent, non-commercial project. It is **not affiliated with, endorsed by, or sponsored by Nintendo or Apple**. "Nintendo 3DS" is a trademark of Nintendo; "Apple Vision Pro" and "visionOS" are trademarks of Apple Inc. They are used here only to describe compatibility.

The game footage in the screenshot comes from a cartridge the author owns and dumped themselves, and is shown only to demonstrate the emulator. The game and its trademarks belong to their respective owners.

Holofold does not include, link to, or distribute any copyrighted games, ROMs, BIOS, firmware, or encryption keys, and the project will not provide them. Please support the developers by buying the games you play and dumping them from your own hardware.

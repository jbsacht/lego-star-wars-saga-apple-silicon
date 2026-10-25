# LEGO Star Wars: The Complete Saga on Apple Silicon

Experimental compatibility fixes for the **original Mac App Store 1.1.1 RC4 release** of LEGO Star Wars: The Complete Saga. Build a local Mac application using your own installed, purchased copy.

This is a continuation of [Yash-Singh1/32-bit-ports](https://github.com/Yash-Singh1/32-bit-ports), based on commit `2245d949ff629a1c7d3e5ae53cbb49463183d627`. The upstream history and author credits are retained. The runtime bridges the original i386 game to modern macOS APIs and runs its Intel code through Rosetta 2; this is not a native ARM port or a replacement game engine.

**Licensing status:** upstream has no explicit license in the checked revision. Do not assume that public source grants permission to redistribute runtime binaries or relicense the inherited code. See [NOTICE.md](NOTICE.md) before publishing a release. This repository does not include the Complete Saga executable, data, receipt, saves, or a ready-to-play application. The original upstream history contains its own existing icons for other games; no Complete Saga artwork has been added.

## Tested status

Tested on one Apple M2 Max running macOS 27.0.1. Other M-series Macs and macOS versions need community testing. The installer deliberately rejects other game revisions instead of assuming compatibility.

Confirmed by the player:

- Keyboard movement and lightsaber activation work.
- A level was completed, saved, and reloaded.
- The performance changes substantially improved play.
- macOS fullscreen is correctly centered and shows the full image.

The delayed integrity check passed against the original signed installation after five minutes; a six-minute idle test retained normal colors. Full-campaign stability, audible mixing quality, controllers with this App Store edition, and long play sessions have not been verified. An intermediate fullscreen test also reached an unsupported C++ exception path; it has not recurred in the final display check, and should be reported if reproduced. This is an experimental community project, not a publisher-supported release.

## Requirements

- Your fully installed **Mac App Store 1.1.1 RC4** game, including its receipt. The setup checks the executable hash against the tested revision.
- An Apple Silicon Mac with Rosetta 2 already installed.
- Xcode command-line tools or Xcode, including a macOS SDK with the legacy system frameworks used by the runtime.
- Python 3, Git, and enough free storage for a local copy of the game data (about 4.4 GB, plus build files).

The current build was checked with Xcode/macOS SDK 27. The minimum OS claimed by the inherited runtime is macOS 11; that full range has **not** been tested here.

## Build your application

Clone or download the repository. Open Terminal in its folder.

Check your installed release without changing anything:

```sh
python3 tools/build_appstore.py --check \
  --source "/Applications/LEGO Star Wars Saga.app"
```

Quit any running compatibility copy, then build:

```sh
python3 tools/build_appstore.py \
  --source "/Applications/LEGO Star Wars Saga.app" \
  --configure-display
```

The script compiles the runtime, checks the original game's signature through native Security APIs, copies the original resources and receipt **on your Mac**, and creates:

```text
build/LEGO Star Wars Saga (Apple Silicon).app
```

`--configure-display` backs up existing preferences and sets only the old game's `FullScreen` preference to `0`. It does not delete saves, reset controls, or change other game options. A first-time preferences file is created if necessary. If you omit the flag, choose windowed mode in the original launcher yourself. Keeping the legacy fullscreen setting off allows macOS to manage fullscreen safely.

The source app is never overwritten. The output path must not already exist. An alternate destination is supported:

```sh
python3 tools/build_appstore.py \
  --source "/Applications/LEGO Star Wars Saga.app" \
  --output "$HOME/Applications/LEGO Star Wars Saga (Apple Silicon).app" \
  --configure-display
```

The generated app can be moved into Applications afterward. **Keep the original signed game installed at its original path**: the runtime validates that installation rather than the compatibility loader's ad-hoc signature. Moving the source later requires rebuilding the compatibility app. Rosetta must remain installed.

## Play

1. Open the generated application and click **Play**.
2. Press **Enter** at the title prompt to select the keyboard.
3. Choose **Load Game** or **New Game**.
4. Use the green window button or **Control–Command–F** for macOS fullscreen. The same shortcut exits fullscreen. Black letterboxing may appear to preserve the game's aspect ratio; the image is never intentionally cropped.
5. After switching apps, select **Resume** if the game is paused.

The verified configuration had shadows and bloom disabled. If a different configuration fails, include those settings in a bug report. Performance depends on the scene and machine; the bridge caps presentation near 60 FPS because the game simulation is frame dependent.

Settings and saves use the game's existing folder:

```text
~/Library/Application Support/Feral Interactive/LEGO Star Wars Saga/
```

Back up that folder before testing experimental builds. Generated apps and copies of game files must stay local and must not be uploaded to this repository or attached to issues.

## What changed

The fixes cover Carbon windows and Cocoa presentation, keyboard delivery and focus recovery, QuickTime movie/image handling, audio callback and converter lifetimes, missing physics and save/date APIs, and OpenGL compatibility. RTTI caching and direct shader-parameter dispatch remove substantial per-frame bridge overhead.

The persistent green tint was caused by the game's delayed integrity check seeing the ad-hoc loader identity. The bridge now validates the installed signed original with native `SecStaticCodeCheckValidity`, preserving the requested requirement and flags. It does not force a successful result or disable the game's checks.

Fullscreen uses a separate, centered render view with a fixed backing surface matching the guest's actual viewport. This avoids confusing the taller desktop mode with the game image size.

See [docs/VERIFICATION.md](docs/VERIFICATION.md) for the test matrix and [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md) for the inherited project's other editions and titles. Steam and DVD workflows in those inherited documents are **not** evidence that this App Store setup script supports them.

## Contributing and reporting issues

Use the issue templates and include the Mac model, macOS version, game edition, scene/action, fullscreen state, and whether it reproduces with shadows and bloom off. Do not upload receipts, save files, product keys, full game apps, or game archives. Redact account names and local paths from log excerpts.

Diagnostics are written to:

```text
~/Library/Logs/LEGOCompleteSagaCompat/last-run.log
```

Use small relevant excerpts rather than whole logs. Review changes against the upstream base; many inherited files support other games. Avoid claiming they have been tested by this project.

## Maintainer: publish with GitHub Desktop

See [docs/GITHUB-DESKTOP.md](docs/GITHUB-DESKTOP.md). No GitHub CLI authentication is required to use this local repository. Public distribution and licensing still need the review described in `NOTICE.md`.

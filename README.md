# G'MIC-Qt plug-in for GIMP 3.x on macOS — build & install script

No prebuilt [G'MIC](https://gmic.eu) plug-in binaries exist for GIMP 3.x on
macOS (gmic.eu ships Windows/Linux only; MacPorts' plugin targets GIMP 2.10;
Homebrew's `gmic` is CLI-only). This script builds one from source and
installs it into your user GIMP profile.

## Prerequisites
- On macOS 13+ on Apple Silicon or Intel
- Download and install GIMP v3.x from https://www.gimp.org/downloads/
- Install [Homebrew](https://brew.sh) and Xcode Command Line Tools
  (run `xcode-select --install`)


## Usage

Download the `./install-gmic-for-gimp-macos.sh` file locally. I suggest placing it on your Desktop.

Run:

```sh
cd ~/Desktop
chmod +x ./install-gmic-for-gimp-macos.sh
./install-gmic-for-gimp-macos.sh
```

Restart your machine, and then run it again:

```sh
cd ~/Desktop
./install-gmic-for-gimp-macos.sh
```

The script can take 10–30 minutes to finish compiling.


Open GIMP, open an image, and verify **Filters → G'MIC-Qt** exists. Done!


## Updating and uninstallation

Re-run the script to update after a new G'MIC or GIMP release.
`--uninstall` removes the plug-in; `--help` lists all options.

Notes / tips
- If you don't want to run many manual commands, the install script will
  attempt to install XQuartz automatically (unless you pass `--skip-deps`).
  If XQuartz is newly installed the script will ask you to restart (or
  log out/in) and re-run the script.
- The script also applies a small patch to `gmic-*/gmic-qt/CMakeLists.txt`
  to enable `cimg_display=1` and wire up X11 includes/libs so the Qt GUI
  works correctly on macOS for recent G'MIC releases.
- Example run (after installing GIMP and XQuartz and restarting):

```sh
chmod +x ./install-gmic-for-gimp-macos.sh
./install-gmic-for-gimp-macos.sh --gmic-version 4.0.3
```

## How it works

The GIMP.app bundle ships every library the plug-in needs but no development
headers. The script:

1. reads your GIMP version from the app bundle and downloads the *matching*
   GIMP source tarball (for headers only) plus the latest G'MIC source;
2. assembles a fake development prefix: headers from the source tree, a
   generated `gimpversion.h`, and a hand-written `gimp-3.0.pc` whose link
   line points at the dylibs **inside GIMP.app** (absolute paths + rpath) —
   so the plug-in speaks exactly the wire-protocol version of your GIMP,
   and never mixes a second copy of glib/GEGL into the process;
3. builds `gmic_gimp_qt` with CMake (`GMIC_QT_HOST=gimp3`, bundled libgmic,
   OpenMP), shimming two newer glib symbols via linker aliases when the
   bundle's glib is older than Homebrew's headers;
4. verifies the linkage (aborts if any Homebrew glib/gegl leaked in),
   ad-hoc signs the binary, installs it to
   `~/Library/Application Support/GIMP/<version>/plug-ins/gmic_gimp_qt/`,
   and smoke-tests it.

## Caveats

- After a GIMP minor upgrade (e.g. 3.2 → 3.4) the plug-in must be rebuilt —
  just re-run the script. GIMP's plug-in protocol changes between minor
  series.
- The plug-in links Qt and fftw from your Homebrew prefix, so don't
  uninstall those formulas while you use it.

## Credits

Build recipe pioneered by Sébastien Guyader
([pixls.us thread](https://discuss.pixls.us/t/gmic-plugin-for-gimp-3-2-in-macos/57708))
and the [resynthesizer macOS port](https://github.com/bootchk/resynthesizer/pull/159);
automated and generalized here. License: CC0 / public domain. No warranty.

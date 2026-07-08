# G'MIC-Qt plug-in for GIMP 3.x on macOS — build & install script

No prebuilt [G'MIC](https://gmic.eu) plug-in binaries exist for GIMP 3.x on
macOS (gmic.eu ships Windows/Linux only; MacPorts' plugin targets GIMP 2.10;
Homebrew's `gmic` is CLI-only). This script builds one from source and
installs it into your user GIMP profile.

## Usage

```sh
./install-gmic-for-gimp-macos.sh
```

Then restart GIMP, open an image, and find **Filters → G'MIC-Qt**.

Re-run the script to update after a new G'MIC or GIMP release.
`--uninstall` removes the plug-in; `--help` lists all options.

## Requirements

- macOS 13+ on Apple Silicon or Intel
- The official GIMP 3.x app bundle in `/Applications`
  (`brew install --cask gimp` or the DMG from gimp.org)
- [Homebrew](https://brew.sh) and Xcode Command Line Tools
  (`xcode-select --install`)

The script installs its build dependencies via Homebrew (Qt 5, gegl, fftw,
etc. — a few GB on first run) and needs 10–30 minutes to compile.

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

#!/usr/bin/env bash
#
# install-gmic-for-gimp-macos.sh
#
# Build and install the G'MIC-Qt plug-in for the *official* macOS GIMP 3.x
# app bundle (the one from gimp.org / `brew install --cask gimp`).
#
# Why this exists: no prebuilt G'MIC binaries exist for GIMP 3.x on macOS.
# The GIMP.app bundle ships all needed libraries but no development headers,
# so this script compiles the plug-in against headers from the matching GIMP
# source tarball while linking directly against the libraries inside
# GIMP.app. That guarantees the plug-in wire-protocol version matches the
# GIMP you actually run.
#
# Usage:
#   ./install-gmic-for-gimp-macos.sh [options]
#
# Options:
#   --gmic-version X.Y.Z   Pin a G'MIC version (default: latest from gmic.eu)
#   --gimp-app PATH        Path to GIMP.app (default: /Applications/GIMP.app)
#   --qt5 | --qt6          Force Qt major version (default: qt@5 if present,
#                          else qt6, else installs qt@5)
#   --work-dir PATH        Build/cache directory, must contain no spaces
#                          (default: ~/.gmic-gimp-build)
#   --jobs N               Parallel build jobs (default: all CPU cores)
#   --skip-deps            Don't run `brew install` (you manage deps yourself)
#   --uninstall            Remove the installed plug-in and exit
#   -h | --help            Show this help
#
# Re-run the script any time to update: it re-detects your GIMP version and
# the latest G'MIC release, rebuilds, and replaces the installed plug-in.
#
# Requirements: macOS 13+, Xcode Command Line Tools, Homebrew.
# Works on Apple Silicon and Intel (builds for your GIMP's architecture).
#
# Credits: build recipe pioneered by Sébastien Guyader (pixls.us) and the
# resynthesizer macOS port; automated and generalized here.
# License: CC0 / public domain. No warranty.

set -euo pipefail

# ---------------------------------------------------------------- utilities
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

trap 'printf "\033[1;31mERROR:\033[0m script failed near line %s. Scroll up for details.\n" "$LINENO" >&2' ERR

# ---------------------------------------------------------------- arguments
GMIC_VERSION=""
GIMP_APP="/Applications/GIMP.app"
QT_CHOICE="auto"          # auto | 5 | 6
WORK="$HOME/.gmic-gimp-build"
JOBS="$(sysctl -n hw.ncpu)"
SKIP_DEPS=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --gmic-version) GMIC_VERSION="${2:?}"; shift 2 ;;
    --gimp-app)     GIMP_APP="${2:?}"; shift 2 ;;
    --qt5)          QT_CHOICE=5; shift ;;
    --qt6)          QT_CHOICE=6; shift ;;
    --work-dir)     WORK="${2:?}"; shift 2 ;;
    --jobs)         JOBS="${2:?}"; shift 2 ;;
    --skip-deps)    SKIP_DEPS=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    -h|--help)      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- preflight
[ "$(uname -s)" = "Darwin" ] || die "this script is for macOS only."

[ -d "$GIMP_APP" ] || die "GIMP.app not found at $GIMP_APP.
Install it first:  brew install --cask gimp   (or from https://www.gimp.org)
Or pass its location with --gimp-app /path/to/GIMP.app"

BUNDLE="$GIMP_APP/Contents/Resources"
GIMP_BIN="$GIMP_APP/Contents/MacOS/gimp"
[ -x "$GIMP_BIN" ] || die "no gimp executable inside $GIMP_APP"

# GIMP version, e.g. 3.2.4 -> user dir 3.2, API 3.0
GIMP_FULL="$(defaults read "$GIMP_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)" \
  || die "could not read GIMP version from $GIMP_APP/Contents/Info.plist"
GIMP_MAJOR="${GIMP_FULL%%.*}"
rest="${GIMP_FULL#*.}"; GIMP_MINOR="${rest%%.*}"
GIMP_MICRO="${GIMP_FULL##*.}"
GIMP_MM="$GIMP_MAJOR.$GIMP_MINOR"
GIMP_API="$GIMP_MAJOR.0"
[ "$GIMP_MAJOR" -ge 3 ] 2>/dev/null || die "GIMP $GIMP_FULL found, but this script supports GIMP 3.x."

PLUGIN_DIR="$HOME/Library/Application Support/GIMP/$GIMP_MM/plug-ins/gmic_gimp_qt"

if [ "$UNINSTALL" = 1 ]; then
  if [ -d "$PLUGIN_DIR" ]; then
    rm -rf "$PLUGIN_DIR"
    log "removed $PLUGIN_DIR"
  else
    log "nothing to remove ($PLUGIN_DIR does not exist)"
  fi
  exit 0
fi

xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools missing. Run:  xcode-select --install"
command -v brew >/dev/null 2>&1 || die "Homebrew missing. Install from https://brew.sh"
BREW="$(brew --prefix)"

case "$WORK" in *" "*) die "work dir '$WORK' contains spaces; pkg-config cannot cope. Use --work-dir /path/without/spaces" ;; esac

# Architecture: build natively, but make sure GIMP.app supports this machine.
HOST_ARCH="$(uname -m)"
lipo -archs "$GIMP_BIN" 2>/dev/null | grep -qw "$HOST_ARCH" \
  || die "GIMP.app is built for '$(lipo -archs "$GIMP_BIN" 2>/dev/null)' but this machine is $HOST_ARCH."

log "GIMP $GIMP_FULL at $GIMP_APP (arch: $HOST_ARCH, plugin dir: GIMP/$GIMP_MM)"

# ---------------------------------------------------------------- Qt choice
if [ "$QT_CHOICE" = auto ]; then
  if brew list --formula qt@5 >/dev/null 2>&1; then QT_CHOICE=5
  elif brew list --formula qt >/dev/null 2>&1; then QT_CHOICE=6
  else QT_CHOICE=5
  fi
fi
if [ "$QT_CHOICE" = 5 ]; then
  QT_FORMULA=qt@5; QT_PREFIX="$BREW/opt/qt@5"; BUILD_WITH_QT6=OFF
else
  QT_FORMULA=qt;   QT_PREFIX="$BREW/opt/qt";   BUILD_WITH_QT6=ON
fi
log "using Qt$QT_CHOICE ($QT_FORMULA)"

# ---------------------------------------------------------------- brew deps
DEPS=(cmake pkgconf libpng fftw libomp glib gegl gexiv2 gdk-pixbuf cairo pango "$QT_FORMULA")
# macOS-only casks we need (installed via `brew install --cask`)
CASKS=(xquartz)
if [ "$SKIP_DEPS" = 1 ]; then
  log "skipping dependency installation (--skip-deps)"
else
  log "installing/checking Homebrew formula dependencies: ${DEPS[*]}"
  for f in "${DEPS[@]}"; do
    brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
  done

  # Install macOS casks (e.g. XQuartz) if missing. XQuartz typically requires
  # a logout/login or restart after first install; if we install it here we
  # exit with a friendly message so the user can restart before continuing.
  HAVE_XQUARTZ=0
  if brew list --cask xquartz >/dev/null 2>&1; then HAVE_XQUARTZ=1; fi
  for c in "${CASKS[@]}"; do
    brew list --cask "$c" >/dev/null 2>&1 || brew install --cask "$c"
  done
  if [ "$HAVE_XQUARTZ" -eq 0 ] && brew list --cask xquartz >/dev/null 2>&1; then
    die "XQuartz was just installed. Please restart (or log out/in) and re-run this script."
  fi
fi
command -v pkg-config >/dev/null 2>&1 || die "pkg-config not found even after installing pkgconf"
command -v cmake      >/dev/null 2>&1 || die "cmake not found"

# ---------------------------------------------------------------- versions
if [ -z "$GMIC_VERSION" ]; then
  log "looking up latest G'MIC release on gmic.eu ..."
  GMIC_VERSION="$(curl -fsSL --max-time 30 https://gmic.eu/files/source/ \
    | grep -oE 'gmic_[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
    | sed -E 's/^gmic_|\.tar\.gz$//g' \
    | sort -t. -k1,1n -k2,2n -k3,3n | uniq | tail -1 || true)"
  [ -n "$GMIC_VERSION" ] || die "could not determine latest G'MIC version. Pin one with --gmic-version X.Y.Z"
fi
log "G'MIC version: $GMIC_VERSION"

GMIC_TARBALL="gmic_${GMIC_VERSION}.tar.gz"
GMIC_URL="https://gmic.eu/files/source/$GMIC_TARBALL"
GIMP_TARBALL="gimp-${GIMP_FULL}.tar.xz"
GIMP_URL="https://download.gimp.org/gimp/v${GIMP_MM}/$GIMP_TARBALL"

# ---------------------------------------------------------------- downloads
mkdir -p "$WORK"
cd "$WORK"

fetch() { # fetch <url> <dest>
  if [ -s "$2" ]; then log "using cached $2"; else
    log "downloading $1"
    curl -fL --retry 3 -o "$2.part" "$1" || die "download failed: $1"
    mv "$2.part" "$2"
  fi
}
fetch "$GMIC_URL" "$GMIC_TARBALL"
fetch "$GIMP_URL" "$GIMP_TARBALL"

[ -d "gmic-$GMIC_VERSION" ]  || { log "extracting $GMIC_TARBALL";  tar xzf "$GMIC_TARBALL"; }
[ -d "gimp-$GIMP_FULL" ]     || { log "extracting $GIMP_TARBALL";  tar xJf "$GIMP_TARBALL"; }
[ -d "gmic-$GMIC_VERSION/gmic-qt" ] || die "gmic tarball layout unexpected (no gmic-qt/ inside)"

# For macOS builds (notably G'MIC 4.x), enable cimg display/X11 glue in the
# gmic-qt CMakeLists so the Qt GUI can use X11 via XQuartz. This mirrors the
# manual patch some users apply upstream.
if [ -f "$WORK/gmic-$GMIC_VERSION/gmic-qt/CMakeLists.txt" ]; then
  log "ensuring gmic-qt CMakeLists enables cimg_display and X11 includes"
  cd "$WORK/gmic-$GMIC_VERSION/gmic-qt"
  [ -f CMakeLists.txt.orig ] || cp CMakeLists.txt CMakeLists.txt.orig
  # Only apply when the file disables cimg display; the perl one-liner edits
  # the file in-place and preserves indentation.
  if grep -q "add_definitions(-Dcimg_display=0)" CMakeLists.txt; then
    perl -0pi -e 's/add_definitions\(-Dcimg_display=0\)\n(\s*)add_definitions\(-D_IS_MACOS_\)/add_definitions(-Dcimg_display=1)\n$1add_definitions(-D_IS_MACOS_)\n$1find_package(X11 REQUIRED)\n$1include_directories(SYSTEM \\${X11_INCLUDE_DIR})\n$1set(gmic_qt_LIBRARIES \\${gmic_qt_LIBRARIES} \\${X11_LIBRARIES})/' CMakeLists.txt
    log "patched CMakeLists.txt (backup at CMakeLists.txt.orig)"
  else
    log "CMakeLists.txt already appears patched; skipping"
  fi
  # quick sanity grep to show nearby lines (non-fatal)
  grep -A5 'cimg_display=1' CMakeLists.txt | tail -8 || true
  cd "$WORK"
fi

# ------------------------------------------------- fake GIMP dev prefix
# Headers come from the GIMP source tree; libraries from the app bundle.
DEV="$WORK/gimp-dev-$GIMP_FULL"
log "assembling GIMP dev prefix at $DEV"
rm -rf "$DEV"
mkdir -p "$DEV/include/gimp-$GIMP_API" "$DEV/lib/pkgconfig"
for d in libgimp libgimpbase libgimpcolor libgimpconfig libgimpmath; do
  [ -d "gimp-$GIMP_FULL/$d" ] || die "missing $d in GIMP source tree"
  mkdir -p "$DEV/include/gimp-$GIMP_API/$d"
  cp "gimp-$GIMP_FULL/$d/"*.h "$DEV/include/gimp-$GIMP_API/$d/"
done

# gimpversion.h is normally generated by meson; generate it from the template.
sed -e "s/@GIMP_MAJOR_VERSION@/$GIMP_MAJOR/" \
    -e "s/@GIMP_MINOR_VERSION@/$GIMP_MINOR/" \
    -e "s/@GIMP_MICRO_VERSION@/$GIMP_MICRO/" \
    -e "s/@GIMP_VERSION@/$GIMP_FULL/" \
    -e "s/@GIMP_API_VERSION@/$GIMP_API/" \
    "gimp-$GIMP_FULL/libgimpbase/gimpversion.h.in" \
    > "$DEV/include/gimp-$GIMP_API/libgimpbase/gimpversion.h"

# Compile flags: headers of the GObject stack come from Homebrew.
# (Homebrew's gexiv2 pkg-config module name varies: gexiv2 vs gexiv2-0.16.)
GEXIV2_PC=""
for cand in gexiv2 $(cd "$BREW/lib/pkgconfig" 2>/dev/null && ls gexiv2*.pc 2>/dev/null | sed 's/\.pc$//'); do
  if pkg-config --exists "$cand" 2>/dev/null; then GEXIV2_PC="$cand"; break; fi
done
[ -n "$GEXIV2_PC" ] || die "gexiv2 pkg-config module not found (brew install gexiv2)"
DEPS_CFLAGS="$(pkg-config --cflags gegl-0.4 "$GEXIV2_PC" pango cairo gdk-pixbuf-2.0 gio-2.0)" \
  || die "pkg-config could not resolve dependency cflags"

# Link line: the bundle's own dylibs, by absolute path (never Homebrew's
# glib/gegl -- mixing GObject stacks inside one process crashes).
BUNDLE_LIBS=""
for lib in libgimp-$GIMP_API libgimpbase-$GIMP_API libgimpcolor-$GIMP_API \
           libgimpconfig-$GIMP_API libgimpmath-$GIMP_API \
           libgegl-0.4 libbabl-0.1 libgobject-2.0 libglib-2.0 libgio-2.0 libintl; do
  f="$BUNDLE/lib/$lib.dylib"
  [ -e "$f" ] || die "expected library missing from GIMP.app: $f"
  BUNDLE_LIBS="$BUNDLE_LIBS $f"
done

# The bundle's glib may be older than Homebrew's headers. Newer glib headers
# emit references to g_once_init_{enter,leave}_pointer; if the bundle's glib
# lacks them, alias them to the classic symbols at link time.
ALIAS_FLAGS=""
if ! nm -gU "$BUNDLE/lib/libglib-2.0.0.dylib" 2>/dev/null | grep -q '_g_once_init_enter_pointer$'; then
  log "bundle glib lacks g_once_init_*_pointer -- enabling linker aliases"
  ALIAS_FLAGS=" -Wl,-alias,_g_once_init_enter,_g_once_init_enter_pointer -Wl,-alias,_g_once_init_leave,_g_once_init_leave_pointer"
fi

cat > "$DEV/lib/pkgconfig/gimp-$GIMP_API.pc" <<EOF
prefix=$DEV
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
gimplibdir=\${prefix}/lib/gimp/$GIMP_API
gimpdatadir=\${prefix}/share/gimp/$GIMP_API
gimpsysconfdir=\${prefix}/etc/gimp/$GIMP_API
gimplocaledir=\${prefix}/share/locale
datarootdir=\${prefix}/share

Name: GIMP
Description: GIMP Library (headers from source tarball, libs from GIMP.app)
Version: $GIMP_FULL
Cflags: -I\${includedir}/gimp-$GIMP_API $DEPS_CFLAGS
Libs:$BUNDLE_LIBS -Wl,-rpath,$GIMP_APP/Contents/Resources$ALIAS_FLAGS
EOF
mkdir -p "$DEV/lib/gimp/$GIMP_API"

export PKG_CONFIG_PATH="$DEV/lib/pkgconfig:$BREW/lib/pkgconfig"
pkg-config --exists "gimp-$GIMP_API" || die "self-check failed: fake gimp-$GIMP_API.pc does not resolve"

# ---------------------------------------------------------------- configure
BUILD="$WORK/build-gmic$GMIC_VERSION-gimp$GIMP_FULL-qt$QT_CHOICE"
log "configuring in $BUILD"
rm -rf "$BUILD"

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DGMIC_QT_HOST=gimp3
  -DENABLE_SYSTEM_GMIC=OFF
  -DBUILD_WITH_QT6=$BUILD_WITH_QT6
  -DCMAKE_PREFIX_PATH="$QT_PREFIX;$BREW"
)
if [ -e "$BREW/opt/libomp/lib/libomp.dylib" ]; then
  CMAKE_ARGS+=(
    -DOpenMP_C_FLAGS="-Xclang -fopenmp -I$BREW/opt/libomp/include"
    -DOpenMP_C_LIB_NAMES=omp
    -DOpenMP_CXX_FLAGS="-Xclang -fopenmp -I$BREW/opt/libomp/include"
    -DOpenMP_CXX_LIB_NAMES=omp
    -DOpenMP_omp_LIBRARY="$BREW/opt/libomp/lib/libomp.dylib"
  )
else
  warn "libomp not found -- building without OpenMP (slower filters)"
fi

cmake -S "$WORK/gmic-$GMIC_VERSION/gmic-qt" -B "$BUILD" "${CMAKE_ARGS[@]}"

# ---------------------------------------------------------------- build
log "building with $JOBS jobs (the G'MIC core is huge -- expect 10-30 minutes)"
cmake --build "$BUILD" -j "$JOBS"

PLUGIN="$BUILD/gmic_gimp_qt"
[ -x "$PLUGIN" ] || die "build finished but $PLUGIN is missing"

# ---------------------------------------------------------------- verify
log "verifying linkage"
if otool -L "$PLUGIN" | grep -E "$BREW/(opt|Cellar)/(glib|gegl|babl)/" ; then
  die "plug-in links Homebrew glib/gegl/babl -- it would crash inside GIMP. Aborting install."
fi
otool -L "$PLUGIN" | grep -q '@rpath/lib/libgimp-' \
  || die "plug-in does not link the bundle's libgimp -- something went wrong"

# ---------------------------------------------------------------- install
log "signing and installing"
codesign --force --sign - "$PLUGIN"
mkdir -p "$PLUGIN_DIR"
cp "$PLUGIN" "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/gmic_gimp_qt"
xattr -d com.apple.quarantine "$PLUGIN_DIR/gmic_gimp_qt" 2>/dev/null || true

# Smoke test: run standalone. Expected: libgimp complains it must be run by
# GIMP (non-zero exit is fine). A dyld error or crash signal means trouble.
set +e
out="$("$PLUGIN_DIR/gmic_gimp_qt" 2>&1)"
rc=$?
set -e
if printf '%s' "$out" | grep -qiE 'library not loaded|symbol not found|image not found'; then
  printf '%s\n' "$out" >&2
  die "smoke test failed: a library did not resolve (see above). Not usable; check otool -L '$PLUGIN_DIR/gmic_gimp_qt'"
elif [ "$rc" -ge 128 ]; then
  printf '%s\n' "$out" >&2
  warn "smoke test: plug-in crashed with signal $((rc-128)) when run standalone. Try it inside GIMP anyway."
else
  log "smoke test OK: plug-in starts and all libraries resolve"
fi

log "DONE. G'MIC $GMIC_VERSION installed for GIMP $GIMP_FULL."
log "Restart GIMP, open an image, and look under:  Filters -> G'MIC-Qt"
log "(the first launch downloads the filter catalog; ~1000 filters)"
log "To update later, just re-run this script. To remove: $0 --uninstall"

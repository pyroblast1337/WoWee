#!/usr/bin/env bash
# Build a Wowee AppImage from an existing CMake build tree.
#
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j4
#   packaging/appimage/build-appimage.sh [build-dir]      # default: ./build
#
# Output: <build-dir>/appimage/Wowee-<version>-<arch>.AppImage (any older one
# in that directory is removed).
#
# What goes in, mirroring the "Package" step of .github/workflows/release.yml:
# the client, the asset tools if they were built, assets/ (without the
# soundtrack), the git-tracked Data/ files and the bundled addons - all
# beside the executable, because that is where the client looks.
#
# What stays out: the game data itself (extract it with --asset-extract or
# --asset-manager; it lands under ~/.local/share/wowee), and libvulkan, which
# has to match the GPU driver on the machine that runs the AppImage.
#
# The shared libraries the binary links (SDL3, ffmpeg, ...) are copied in, so
# the AppImage runs with the versions it was built against rather than the
# ones on the host. Build it on the oldest distribution you want it to run on:
# glibc is not bundled.
#
# Environment overrides: OUT_DIR, ARCH, VERSION, LINUXDEPLOY, APPIMAGETOOL, and
# GIT_ROOT - the git checkout to take the tracked Data/ files and the version
# from, for when this script runs from a copy of the tree without a .git (the
# container build, which passes the checkout it mounts).
#
# The Linux container build (container/run-linux.sh) and the CI workflows run
# this script; it is how every Linux build ends.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$HERE/../.." && pwd)"
BUILD_DIR="$(cd "${1:-$SRC_DIR/build}" && pwd)"
BIN_DIR="$BUILD_DIR/bin"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/appimage}"
APPDIR="$OUT_DIR/AppDir"
ARCH="${ARCH:-$(uname -m)}"
GIT_ROOT="${GIT_ROOT:-$SRC_DIR}"

# safe.directory: the checkout may be a bind mount owned by another user.
git_root() { git -c safe.directory='*' -C "$GIT_ROOT" "$@"; }

VERSION="${VERSION:-$(git_root describe --tags --always --dirty 2>/dev/null || echo dev)}"

# Pinned, and checked against these hashes after download.
LINUXDEPLOY_TAG=1-alpha-20250213-2
APPIMAGETOOL_TAG=1.9.1
declare -A LINUXDEPLOY_SHA256=(
    [x86_64]=4648f278ab3ef31f819e67c30d50f462640e5365a77637d7e6f2ad9fd0b4522a
    [aarch64]=06706ac8189797dccd36bd384105892cb5e6e71f784f4df526cc958adc223cd6
)
declare -A APPIMAGETOOL_SHA256=(
    [x86_64]=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    [aarch64]=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
)

if [ ! -x "$BIN_DIR/wowee" ]; then
    echo "error: $BIN_DIR/wowee not found - build the project first." >&2
    exit 1
fi
if [ -z "${LINUXDEPLOY_SHA256[$ARCH]:-}" ]; then
    echo "error: unsupported architecture '$ARCH' (x86_64 and aarch64 only)." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# Download a tool once, verify it, and print its path.
fetch_tool() {
    local name="$1" url="$2" sha="$3"
    local path="$OUT_DIR/$name"
    if [ ! -x "$path" ]; then
        echo "Downloading $name" >&2
        curl -fsSL -o "$path.part" "$url"
        echo "$sha  $path.part" | sha256sum -c - >&2
        chmod +x "$path.part"
        mv "$path.part" "$path"
    fi
    echo "$path"
}

LINUXDEPLOY="${LINUXDEPLOY:-$(fetch_tool "linuxdeploy-$ARCH.AppImage" \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/$LINUXDEPLOY_TAG/linuxdeploy-$ARCH.AppImage" \
    "${LINUXDEPLOY_SHA256[$ARCH]}")}"
APPIMAGETOOL="${APPIMAGETOOL:-$(fetch_tool "appimagetool-$ARCH.AppImage" \
    "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_TAG/appimagetool-$ARCH.AppImage" \
    "${APPIMAGETOOL_SHA256[$ARCH]}")}"

# The tools are AppImages themselves; unpack-and-run needs no FUSE.
export APPIMAGE_EXTRACT_AND_RUN=1

# ---- Stage the files the client expects beside its executable ----
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
APP_BIN="$APPDIR/usr/bin"

install -m 755 "$BIN_DIR/wowee" "$APP_BIN/"
EXTRA_EXECUTABLES=()
for tool in asset_extract wowee_assets; do
    if [ -x "$BIN_DIR/$tool" ]; then
        install -m 755 "$BIN_DIR/$tool" "$APP_BIN/"
        EXTRA_EXECUTABLES+=(--executable "$APP_BIN/$tool")
    else
        echo "note: $tool was not built; the AppImage will not include it." >&2
    fi
done

# The optional AMD FSR3 runtime (WOWEE_BUILD_AMD_FSR3_RUNTIME). The client
# loads it from its own directory.
if [ -f "$BIN_DIR/libamd_fidelityfx_vk.so" ]; then
    install -m 755 "$BIN_DIR/libamd_fidelityfx_vk.so" "$APP_BIN/"
fi

# assets/ without the soundtrack, as the release archives do.
cp -a "$BIN_DIR/assets" "$APP_BIN/assets"
rm -rf "$APP_BIN/assets/Original Music"

# Data/ holds the expansion profiles. Only tracked files: in a development
# tree the same directory can also hold a multi-gigabyte extraction.
if git_root rev-parse --git-dir >/dev/null 2>&1; then
    git_root ls-files -z Data \
        | tar -C "$GIT_ROOT" --null -T - -cf - \
        | tar -C "$APP_BIN" -xf -
else
    echo "note: not a git checkout, copying all of Data/." >&2
    cp -a "$SRC_DIR/Data" "$APP_BIN/Data"
fi

if [ -d "$BIN_DIR/addons" ]; then
    cp -a "$BIN_DIR/addons" "$APP_BIN/addons"
else
    cp -a "$SRC_DIR/addons" "$APP_BIN/addons"
fi

# linuxdeploy takes the icon's file name as the icon name, and the desktop
# file refers to it as "wowee".
cp "$SRC_DIR/assets/Wowee.png" "$OUT_DIR/wowee.png"

# ---- Bundle the shared libraries and lay out the AppDir ----
# linuxdeploy asks dpkg which package owns each file it deploys, copies that
# package's licence, and warns "Could not find copyright files" for a file no
# package owns. For the client, its tools and the icon that is always so, and
# their licence is added below, so those warnings are filtered out. Any other
# one stays visible: a library no package owns, SDL3 included when it was not
# installed as one (the builder image does).
# awk rather than grep -v: its status is 0 however many lines it passes, so
# with pipefail the status of the pipeline is linuxdeploy's.
echo "note: hiding linuxdeploy's 'Could not find copyright files' warnings for the client, its tools and the icon; their licence is added below." >&2
"$LINUXDEPLOY" --appdir "$APPDIR" \
    --executable "$APP_BIN/wowee" ${EXTRA_EXECUTABLES[@]+"${EXTRA_EXECUTABLES[@]}"} \
    --desktop-file "$HERE/wowee.desktop" \
    --icon-file "$OUT_DIR/wowee.png" \
    --custom-apprun "$HERE/AppRun" 2>&1 \
    | awk -v bin="Could not find copyright files for file $APPDIR/usr/bin/" \
          -v icon="Could not find copyright files for file $OUT_DIR/wowee.png" \
          'index($0, bin) == 0 && index($0, icon) == 0 { print; fflush() }'

# Licences for what linuxdeploy could not find a package for: this project's
# own, and SDL3's when it was installed without a package, as in a native
# build (in the container it is a package, and linuxdeploy copied its licence).
DOC_DIR="$APPDIR/usr/share/doc"
install -d "$DOC_DIR/wowee"
install -m 644 "$SRC_DIR/LICENSE" "$SRC_DIR/NOTICE" "$DOC_DIR/wowee/"
if compgen -G "$APPDIR/usr/lib/libSDL3.so*" >/dev/null \
        && ! compgen -G "$DOC_DIR/*sdl3*/copyright" >/dev/null; then
    for sdl_license in /usr/local/share/licenses/SDL3/LICENSE.txt \
                       /usr/share/licenses/SDL3/LICENSE.txt; do
        if [ -f "$sdl_license" ]; then
            install -d "$DOC_DIR/SDL3"
            install -m 644 "$sdl_license" "$DOC_DIR/SDL3/"
            break
        fi
    done
    [ -d "$DOC_DIR/SDL3" ] || echo "note: SDL3 is bundled but its LICENSE.txt was not found." >&2
fi

# The Vulkan loader must match the GPU driver of the host, not of this build
# machine; the system's copy is found through the normal library search path.
rm -f "$APPDIR"/usr/lib/libvulkan.so*

# ---- Pack ----
OUTPUT="$OUT_DIR/Wowee-$VERSION-$ARCH.AppImage"
rm -f "$OUT_DIR"/Wowee-*.AppImage
ARCH="$ARCH" VERSION="$VERSION" "$APPIMAGETOOL" --no-appstream "$APPDIR" "$OUTPUT"
echo "Built $OUTPUT"

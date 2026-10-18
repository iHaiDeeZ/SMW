#!/usr/bin/env bash
# Package the PS4 build (scripts/rebuild-smw.sh) as SMW, SMWR00001 (IV0000-SMWR00001_00-SMWRECOMPPS40000.pkg).
#   SMW_VERSION=00.01 package-smw.sh
# The eboot carries code recompiled from YOUR dump of the game: the package is for your console only, never share it.
# The game's data (analysis/, extract/romfs, spirv/) is not in it: scripts/stage-data.sh, then FTP to /data/SMW
# (scripts/upload-data.py). SMW_BUNDLE_DATA=1 puts it in the package as /app0/data instead.
# Older builds stay in out/ (delete them by hand). The console gets the package from Windows with
# scripts/upload-to-console.sh (uploads sent from WSL were lost on the console, see Resonance).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/ps4-env.sh"
BUILD="${SMW_BUILD:-$PS4_BUILD_ROOT/build/wonder}"
SRC="${WONDER_SRC:-$PS4_BUILD_ROOT/src/wonder}"
EBOOT="$BUILD/wonder_eboot/eboot.bin"
VERSION="${SMW_VERSION:-00.01}"

[ -f "$EBOOT" ] || { echo "missing $EBOOT: build first" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9][0-9]\.[0-9][0-9]$ ]] || { echo "version must look like 01.00" >&2; exit 1; }
STAGE="$PS4_BUILD_ROOT/build/smw-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/sce_sys" "$STAGE/fonts"
cp "$EBOOT" "$STAGE/eboot.bin"
cp "$HERE/../sce_sys/icon0.png" "$HERE/../sce_sys/pic1.png" "$STAGE/sce_sys/"
echo "$VERSION" > "$STAGE/version.txt"
# Shared fonts (runtime/src/hle_pl.cpp looks in /data/SMW/fonts first, then here): upstream's own button glyph font
# (NintendoExtended codepoints, MIT, as the repository) and Fredoka (SIL OFL 1.1) for the standard font.
cp "$SRC/android/wonder/assets/fonts/shared_5.ttf" "$SRC/android/wonder/assets/fonts/Fredoka.ttf" "$STAGE/fonts/"
cp "$SRC/android/wonder/assets/licenses/OFL-Fredoka.txt" "$STAGE/fonts/"
# The boot screen (runtime/src/ps4/ps4_boot_screen.cpp reads /app0/boot): the art and its glyphs, drawn here.
python3 "$HERE/make-art.py" "$SRC/android/wonder/assets/fonts/Fredoka.ttf" "$STAGE/boot" --boot
rm -f "$STAGE/boot/preview.png"
# The game's data stays out of the package (on the console's /data/SMW, scripts/upload-data.py). SMW_BUNDLE_DATA=1
# puts it in as /app0/data instead (~4 GB more; the runtime reads it there before /data/SMW, platform_ps4.cpp
# content_root), hard links of scripts/stage-data.sh's copy.
if [ "${SMW_BUNDLE_DATA:-0}" = 1 ]; then
    DATA="${SMW_DATA_STAGE:-$PS4_BUILD_ROOT/data-stage/SMW}"
    for d in extract spirv analysis; do
        [ -d "$DATA/$d" ] || { echo "missing $DATA/$d: run scripts/stage-data.sh (or SMW_BUNDLE_DATA=0)" >&2; exit 1; }
    done
    mkdir -p "$STAGE/data"
    cp -al "$DATA/extract" "$DATA/spirv" "$DATA/analysis" "$STAGE/data/"
    echo "game data bundled: $(du -sh "$STAGE/data" | cut -f1)"
fi
# PkgTool's pkg_build crashes ("Sequence contains no elements") on empty folders.
find "$STAGE" -type d -empty -delete
# Vulkan (RADV on GNM) runs under the plain homebrew identity (4.5 GiB of direct memory).
PKG="$(SFO_STYLE=plain NO_RIGHT_SPRX=1 DOLPHIN_PS4_MODULES_DIR=/nonexistent "$HERE/make-pkg.sh" "$STAGE" SMWR00001 "SMW" "$VERSION" SMWRECOMPPS4 "$PS4_BUILD_ROOT/out" | tail -1)"
ls -la "$PKG"
# a copy next to the repo (E:\PS4 Projects\SMW\out), easy to find from Windows; *.pkg is ignored by git
mkdir -p "$HERE/../out"
NAME="SMW-v$VERSION.pkg"
cp "$PKG" "$HERE/../out/$NAME"
# Older packages stay (the user keeps them; v00.23 was the first with the game data inside).
# Keep the symbols of every packaged build: crash logs must be symbolized against the exact binary.
mkdir -p "$PS4_BUILD_ROOT/oelf"
cp "$BUILD/wonder_eboot/wonder.oelf" "$PS4_BUILD_ROOT/oelf/v$VERSION.oelf"
cp "$BUILD/wonder" "$PS4_BUILD_ROOT/oelf/v$VERSION.elf"
echo "now, from Windows (Git Bash): scripts/upload-to-console.sh out/$NAME"

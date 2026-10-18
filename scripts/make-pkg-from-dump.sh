#!/usr/bin/env bash
# Your SMW package from YOUR Super Mario Bros. Wonder 1.0.0 dump and keys, in one go (windows/SMW-Data-Tool.cmd runs
# this in WSL when "Build my package" is ticked; it works the same from any Ubuntu shell):
#
#   make-pkg-from-dump.sh --game <.nsp/.xci> --prod <prod.keys> [--title <title.keys>] --out <folder> [--version 00.29]
#
#   1. checks: clang 21 and PacBrew's toolchain (sudo bash scripts/install-build-deps.sh installs them), memory, space
#   2. the SDK: the prebuilt PS4 libraries (libc++ 21 sysroot, RADV) from this project's GitHub release, checked
#      against its SHA-256, and Vulkan-Headers 1.4.357
#   3. the game's code: upstream's importer decrypts the dump with your keys, its recompiler turns main and sdk into
#      C++ (~1.4 GB). Shared with scripts/make-data.sh: a dump it already imported is not imported again.
#   4. the build: the C++ and the PS4 runtime compiled into eboot.bin (an hour or more on 4 cores, ~1.5 GB of memory
#      per compile job)
#   5. the package: <out>/SMW-v<version>.pkg
#
# Needs ~40 GB free in WSL. Your keys are copied for the import and deleted after it. Nothing is uploaded anywhere.
# The package carries the game's code: it is for your own console, never share it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="" PROD="" TITLE="" OUT="" VERSION="$(cat "$HERE/../VERSION")"
while [ $# -gt 0 ]; do
    case "$1" in
        --game) GAME="$2"; shift 2 ;;
        --prod) PROD="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "--out: where the package goes" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9][0-9]\.[0-9][0-9]$ ]] || { echo "--version must look like 00.29" >&2; exit 1; }

# The SDK of this release (scripts/make-sdk.sh).
SDK_URL="https://github.com/iHaiDeeZ/SMW/releases/download/sdk-1/SMW-PS4-SDK-1.tar.xz"
SDK_SHA256="15e7927cb01fa877c04ef59beca33907cb7fe3d39b035e3e296661c3a0f2e026"

WORK="${SMW_WORK:-$HOME/smw-data-tool}"
export WONDER_SRC="$WORK/wonder"
export PS4_BUILD_ROOT="$WORK/ps4"
export PS4_SYSROOT="$PS4_BUILD_ROOT/sysroot"
G="$WONDER_SRC/private/wonder"
mkdir -p "$WORK" "$PS4_BUILD_ROOT"/{build,logs,out}

step() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

step "1/5 checks"
missing=()
for c in clang-21 clang++-21 git cmake ninja c++ curl xz python3; do command -v "$c" >/dev/null || missing+=("$c"); done
python3 -c 'import venv, ensurepip, PIL' 2>/dev/null || missing+=(python3-venv/python3-pil)
[ -x /opt/pacbrew/ps4/openorbis/bin/create-fself ] || missing+=(PacBrew)
if [ ${#missing[@]} -gt 0 ]; then
    echo "missing: ${missing[*]}" >&2
    echo "install them once with:  sudo bash $HERE/install-build-deps.sh" >&2
    exit 1
fi
mem_gb=$(awk '/MemTotal/ { print int($2 / 1048576) }' /proc/meminfo)
free_gb=$(df -P -BG "$WORK" | awk 'NR == 2 { print int($4) }')
echo "memory: ${mem_gb} GB, free in $WORK: ${free_gb} GB, cores: $(nproc)"
[ "$free_gb" -ge 30 ] || { echo "not enough space: about 40 GB are needed in $WORK" >&2; exit 1; }
[ "$mem_gb" -ge 7 ] || echo "(less than 8 GB of memory: the build runs one file at a time and takes long)"
# The configure and link steps break on a path with a space (the linker script's flags): build from a copy of these
# scripts under $WORK.
REPO="$WORK/repo"
rm -rf "$REPO"
mkdir -p "$REPO"
tar -C "$HERE/.." -cf - --exclude=./out --exclude=./.git --exclude=./docs . | tar -C "$REPO" -xf -
S="$REPO/scripts"

step "2/5 the PS4 SDK"
if [ "$(cat "$PS4_BUILD_ROOT/sdk.txt" 2>/dev/null)" != "$SDK_SHA256" ]; then
    curl -fL --progress-bar "$SDK_URL" -o "$WORK/sdk.tar.xz"
    echo "$SDK_SHA256  $WORK/sdk.tar.xz" | sha256sum -c --quiet - || { echo "the SDK download is damaged: start again" >&2; rm -f "$WORK/sdk.tar.xz"; exit 1; }
    rm -rf "$PS4_BUILD_ROOT/sysroot" "$PS4_BUILD_ROOT/build/mesa" "$WORK/sdk"
    mkdir -p "$WORK/sdk"
    tar -C "$WORK/sdk" -xJf "$WORK/sdk.tar.xz"
    mv "$WORK/sdk/smw-ps4-sdk/sysroot" "$PS4_BUILD_ROOT/sysroot"
    mv "$WORK/sdk/smw-ps4-sdk/build/mesa" "$PS4_BUILD_ROOT/build/mesa"
    rm -rf "$WORK/sdk" "$WORK/sdk.tar.xz"
    echo "$SDK_SHA256" > "$PS4_BUILD_ROOT/sdk.txt"
fi
VKH="$PS4_BUILD_ROOT/third_party/Vulkan-Headers-1.4.357"
[ -d "$VKH/include" ] || git clone -q --depth 1 --branch v1.4.357 https://github.com/KhronosGroup/Vulkan-Headers "$VKH"
echo "SDK: ready"

step "3/5 the game's code (your dump and keys)"
bash "$S/clone-wonder.sh"
if [ -f "$G/analysis/main.bin" ] && [ -f "$G/exefs/main" ] && [ -f "$G/exefs/sdk" ]; then
    echo "already imported: $G"
else
    [ -f "$GAME" ] || { echo "no game dump at '$GAME' (--game: the .nsp or .xci)" >&2; exit 1; }
    [ -f "$PROD" ] || { echo "no prod.keys at '$PROD' (--prod)" >&2; exit 1; }
    [ -z "$TITLE" ] || [ -f "$TITLE" ] || { echo "no title.keys at '$TITLE'" >&2; exit 1; }
    IN="$WORK/input"
    rm -rf "$IN"
    mkdir -p "$IN"
    chmod 700 "$IN"
    trap 'rm -rf "$IN"' EXIT  # the copies of your keys go, whatever happens
    cp "$PROD" "$IN/prod.keys"
    [ -z "$TITLE" ] || cp "$TITLE" "$IN/title.keys"
    chmod 600 "$IN"/*.keys
    ext="${GAME##*.}"
    ln -s "$(readlink -f "$GAME")" "$IN/game.${ext,,}"
    bash "$S/prepare-game.sh" "$IN" import
    rm -rf "$IN"
fi
if [ -f "$G/gen/main/.done" ] && [ -f "$G/gen/sdk/.done" ]; then
    echo "already recompiled: $G/gen"
else
    rm -rf "$G/gen"
    bash "$S/prepare-game.sh" "$WORK" recompile
    touch "$G/gen/main/.done" "$G/gen/sdk/.done"
fi

step "4/5 the build"
# ~1.5 GB of memory per compile job at the peak (the recompiled files are big).
jobs=$(( mem_gb * 10 / 16 ))
[ "$jobs" -le "$(nproc)" ] || jobs=$(nproc)
[ "$jobs" -ge 1 ] || jobs=1
echo "compiling with $jobs jobs (log: $PS4_BUILD_ROOT/logs/build.log)"
BUILD="$PS4_BUILD_ROOT/build/wonder"
bash "$S/logrun.sh" configure bash "$S/configure-smw.sh" || { tail -40 "$PS4_BUILD_ROOT/logs/configure.log"; exit 1; }
rm -f "$BUILD/wonder_eboot/eboot.bin"
L="$PS4_BUILD_ROOT/logs/build.log"
# Ninja's "[done/total]" lines become "build N%" lines (once per percent), the rest stays in the log.
set +e
( source "$S/ps4-env.sh" && ninja -C "$BUILD" -j"$jobs" ) 2>&1 | tee "$L" | awk '
    match($0, /^\[[0-9]+\/[0-9]+\]/) {
        split(substr($0, 2, RLENGTH - 2), a, "/"); p = int(100 * a[1] / a[2])
        if (p != last) { print "build " p "%"; fflush(); last = p }
        next
    }
    /error:|FAILED:/ { print; fflush() }'
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" != 0 ] || [ ! -f "$BUILD/wonder_eboot/eboot.bin" ]; then
    echo "the build failed: the first errors in $L:" >&2
    grep -m 20 "error:" "$L" >&2 || tail -30 "$L" >&2
    exit 1
fi

step "5/5 the package"
SMW_VERSION="$VERSION" SMW_BUNDLE_DATA=0 bash "$S/package-smw.sh" | grep -v "upload-to-console" || true
PKG="$REPO/out/SMW-v$VERSION.pkg"
[ -f "$PKG" ] || { echo "no package was made" >&2; exit 1; }
mkdir -p "$OUT"
cp "$PKG" "$OUT/SMW-v$VERSION.pkg"
echo
echo "done: $OUT/SMW-v$VERSION.pkg ($(du -h "$OUT/SMW-v$VERSION.pkg" | cut -f1))"
echo "install it with GoldHEN's Package Installer (put it in /data/pkg on the PS4). It is your game: never share it."

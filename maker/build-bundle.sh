#!/usr/bin/env bash
# Maintainers, on Linux: assembles SMW Maker's tools/ folder, everything the Windows app runs, built or downloaded
# from the sources named here (no game files): the importer, Python with the recompiler's packages, the shader
# translator, .NET, clang 21, CMake, Ninja, OpenOrbis' PS4 files and tools, PkgTool, and the PS4 SDK.
#   maker/build-bundle.sh <out dir>        (then maker/pack.sh makes the release zip)
# Needs: the SDK's build tree (scripts/make-sdk.sh's inputs), curl, unzip, xz, python3, mingw-w64 (x86_64-w64-mingw32-g++),
# a .NET 10 SDK (DOTNET, default upstream's private/third_party/dotnet).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
W="${MAKER_WORK:-$HOME/maker-build}"
DL="$W/dl"
mkdir -p "$W/src" "$DL" "$OUT/tools"
T="$OUT/tools"
PSB="${PS4_BUILD_ROOT:-$HOME/smw-build}"
WONDER="${WONDER_SRC:-$PSB/src/wonder}"
DOTNET="${DOTNET:-$WONDER/private/third_party/dotnet/dotnet}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

fetch() {  # fetch <url> <file> <sha256>
    [ -f "$DL/$2" ] || curl -fL --retry 3 -o "$DL/$2.part" "$1" && { [ -f "$DL/$2" ] || mv "$DL/$2.part" "$DL/$2"; }
    echo "$3  $DL/$2" | sha256sum -c --quiet - || { echo "checksum mismatch: $2" >&2; exit 1; }
}
unzip_to() { mkdir -p "$2"; python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"; }
step() { printf '\n== %s\n' "$*"; }

step "create-fself, create-gp4 (OpenOrbis, the commits PacBrew packages, for Windows)"
GO="$W/go/bin/go"
[ -x "$GO" ] || { fetch https://go.dev/dl/go1.23.4.linux-amd64.tar.gz go.tar.gz 6924efde5de86fe277676e929dc9917d466efa02fb934197bc2eba35d5680971; tar -xzf "$DL/go.tar.gz" -C "$W"; }
mkdir -p "$T/openorbis/bin"
gitat() {  # gitat <repo url> <commit> <dir>: that commit's tree (GitHub's generated archives aren't byte-stable)
    [ "$(git -C "$3" rev-parse HEAD 2>/dev/null)" = "$2" ] && return
    rm -rf "$3"; git init -q "$3"; git -C "$3" fetch -q --depth 1 "$1" "$2"; git -C "$3" checkout -q FETCH_HEAD
}
gitat https://github.com/OpenOrbis/create-fself 30d2e10507f55124cf21e85e19825482e4f93c87 "$W/src/create-fself"
gitat https://github.com/OpenOrbis/create-gp4 bf8e66e9e9bdd92e41e1697893bc8098a151fa24 "$W/src/create-gp4"
( cd "$W/src/create-fself/cmd/create-fself" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 "$GO" build -o "$T/openorbis/bin/create-fself.exe" -modfile=go-linux.mod )
( cd "$W/src/create-gp4/cmd/create-gp4" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 "$GO" build -o "$T/openorbis/bin/create-gp4.exe" )
ls -la "$T/openorbis/bin"

step "clang 21 for Windows (LLVM 21.1.8, the version the Linux build uses): the compiler, linker and archiver only"
fetch https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.8/clang+llvm-21.1.8-x86_64-pc-windows-msvc.tar.xz llvm-win64.tar.xz 749d22f565fcd5718dbed06512572d0e5353b502c03fe1f7f17ee8b8aca21a47
L=clang+llvm-21.1.8-x86_64-pc-windows-msvc
rm -rf "$T/llvm"; mkdir -p "$T/llvm"
tar -xJf "$DL/llvm-win64.tar.xz" -C "$T/llvm" --strip-components=1 \
    $L/bin/clang.exe $L/bin/ld.lld.exe $L/bin/llvm-ar.exe $L/bin/llvm-ranlib.exe $L/bin/llvm-readelf.exe \
    $L/lib/clang/21/include
du -sh "$T/llvm"

step "OpenOrbis' PS4 files (headers, libc, crt, library stubs, port libraries) from PacBrew, without its Linux tools"
PB="$W/pacbrew-root"
[ -d "$PB/opt/pacbrew/ps4/openorbis/lib" ] || { mkdir -p "$PB"; bash "$REPO/scripts/fetch-pacbrew.sh" "$PB"; }
curl -fsSL https://pacman.mydedibox.fr/pacbrew/packages/pacbrew.files -o "$W/pacbrew.files"
rm -rf "$W/pbfiles"; mkdir -p "$W/pbfiles"; tar -xf "$W/pacbrew.files" -C "$W/pbfiles"
# Host programs: clang 12 (clang 21 replaces it), the Go and .NET tools (built for Windows above and below), readoelf.
for p in clang create-fself create-gp4 pkgtools readoelf pkg-config; do
    awk '/%FILES%/ { f = 1; next } f && !/\/$/' "$W"/pbfiles/ps4-openorbis-$p-[0-9]*/files
done | sed 's|^opt/pacbrew/ps4/openorbis/||' | sort -u > "$W/pacbrew-host-files.txt"
( cd "$PB/opt/pacbrew/ps4/openorbis" && find . -type f | sed 's|^\./||' | grep -vxF -f "$W/pacbrew-host-files.txt" \
    | grep -v '^bin/' | tar -cf - -T - ) | tar -xf - -C "$T/openorbis"
du -sh "$T/openorbis"

step "the PS4 SDK (sdk-1: libc++ 21 sysroot, RADV)"
fetch https://github.com/iHaiDeeZ/SMW/releases/download/sdk-1/SMW-PS4-SDK-1.tar.xz sdk-1.tar.xz 15e7927cb01fa877c04ef59beca33907cb7fe3d39b035e3e296661c3a0f2e026
rm -rf "$T/sdk"; mkdir -p "$T/sdk"
tar -xJf "$DL/sdk-1.tar.xz" -C "$T/sdk" --strip-components=1
[ -d "$W/src/Vulkan-Headers" ] || git clone -q --depth 1 --branch v1.4.357 https://github.com/KhronosGroup/Vulkan-Headers "$W/src/Vulkan-Headers"
mkdir -p "$T/sdk/Vulkan-Headers"
cp -r "$W/src/Vulkan-Headers/include" "$W/src/Vulkan-Headers/LICENSE.md" "$T/sdk/Vulkan-Headers/"
du -sh "$T/sdk"

step "CMake 4.2.3 (the Linux build's version) and Ninja 1.12.1 for Windows"
fetch https://github.com/Kitware/CMake/releases/download/v4.2.3/cmake-4.2.3-windows-x86_64.zip cmake-win.zip eb4ebf5155dbb05436d675706b2a08189430df58904257ae5e91bcba4c86933c
fetch https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip ninja-win.zip f550fec705b6d6ff58f2db3c374c2277a37691678d6aba463adcbb129108467a
rm -rf "$T/cmake" "$W/cmake-x"; unzip_to "$DL/cmake-win.zip" "$W/cmake-x"
mkdir -p "$T/cmake"
cp -r "$W"/cmake-x/cmake-*/bin "$W"/cmake-x/cmake-*/share "$T/cmake/"
rm -rf "$T/cmake/share/doc" "$T/cmake/bin/cmake-gui.exe" "$T/cmake/bin/cmcldeps.exe"
unzip_to "$DL/ninja-win.zip" "$T/cmake/bin"
du -sh "$T/cmake"

step "upstream's importer (nximport) for Windows: mingw-w64, with maker/nximport-win's POSIX shims"
I="$WONDER/android/wonder/importer"
x86_64-w64-mingw32-g++-posix -std=c++17 -O2 -static -D_FILE_OFFSET_BITS=64 -I "$HERE/nximport-win" \
    -include "$HERE/nximport-win/compat.h" "$I/nximport_cli.cpp" "$I/nximport.cpp" "$I/nxcrypto.cpp" \
    -o "$T/nximport.exe"
ls -la "$T/nximport.exe"

step "Python 3.14 (embeddable) with the recompiler's packages and Pillow"
fetch https://www.python.org/ftp/python/3.14.4/python-3.14.4-embed-amd64.zip python-embed.zip cda80a9b1e75c0f1b4f9872ca1b417f0d19bce32facc811aea9180e70fad5fb9
rm -rf "$T/python"; unzip_to "$DL/python-embed.zip" "$T/python"
# No ._pth: a normal sys.path (the script's folder, Lib/site-packages); the app clears PYTHONHOME/PYTHONPATH.
rm -f "$T"/python/python*._pth
SP="$T/python/Lib/site-packages"; mkdir -p "$SP"
"${PYDL:-$WONDER/private/venv/bin/python}" -m pip download -q --only-binary=:all: --platform win_amd64 --python-version 3.14     --implementation cp -d "$DL/wheels" capstone==5.0.9 lz4==4.4.5 zstandard==0.25.0 fonttools==4.67.0 pillow==12.3.0
while read -r sum whl; do
    echo "$sum  $DL/wheels/$whl" | sha256sum -c --quiet -
    unzip_to "$DL/wheels/$whl" "$SP"
done <<'WHEELS'
732cedbbb56d42e723f14d7af6387f1454194a820b4b96b56d1e53f865ef85d0 capstone-5.0.9-py3-none-win_amd64.whl
4e2c1586b5b6588a47d02e2588170eefdc996b708f2659c44dbe169bd6fcacb5 fonttools-4.67.0-cp314-cp314-win_amd64.whl
92159782a4502858a21e0079d77cdcaade23e8a5d252ddf46b0652604300d7be lz4-4.4.5-cp314-cp314-win_amd64.whl
fdafc9cce40277e0f7a0feabce0ee50dd2fa1800f3b38015e51296b5e814048d pillow-12.3.0-cp314-cp314-win_amd64.whl
c19bcdd826e95671065f8692b5a4aa95c52dc7a02a4c5a0cac46deb879a017a2 zstandard-0.25.0-cp314-cp314-win_amd64.whl
WHEELS
du -sh "$T/python"

step ".NET 10.0.12 runtime (the Linux build's) with the shader translator and PkgTool"
curl -fsSL -o "$DL/dotnet-win.zip" https://builds.dotnet.microsoft.com/dotnet/Runtime/10.0.12/dotnet-runtime-10.0.12-win-x64.zip
echo "844fa99e16fd6f44e0a7c29def7a82d7846902334d6a955248a9519a4dddb3f5acceb9c9223bef69f8c83b8ae2417537e5b76dddf79fb7117dc85b5039bc1297  $DL/dotnet-win.zip" | sha512sum -c --quiet -
rm -rf "$T/dotnet"; unzip_to "$DL/dotnet-win.zip" "$T/dotnet"
# Upstream's shader harness (scripts/prepare-game.sh shaders builds it), managed code only: the same files run here.
H="$WONDER/private/build/spirv_harness/bin/Release/net10.0"
[ -f "$H/spirv_harness.dll" ] || { echo "build the shader harness first (scripts/prepare-game.sh <dir> shaders)" >&2; exit 1; }
rm -rf "$T/harness"; mkdir -p "$T/harness"
cp "$H"/*.dll "$H"/*.json "$T/harness/"
# PkgTool with the PlayGo slack (scripts/build-pkgtool.sh), managed code only as well.
P="$PSB/tools/pkgtool-fixed"
[ -f "$P/PkgTool.Core.dll" ] || { echo "build PkgTool first (scripts/build-pkgtool.sh)" >&2; exit 1; }
rm -rf "$T/pkgtool"; mkdir -p "$T/pkgtool"
cp "$P"/*.dll "$P"/*.json "$T/pkgtool/"
du -sh "$T/dotnet" "$T/harness" "$T/pkgtool"

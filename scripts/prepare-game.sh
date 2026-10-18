#!/usr/bin/env bash
# Turns your own Super Mario Bros. Wonder 1.0.0 dump into what the PS4 build needs, with upstream's tools
# (docs in ~/smw-build/src/wonder: README.md "Linux", docs/WONDER-DUMP.md, docs/nvn/TRANSLATOR.md, SHADERS.md):
#
#   1. import    the XCI/NSP with your keys -> analysis/{main,sdk}.bin, exefs/, extract/romfs (3.7 GB)
#   2. recompile main and sdk to C++ (~1.4 GB, ~6 min, 2.4 GB of memory)    -> gen/{main,sdk}
#   3. shaders   extract the 12,751 Maxwell blocks and translate them to SPIR-V (.NET 10 + Ryujinx's translator)
#                                                                             -> spirv/<hash>.spv, results.tsv
#
#   prepare-game.sh <folder with prod.keys, title.keys and MarioWonder.xci> [steps...]
#   (steps: import recompile shaders; default all three)
#
# Everything lands in ~/smw-build/src/wonder/private/wonder (upstream's tools only write under private/). Nothing
# here is shared or committed: it is your game. Needs: clang, cmake, ninja, python3-venv, curl; spirv-val (apt
# install spirv-tools) validates the shaders if present.
set -euo pipefail
IN="$(readlink -f "${1:?folder with prod.keys, title.keys and the XCI/NSP}")"; shift
STEPS="${*:-import recompile shaders}"
SRC="${WONDER_SRC:-$HOME/smw-build/src/wonder}"
G="$SRC/private/wonder"
T="$SRC/private/third_party"
VENV="$SRC/private/venv"
mkdir -p "$G" "$T"
cd "$SRC"

has() { [[ " $STEPS " == *" $1 "* ]]; }

if has import; then
    echo "== import"
    cmake -S android/wonder/importer -B private/build/importer -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
    ninja -C private/build/importer nximport
    shopt -s nullglob nocaseglob
    games=("$IN"/*.xci "$IN"/*.nsp)
    shopt -u nullglob nocaseglob
    [ ${#games[@]} -gt 0 ] || { echo "no .xci / .nsp in $IN" >&2; exit 1; }
    keys=("$IN/prod.keys"); [ -f "$IN/title.keys" ] && keys+=("$IN/title.keys")
    private/build/importer/nximport --exefs --out "$G" "${keys[@]}" "${games[@]}"
    ls -la "$G/analysis"
fi

if has recompile; then
    echo "== recompile"
    [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip -q install capstone lz4 zstandard fonttools
    "$VENV/bin/python" -m recomp "$G/exefs/main" "$G/gen/main" --name main --base 0x4000000000
    "$VENV/bin/python" -m recomp "$G/exefs/sdk" "$G/gen/sdk" --name sdk --base 0x4010000000
    du -sh "$G/gen"/*
fi

if has shaders; then
    echo "== shaders"
    [ -x "$VENV/bin/python" ] || { python3 -m venv "$VENV"; "$VENV/bin/python" -m pip -q install capstone lz4 zstandard fonttools; }
    if [ ! -x "$T/dotnet/dotnet" ]; then
        mkdir -p "$T/dotnet"
        curl -L https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.401/dotnet-sdk-10.0.401-linux-x64.tar.gz | tar -xz -C "$T/dotnet"
    fi
    if [ ! -d "$T/ryubing/src" ]; then
        mkdir -p "$T/ryubing"
        curl -L https://codeberg.org/Software_arch/Ryubing/archive/a82350bb77.tar.gz | tar -xz -C "$T/ryubing" --strip-components=1
    fi
    # Invariant globalization: WSL's Ubuntu has no libicu, which .NET would otherwise require.
    export DOTNET_ROOT="$T/dotnet" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
    "$DOTNET_ROOT/dotnet" build tools/maxwell/spirv_harness/SpirvHarness.csproj -c Release -m:2
    H="private/build/spirv_harness/bin/Release/net10.0/spirv_harness.dll"
    P="$VENV/bin/python"; X=tools/maxwell/containers.py; O="$G/shaders_extracted"; R="$G/extract/romfs"
    mkdir -p "$O"
    # The containers (docs/nvn/SHADERS.md, "Where the shaders are"), one output folder each (each run rewrites its
    # manifest.tsv). Layout archives without shaders (131 of 234) extract nothing.
    "$P" $X "$R/Shader/SecredUber.Product.100.product.Nin_NX_NVN.bfsha.zs" --extract "$O/uber" --unique
    "$P" $X "$R/Shader/Secred.Nin_NX_NVN.release.sarc.zs" --extract "$O/secred" --unique
    "$P" $X "$R/Lib/agl/agl_resource.Nin_NX_NVN.release.sarc.zs" --extract "$O/agl" --unique
    "$P" $X "$R/Lib/gsys/gsys_resource.Nin_NX_NVN.release.sarc.zs" --extract "$O/gsys" --unique
    for f in "$R"/Effect/*.Nin_NX_NVN.esetb.byml.zs; do
        n="$(basename "$f" .Nin_NX_NVN.esetb.byml.zs)"
        "$P" $X "$f" --extract "$O/effect_$n" --unique
    done
    for f in "$R"/Layout/*.Nin_NX_NVN.blarc.zs; do
        n="$(basename "$f" .Nin_NX_NVN.blarc.zs)"
        "$P" $X "$f" --extract "$O/layout_$n" --unique >/dev/null 2>&1 || true
        [ -n "$(ls -A "$O/layout_$n" 2>/dev/null | grep -v manifest.tsv)" ] || rm -rf "$O/layout_$n"
    done
    "$P" tools/maxwell/exefs_shaders.py "$G/analysis/main.bin" --extract "$O/exefs"
    if command -v spirv-val >/dev/null; then val=(--spirv-val "$(command -v spirv-val)"); else val=(--no-val); fi
    "$DOTNET_ROOT/dotnet" "$H" --batch "$O" --out "$G/spirv" --jobs "${SHADER_JOBS:-6}" "${val[@]}"
    echo "$(ls "$G/spirv" | grep -c '\.spv$') shaders (12,751 expected)"
fi
echo "done: $G (next: scripts/rebuild-smw.sh, scripts/package-smw.sh, scripts/stage-data.sh)"

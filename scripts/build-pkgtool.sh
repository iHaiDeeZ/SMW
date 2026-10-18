#!/usr/bin/env bash
# PkgTool from LibOrbisPkg's source with one change: room to spare for the PlayGo chunk hashes. The toolchain's
# PkgTool sizes them from an estimate of the package that falls short for the 4 GB package with the game data in it
# ("Playgo Chunk hash file was not allocated enough space"). Built with the .NET SDK scripts/prepare-game.sh fetched;
# scripts/make-pkg.sh uses it when it is there (<build root>/tools/pkgtool-fixed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/ps4-env.sh"
T="$PS4_BUILD_ROOT/tools"
DOTNET="$PS4_BUILD_ROOT/src/wonder/private/third_party/dotnet"
[ -x "$DOTNET/dotnet" ] || { echo "no .NET SDK at $DOTNET: run scripts/prepare-game.sh first" >&2; exit 1; }
mkdir -p "$T"
[ -d "$T/LibOrbisPkg" ] || git clone -q https://github.com/maxton/LibOrbisPkg.git "$T/LibOrbisPkg"
cd "$T/LibOrbisPkg"
sed -i 's|e.DataSize = (uint)(pkgSize / 0x10000L) \* 4;|e.DataSize = (uint)(pkgSize / 0x10000L) * 4 + 0x10000;  // slack: the estimate fell short for a 4 GB image (SMW)|' \
    LibOrbisPkg/PKG/PkgBuilder.cs
grep -q "slack: the estimate" LibOrbisPkg/PKG/PkgBuilder.cs || { echo "the PlayGo sizing line moved: patch by hand" >&2; exit 1; }
sed -i 's|<TargetFramework>netcoreapp3.0</TargetFramework>|<TargetFramework>net10.0</TargetFramework>|' \
    PkgTool.Core/PkgTool.Core.csproj LibOrbisPkg.Core/LibOrbisPkg.Core.csproj
export DOTNET_ROOT="$DOTNET" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_NOLOGO=1
"$DOTNET/dotnet" publish PkgTool.Core/PkgTool.Core.csproj -c Release -o "$T/pkgtool-fixed" | tail -1

#!/usr/bin/env bash
# Maintainers (WSL): SMW Maker's release zip from maker/build-bundle.sh's tools.
#   maker/pack.sh <bundle dir> [out dir]    -> <out>/SMW-Maker-v<VERSION>.zip
#
#   SMW-Maker/SMW-Maker.exe       the app (maker/SMW-Maker.cs, built with Windows' own C# compiler: maker/build-exe.cmd)
#   SMW-Maker/smw/                this repository's build files and maker/smw_maker.py (the pipeline)
#   SMW-Maker/src/wonder/         upstream at patches/BASE.txt with patches/wonder-ps4.patch (its docs left out)
#   SMW-Maker/tools/              the bundle
#   SMW-Maker/THIRD-PARTY.txt     what is in tools/ and where it comes from
# No game files, keys or packages.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BUNDLE="$(cd "$1" && pwd)"
OUT="$(mkdir -p "${2:-$REPO/out}" && cd "${2:-$REPO/out}" && pwd)"
VER="$(cat "$REPO/VERSION")"
W="${MAKER_WORK:-$HOME/maker-build}"
S="$W/pack/SMW-Maker"
rm -rf "$W/pack"
mkdir -p "$S/smw" "$S/src"

# This repository's files the pipeline uses (as committed).
git -C "$REPO" archive HEAD toolchain port sce_sys scripts patches VERSION LICENSE CREDITS.md README.md maker/smw_maker.py \
    | tar -x -C "$S/smw"

# Upstream with the PS4 port, from a clean clone (scripts/clone-wonder.sh), without its docs.
WONDER_SRC="$W/src/wonder-release" SMW_SOURCE_RESET=1 bash "$REPO/scripts/clone-wonder.sh" >/dev/null
mkdir -p "$S/src/wonder"
git -C "$W/src/wonder-release" archive HEAD | tar -x -C "$S/src/wonder" --exclude=docs
# It must be the port: the PS4 branch of upstream's CMakeLists.txt.
grep -q "NX_PS4" "$S/src/wonder/CMakeLists.txt" || { echo "src/wonder is not the PS4 port" >&2; exit 1; }

cp -r "$BUNDLE/tools" "$S/tools"
cp "$HERE/THIRD-PARTY.txt" "$S/THIRD-PARTY.txt"

# The app, with the C# compiler of Windows' .NET Framework 4: SMW_MAKER_EXE names one built with maker/build-exe.cmd,
# else it is built here (needs WSL's interop, which runs Windows programs).
if [ -n "${SMW_MAKER_EXE:-}" ]; then
    cp "$SMW_MAKER_EXE" "$S/SMW-Maker.exe"
else
    WIN_OUT="$(wslpath -w "$S")"
    ( cd "$HERE" && cmd.exe /c "build-exe.cmd $WIN_OUT" ) | tr -d '\r'
fi
[ -f "$S/SMW-Maker.exe" ] || { echo "SMW-Maker.exe was not built" >&2; exit 1; }

Z="$OUT/SMW-Maker-v$VER.zip"
rm -f "$Z"
( cd "$W/pack" && python3 - "$Z" <<'EOF'
import os, sys, zipfile
# One fixed date in the past for every file: zip times have no time zone, and a file dated in the future of the PC that
# unzips it (packed in a time zone ahead of it) sends CMake and Ninja into a loop ("build.ninja still dirty").
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk("SMW-Maker"):
        dirs.sort()
        for f in sorted(files):
            path = os.path.join(root, f)
            info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (os.stat(path).st_mode & 0xFFFF) << 16
            with open(path, "rb") as fh:
                z.writestr(info, fh.read(), compresslevel=9)
EOF
)
ls -la "$Z"
sha256sum "$Z"

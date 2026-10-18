#!/usr/bin/env bash
# Maintainers (WSL): SMW Maker's release zip from maker/build-bundle.sh's tools.
#   maker/pack.sh <bundle dir> [out dir]    -> <out>/SMW-Maker-v<VERSION>.zip
#
#   SMW-Maker/SMW-Maker.exe       the app (maker/SMW-Maker.cs, built with Windows' own C# compiler through WSL interop)
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
WONDER_SRC="$W/src/wonder-release" bash "$REPO/scripts/clone-wonder.sh" >/dev/null
mkdir -p "$S/src/wonder"
git -C "$W/src/wonder-release" archive HEAD | tar -x -C "$S/src/wonder" --exclude=docs

cp -r "$BUNDLE/tools" "$S/tools"
cp "$HERE/THIRD-PARTY.txt" "$S/THIRD-PARTY.txt"

# The app, with the C# compiler of Windows' .NET Framework 4 (WSL runs Windows programs).
WIN_OUT="$(wslpath -w "$S")"
( cd "$HERE" && cmd.exe /c "build-exe.cmd $WIN_OUT" ) | tr -d '\r'
[ -f "$S/SMW-Maker.exe" ] || { echo "SMW-Maker.exe was not built" >&2; exit 1; }

Z="$OUT/SMW-Maker-v$VER.zip"
rm -f "$Z"
( cd "$W/pack" && python3 - "$Z" <<'EOF'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk("SMW-Maker"):
        dirs.sort()
        for f in sorted(files):
            z.write(os.path.join(root, f))
EOF
)
ls -la "$Z"
sha256sum "$Z"

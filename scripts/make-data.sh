#!/usr/bin/env bash
# The game data for /data/SMW from YOUR Super Mario Bros. Wonder 1.0.0 dump and keys, with upstream's own tools
# (windows/SMW-Data-Tool.cmd runs this in WSL; it works the same from any Linux shell):
#
#   make-data.sh --game <.nsp/.xci> --prod <prod.keys> [--title <title.keys>] --out <folder>
#
#   1. upstream's recompiler project at the commit in patches/BASE.txt, with the PS4 changes (scripts/clone-wonder.sh)
#   2. its importer: the dump decrypted with your keys -> analysis/{main,sdk}.bin and the RomFS (3.7 GB)
#   3. its shader translator: the game's 12,751 Maxwell shaders -> SPIR-V (.NET 10 and Ryujinx's translator,
#      downloaded once)
#   4. the folder laid out for /data/SMW: <out>/SMW/{analysis,extract,spirv,config.txt}
#
# Needs ~12 GB free in WSL and ~5 GB in <out>, git, cmake, ninja, a C++ compiler, python3-venv and curl (asked for
# with apt when missing). Takes 20-40 minutes. Your keys are copied for the import and deleted after it; nothing is
# uploaded anywhere. The result is your game: keep it to yourself.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="" PROD="" TITLE="" OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --game) GAME="$2"; shift 2 ;;
        --prod) PROD="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -f "$GAME" ] || { echo "no game dump at '$GAME' (--game: the .nsp or .xci)" >&2; exit 1; }
[ -f "$PROD" ] || { echo "no prod.keys at '$PROD' (--prod)" >&2; exit 1; }
[ -n "$OUT" ] || { echo "--out: where the SMW folder goes" >&2; exit 1; }
[ -z "$TITLE" ] || [ -f "$TITLE" ] || { echo "no title.keys at '$TITLE'" >&2; exit 1; }

WORK="${SMW_WORK:-$HOME/smw-data-tool}"
export WONDER_SRC="$WORK/wonder"
mkdir -p "$WORK"

step() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

step "1/4 tools"
need=()
for c in git cmake ninja c++ curl python3; do command -v "$c" >/dev/null || need+=("$c"); done
python3 -c 'import venv, ensurepip' 2>/dev/null || need+=(python3-venv)
if [ ${#need[@]} -gt 0 ]; then
    echo "installing: git cmake ninja-build g++ curl python3-venv (asks for your WSL password)"
    sudo apt-get update -qq
    sudo apt-get install -y -qq git cmake ninja-build g++ curl python3 python3-venv ca-certificates
fi
command -v spirv-val >/dev/null || echo "(spirv-tools is not installed: the shaders are translated without the extra check)"
SMW_SOURCE_RESET=1 bash "$HERE/clone-wonder.sh"

step "2/4 import (your dump and keys)"
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
bash "$HERE/prepare-game.sh" "$IN" import
rm -rf "$IN"

step "3/4 shaders (20-30 minutes the first time)"
bash "$HERE/prepare-game.sh" "$WORK" shaders

step "4/4 the SMW folder"
STAGE="$WORK/stage/SMW"
bash "$HERE/stage-data.sh" "$STAGE"
mkdir -p "$OUT"
echo "copying to $OUT/SMW (about 4 GB)"
rm -rf "$OUT/SMW"
cp -r "$STAGE" "$OUT/SMW"
rm -rf "$WORK/stage"
echo
echo "done: $(find "$OUT/SMW" -type f | wc -l) files in $OUT/SMW"
echo "copy the CONTENTS of that folder to /data/SMW on your PS4 (FTP), once."

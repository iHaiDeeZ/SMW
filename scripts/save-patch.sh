#!/usr/bin/env bash
# Commit the work in ~/smw-build/src/wonder (branch ps4) and export it as patches/wonder-ps4.patch against the
# upstream commit in patches/BASE.txt. private/ (the game) is gitignored upstream and never part of it.
#   save-patch.sh "commit message"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${WONDER_SRC:-$HOME/smw-build/src/wonder}"
BASE="$(cat "$HERE/../patches/BASE.txt")"
git -C "$SRC" add -A
git -C "$SRC" diff --cached --quiet || git -C "$SRC" -c user.name=SMW -c user.email=smw@localhost commit -q -m "${1:-PS4 port work}"
git -C "$SRC" diff "$BASE" HEAD > "$HERE/../patches/wonder-ps4.patch"
echo "patches/wonder-ps4.patch: $(grep -c '^diff --git' "$HERE/../patches/wonder-ps4.patch") files"

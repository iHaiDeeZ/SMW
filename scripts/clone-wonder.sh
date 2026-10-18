#!/usr/bin/env bash
# Upstream Super Mario Bros. Wonder recomp (BelmanteGu/SuperMarioWonderRecomp) at the commit in
# patches/BASE.txt into ~/smw-build/src/wonder, with the PS4 port applied on a branch "ps4".
#   clone-wonder.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${WONDER_SRC:-$HOME/smw-build/src/wonder}"
BASE="$(cat "$HERE/../patches/BASE.txt")"
if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/BelmanteGu/SuperMarioWonderRecomp "$SRC"
fi
git -C "$SRC" fetch -q origin
git -C "$SRC" checkout -q "$BASE"
if ! git -C "$SRC" rev-parse -q --verify ps4 >/dev/null; then
    git -C "$SRC" checkout -q -b ps4
    git -C "$SRC" apply --index "$HERE/../patches/wonder-ps4.patch"
    git -C "$SRC" -c user.name=SMW -c user.email=smw@localhost commit -q -m "PS4 port (patches/wonder-ps4.patch)"
fi
git -C "$SRC" log -2 --oneline

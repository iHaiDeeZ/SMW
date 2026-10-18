#!/usr/bin/env bash
# Upstream Super Mario Bros. Wonder recomp (BelmanteGu/SuperMarioWonderRecomp) at the commit in
# patches/BASE.txt into ~/smw-build/src/wonder, with the PS4 port applied on a branch "ps4", which is left checked out.
#   clone-wonder.sh
# Run again, it checks ps4 out as it is when it matches patches/wonder-ps4.patch. If it doesn't (a newer patch, or
# work not yet saved with save-patch.sh), it is left alone with a warning, unless SMW_SOURCE_RESET=1 (the trees the
# data and package tools manage), which makes it again from patches/BASE.txt and the patch. private/ (the game) stays.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${WONDER_SRC:-$HOME/smw-build/src/wonder}"
BASE="$(cat "$HERE/../patches/BASE.txt")"
PATCH="$HERE/../patches/wonder-ps4.patch"
if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/BelmanteGu/SuperMarioWonderRecomp "$SRC"
fi
git -C "$SRC" cat-file -e "$BASE^{commit}" 2>/dev/null || git -C "$SRC" fetch -q origin
make_ps4() {
    git -C "$SRC" checkout -q -f -B ps4 "$BASE"
    git -C "$SRC" apply --index "$PATCH"
    git -C "$SRC" -c user.name=SMW -c user.email=smw@localhost commit -q -m "PS4 port (patches/wonder-ps4.patch)"
}
if ! git -C "$SRC" rev-parse -q --verify ps4 >/dev/null; then
    make_ps4
elif cmp -s <(git -C "$SRC" diff "$BASE" ps4) "$PATCH"; then
    git -C "$SRC" checkout -q ps4
elif [ "${SMW_SOURCE_RESET:-0}" = 1 ]; then
    echo "the PS4 port changed: applying the new patches/wonder-ps4.patch"
    make_ps4
else
    git -C "$SRC" checkout -q ps4
    echo "warning: branch ps4 in $SRC differs from patches/wonder-ps4.patch (scripts/save-patch.sh saves it;" \
         "SMW_SOURCE_RESET=1 makes ps4 again from the patch)" >&2
fi
git -C "$SRC" log -2 --oneline

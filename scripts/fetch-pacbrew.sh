#!/usr/bin/env bash
# PacBrew's OpenOrbis toolchain and port libraries (every ps4-openorbis-* package of its pacman repository, the
# toolchain SMW is built with: clang 12, ld.lld, create-fself, create-gp4, PkgTool, the OpenOrbis headers and libc),
# unpacked into <root>/opt/pacbrew without pacman. Each package is checked against the repository's SHA-256.
#   fetch-pacbrew.sh [root, default /]      (needs write access to <root>/opt)
set -euo pipefail
ROOT="${1:-/}"
REPO="${PACBREW_REPO:-https://pacman.mydedibox.fr/pacbrew/packages}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
curl -fsSL "$REPO/pacbrew.db" -o "$T/pacbrew.db"
mkdir -p "$T/db"
tar -xf "$T/pacbrew.db" -C "$T/db"
field() { awk -v k="%$2%" '$0 == k { getline; print; exit }' "$1/desc"; }
n=0
for d in "$T"/db/ps4-openorbis-*/; do
    f="$(field "$d" FILENAME)"; sum="$(field "$d" SHA256SUM)"
    echo "pacbrew: $f"
    curl -fsSL "$REPO/$f" -o "$T/$f"
    echo "$sum  $T/$f" | sha256sum -c --quiet - || { echo "pacbrew: $f does not match the repository's checksum" >&2; exit 1; }
    tar -xf "$T/$f" -C "$ROOT" --exclude=.PKGINFO --exclude=.MTREE --exclude=.BUILDINFO --exclude=.INSTALL
    rm -f "$T/$f"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "pacbrew: no ps4-openorbis packages in $REPO" >&2; exit 1; }
echo "pacbrew: $n packages in $ROOT/opt/pacbrew/ps4/openorbis"

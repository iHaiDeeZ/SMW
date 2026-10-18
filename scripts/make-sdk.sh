#!/usr/bin/env bash
# Maintainers: the prebuilt PS4 pieces that scripts/make-pkg-from-dump.sh downloads, as one archive for a GitHub
# release (SMW-PS4-SDK-<version>.tar.xz). No game code or Sony files: the libc++ 21 sysroot with the libc overlay and
# its open-source libraries (Resonance's, plus toolchain/smw-overlay.sh), and Crema's RADV build reduced to the
# static libraries toolchain/ps4-love-style.cmake links, as ordinary archives (the build's own are thin ones that
# point into the whole Mesa build tree).
#   make-sdk.sh <version> [out dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="${1:?SDK version, e.g. 1}"
OUT="$(readlink -f "${2:-$HERE/../out}")"
PSB="${PS4_BUILD_ROOT:-$HOME/smw-build}"
AR="${AR:-llvm-ar-21}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
S="$T/smw-ps4-sdk"
mkdir -p "$S/build/mesa"
cp -a "$PSB/sysroot" "$S/sysroot"
rm -rf "$S/sysroot/share/man" "$S/sysroot/share/doc"
# The library list of ps4_link_mesa, each thin archive rewritten with its members' contents.
libs=$(sed -n '/^function(ps4_link_mesa/,/^endfunction/p' "$HERE/../toolchain/ps4-love-style.cmake" | grep -o 'src/[^ )]*\.a')
for l in $libs; do
    src="$PSB/build/mesa/$l"
    mkdir -p "$S/build/mesa/$(dirname "$l")"
    ( cd "$(dirname "$src")" && "$AR" t "$src" | xargs "$AR" rcsD --format=gnu "$S/build/mesa/$l" )
done
cat > "$S/NOTICE.txt" <<'EOF'
SMW PS4 SDK: prebuilt open-source pieces for building SMW (github.com/iHaiDeeZ/SMW) on Linux. No game code.

sysroot/          libc++ / libc++abi 21 (LLVM, Apache-2.0 WITH LLVM-exception), the OpenOrbis libc overlay and
                  runtime from Resonance / DolphinPS4 (MIT), and static builds of: Boost (BSL-1.0), zlib (Zlib),
                  zstd (BSD-3-Clause), libzip (BSD-3-Clause), libpng (libpng), curl (curl), OpenSSL (Apache-2.0),
                  fmt (MIT), glm (MIT), glslang (BSD-3-Clause and others), pugixml (MIT), RapidJSON (MIT),
                  libnfs (LGPL-2.1), libsmb2 (LGPL-2.1). Each is unmodified upstream source built for the PS4;
                  the sources are at their projects' sites.
build/mesa/       Mesa's RADV Vulkan driver (MIT) ported to the PS4 GPU: github.com/iHaiDeeZ/Crema.

The toolchain itself (PacBrew OpenOrbis, GPL-3.0 tools) is downloaded from PacBrew's own release, not included.
EOF
mkdir -p "$OUT"
A="$OUT/SMW-PS4-SDK-$VER.tar.xz"
tar -C "$T" -cf - smw-ps4-sdk | xz -T0 -9 > "$A"
ls -la "$A"
sha256sum "$A"

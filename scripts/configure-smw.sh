#!/usr/bin/env bash
# Configure the Wonder recomp (with patches/wonder-ps4.patch applied, scripts/clone-wonder.sh) for the PS4.
#   configure-smw.sh [extra cmake args...]
# The generated code (python -m recomp, scripts/prepare-game.sh) comes from SMW_GEN, default
# ~/smw-build/src/wonder/private/wonder/gen; with SMW_GEN pointing at scripts/make-stub-gen.sh's output only the
# runtime is real. Run through ~/smw (no space in the path).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/ps4-env.sh"
SRC="${WONDER_SRC:-$PS4_BUILD_ROOT/src/wonder}"
BUILD="${SMW_BUILD:-$PS4_BUILD_ROOT/build/wonder}"
GEN="${SMW_GEN:-$SRC/private/wonder/gen}"
[ -d "$GEN/main" ] || { echo "no generated code in $GEN (scripts/prepare-game.sh, or SMW_GEN=\$(scripts/make-stub-gen.sh))" >&2; exit 1; }
ps4_cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/../toolchain/ps4-smw.cmake" \
    "-DCMAKE_PROJECT_SwitchGamesRecomp_INCLUDE=$HERE/../toolchain/ps4-love-style.cmake" \
    -DPS4_PAID="${PS4_PAID:-0x3800000000000035}" \
    -DPS4_MESA_BUILD="$PS4_BUILD_ROOT/build/mesa" \
    -DNX_PS4=ON -DNX_GAME=wonder -DNX_GEN_DIR="$GEN" \
    -DNX_VULKAN_INCLUDE="$PS4_BUILD_ROOT/third_party/Vulkan-Headers-1.4.357/include" \
    "$@"

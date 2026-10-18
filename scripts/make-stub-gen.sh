#!/usr/bin/env bash
# Stand-in "generated code" for building the runtime without a game dump: an empty main and sdk module (no
# functions, relocations or symbols), so the whole PS4 runtime compiles and links into an eboot. That eboot stops at
# boot ("nn::init::Start not found" in nx.log); it is for checking the port, not for playing.
#   make-stub-gen.sh [gen dir]     (default ~/smw-build/stub-gen)
set -euo pipefail
GEN="${1:-$HOME/smw-build/stub-gen}"
for mod in main sdk; do
    mkdir -p "$GEN/$mod"
    off=0x0; [ "$mod" = sdk ] && off=0x10000000
    cat > "$GEN/$mod/table.cpp" <<EOF
// Stub module (scripts/make-stub-gen.sh): no recompiled code.
#include <nx/module.h>

extern const nx::ModuleInfo nx_module_$mod = {
    "$mod", NX_BASE + ${off}ull,
    0, 0, 0, 0, 0, 0, 0, 0,
    nullptr, 0,
    nullptr, 0,
    nullptr, 0,
    nullptr, 0, nullptr, 0,
};
EOF
done
echo "$GEN"

#!/usr/bin/env bash
# One-time: create ~/smw-build from copies of Resonance's build tree (libc++ 21 sysroot with the libc
# overlay and prebuilt libraries, and the RADV/GNM Mesa build), so this port never writes into
# ~/resonance-build. Then the PS4 signal context layout in the overlay (the lazy guest memory and
# the crash handler read it), and ~/smw -> this repo.
set -euo pipefail
RES="${RES:-$HOME/resonance-build}"
PSB="${PSB:-$HOME/smw-build}"
mkdir -p "$PSB/src" "$PSB/build" "$PSB/out" "$PSB/logs" "$PSB/oelf"
[ -d "$PSB/sysroot" ] || cp -a "$RES/sysroot" "$PSB/sysroot"
[ -d "$PSB/host-compat" ] || cp -a "$RES/host-compat" "$PSB/host-compat"
# Mesa: the whole build directory (its static libraries are thin archives). Crema's, the newest PS4 RADV: Resonance's
# (2026-10-12) lacks the Liverpool vertex fetch fix, and Wonder's lit models drew black with it.
MESA="${MESA:-$HOME/cemups4-build/build/mesa}"
[ -d "$PSB/build/mesa" ] || cp -a "$MESA" "$PSB/build/mesa"
PSB="$PSB" bash "$(dirname "$0")/../toolchain/smw-overlay.sh"
# Vulkan-Headers 1.4.357: the registry version upstream generated runtime/src/vk_gen.h from (RADV's own are older)
VKH="$PSB/third_party/Vulkan-Headers-1.4.357"
[ -d "$VKH" ] || git clone -q --depth 1 --branch v1.4.357 https://github.com/KhronosGroup/Vulkan-Headers "$VKH"
# Space-free path to this repo: toolchain flags (linker script paths) break on "PS4 Projects".
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -e "$HOME/smw" ] || ln -s "$REPO" "$HOME/smw"
du -sh "$PSB"/* 2>/dev/null
find "$PSB/build/mesa" -name '*.a' | wc -l

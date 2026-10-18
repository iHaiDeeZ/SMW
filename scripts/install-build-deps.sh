#!/usr/bin/env bash
# As root, once: what scripts/make-pkg-from-dump.sh needs on Ubuntu (WSL or not).
#   sudo bash scripts/install-build-deps.sh
#
# - apt: git, cmake, ninja, a C++ compiler (upstream's importer), python3 with venv and Pillow (the boot screen art),
#   curl, xz, libxml2 (PacBrew's ld.lld)
# - clang 21 (the PS4 build's compiler, with libc++ 21 from the SDK): from Ubuntu when it has it, else from
#   apt.llvm.org
# - PacBrew's OpenOrbis toolchain in /opt/pacbrew (scripts/fetch-pacbrew.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git cmake ninja-build g++ curl ca-certificates xz-utils python3 python3-venv python3-pil \
    libxml2 gnupg >/dev/null
if ! apt-cache policy clang-21 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    . /etc/os-release
    echo "clang 21 from apt.llvm.org ($VERSION_CODENAME)"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/llvm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/llvm.gpg] http://apt.llvm.org/$VERSION_CODENAME/ llvm-toolchain-$VERSION_CODENAME-21 main" \
        > /etc/apt/sources.list.d/llvm-21.list
    apt-get update -qq
fi
apt-get install -y -qq clang-21 >/dev/null
clang-21 --version | head -1
if [ ! -x /opt/pacbrew/ps4/openorbis/bin/create-fself ]; then
    bash "$HERE/fetch-pacbrew.sh" /
fi
echo "build tools: ready"

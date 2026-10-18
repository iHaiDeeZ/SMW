#!/usr/bin/env bash
# The quick menu (runtime/src/ps4/ps4_menu.cpp) drawn on the PC, to check its look without a console.
#   scripts/menu-preview.sh [frame.png] [page 0 main / 1 controls / 2 bind] [selected row] [out.png]
# The fonts come from scripts/make-art.py --boot (made here in a temporary folder).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/ps4-env.sh"
SRC="${WONDER_SRC:-$PS4_BUILD_ROOT/src/wonder}"
FRAME="${1:-}" PAGE="${2:-0}" SEL="${3:-1}" OUT="${4:-menu-preview.png}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 "$HERE/make-art.py" "$SRC/android/wonder/assets/fonts/Fredoka.ttf" "$TMP/boot" --boot >/dev/null
cat > "$TMP/main.cpp" <<'EOF'
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
namespace nx::plat::ps4 {
void menu_preview(const char*, const uint8_t*, int, int, const char*);
}
int main(int argc, char** argv) {
    std::vector<uint8_t> frame;
    if (argv[2][0] != '-') {
        frame.resize(1920 * 1080 * 4);
        FILE* f = std::fopen(argv[2], "rb");
        if (!f || std::fread(frame.data(), 1, frame.size(), f) != frame.size()) return 1;
        std::fclose(f);
    }
    nx::plat::ps4::menu_preview(argv[1], frame.empty() ? nullptr : frame.data(), std::atoi(argv[3]), std::atoi(argv[4]),
                                argv[5]);
}
EOF
g++ -std=c++20 -O1 -DSMW_MENU_PREVIEW -I "$SRC/runtime/src/ps4" -o "$TMP/preview" "$SRC/runtime/src/ps4/ps4_menu.cpp" "$TMP/main.cpp"
RAW=-
if [ -n "$FRAME" ]; then
    python3 -c "from PIL import Image; import sys; Image.open(sys.argv[1]).convert('RGBA').resize((1920, 1080)).save(sys.argv[2], 'raw')" "$FRAME" "$TMP/frame.rgba" 2>/dev/null ||
        python3 -c "from PIL import Image; import sys; open(sys.argv[2], 'wb').write(Image.open(sys.argv[1]).convert('RGBA').resize((1920, 1080)).tobytes())" "$FRAME" "$TMP/frame.rgba"
    RAW="$TMP/frame.rgba"
fi
"$TMP/preview" "$TMP/boot" "$RAW" "$PAGE" "$SEL" "$TMP/out.ppm"
python3 -c "from PIL import Image; import sys; Image.open(sys.argv[1]).save(sys.argv[2])" "$TMP/out.ppm" "$OUT"
echo "wrote $OUT"

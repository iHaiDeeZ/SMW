# Credits

SMW is a port. Nearly everything that makes the game run is other people's work.

## The game's recompilation

- **[Super Mario Bros. Wonder Recomp](https://github.com/BelmanteGu/SuperMarioWonderRecomp)** by **BelmanteGu**
  (MIT): the static recompiler, the runtime (Horizon services, NVN on Vulkan, audio), the importer and the shader
  tools. SMW applies `patches/wonder-ps4.patch` to it and builds it at the commit in `patches/BASE.txt`. Upstream's
  own third-party components (listed in its README) keep their licenses.
- **[Ryujinx](https://ryujinx.app)** and its continuation **[Ryubing](https://codeberg.org/Software_arch/Ryubing)**
  (MIT): the Maxwell shader translator upstream's tools use to make SPIR-V. Downloaded by the data tool, not
  included here.

## The PS4 side

- **[Mesa](https://mesa3d.org)** (MIT): the RADV Vulkan driver, ported to the PS4's GPU in
  [Crema](https://github.com/iHaiDeeZ/Crema). `port/mesa/ac_ps4_drm.c` is that port's winsys.
- **[OpenOrbis](https://github.com/OpenOrbis)** (GPL-3.0 toolchain; its libraries under their own terms) and
  **[PacBrew](https://github.com/PacBrew)**: the PS4 toolchains. `toolchain/` comes from
  [love-ps4](https://github.com/Mari0/love-ps4)'s setup by way of Resonance, DolphinPS4 and Crema. The package
  build (`scripts/install-build-deps.sh`) downloads PacBrew's packages from its own repository; they are not
  included here.
- **[LLVM](https://llvm.org)** (Apache-2.0 WITH LLVM-exception): clang 21 builds the eboot, and libc++ 21 is in
  the [SDK release](https://github.com/iHaiDeeZ/SMW/releases/tag/sdk-1) with the sysroot's other open-source
  libraries (listed in its `NOTICE.txt`).
- **[Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers)** (Apache-2.0 / MIT): downloaded by the
  build.
- **[Resonance](https://github.com/iHaiDeeZ/Resonance)**, **[DolphinPS4](https://github.com/iHaiDeeZ/DolphinPS4)**,
  **[M33](https://github.com/iHaiDeeZ/M33)** and **[Crema](https://github.com/iHaiDeeZ/Crema)** by ShiroKlein:
  the PS4 runtime in `port/` (heap, crash and hang logs, thread placement) and the VideoOut presentation.
- **dlmalloc** by Doug Lea (its MIT-style licence, at the top of `port/third_party/dlmalloc/malloc.c`).
- **libjpeg-turbo** (BSD-3-Clause): the `turbojpeg.h` header in `port/third_party/turbojpeg`, with its notice.

## In the package

- **[AMD FidelityFX Super Resolution 1](https://github.com/GPUOpen-Effects/FidelityFX-FSR)** (MIT): EASU and
  RCAS in upstream's present pass.
- **Fredoka** by Milena Brandão (SIL Open Font License 1.1, licence text in the package's `fonts/`): the boot
  screen, the quick menu and the shared font.
- Upstream's button glyph font (MIT, as upstream).
- The home screen and boot screen art (`scripts/make-art.py`) is drawn from shapes and Fredoka lettering: no game
  art.

## Thanks

To BelmanteGu for making the recompilation open, to the Ryujinx and Mesa developers, and to everyone keeping the
PS4 homebrew scene and its toolchains alive.

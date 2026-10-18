# Building SMW

SMW is [Super Mario Bros. Wonder Recomp](https://github.com/BelmanteGu/SuperMarioWonderRecomp) (BelmanteGu's static
recompilation of the Switch game) with a PS4 runtime. The package is built from **your own dump**: its `eboot.bin`
is mostly the game's code, recompiled to x86-64, so it can't be downloaded and must never be shared.

Everything runs in WSL Ubuntu (or any Linux) with the toolchain of Resonance and Crema: clang 21 and libc++ 21 on
OpenOrbis, and Mesa's RADV driver ported to the PS4 GPU.

## What you need

- A PC with WSL Ubuntu, 16 GB of RAM and about 60 GB free.
- Your **Super Mario Bros. Wonder 1.0.0** dump (`.nsp` or `.xci`, base game, no update; upstream's
  `docs/WONDER-DUMP.md` has the exact size and SHA-256), with your `prod.keys` and `title.keys`.
- The PS4 toolchain and libraries, once:
  1. [Resonance](https://github.com/iHaiDeeZ/Resonance)'s build tree in `~/resonance-build` (its build guide sets
     up the PacBrew OpenOrbis toolchain in `/opt/pacbrew/ps4/openorbis` and the libc++ 21 sysroot);
  2. [Crema](https://github.com/iHaiDeeZ/Crema)'s Mesa build in `~/cemups4-build/build/mesa` (the newest PS4
     RADV; older builds draw Wonder's lit models black).

## Steps

Run everything from WSL through `~/smw` (a link to this repository made by the first step): the space in a path
such as "PS4 Projects" breaks the linker flags.

```
scripts/seed-build-tree.sh            # ~/smw-build: the sysroot and RADV build, the ucontext overlay, Vulkan-Headers 1.4.357
scripts/clone-wonder.sh               # upstream at patches/BASE.txt into ~/smw-build/src/wonder, patches/wonder-ps4.patch on branch ps4
scripts/prepare-game.sh <folder>      # your keys and dump: import, recompile (~1.4 GB of C++), translate the shaders
scripts/rebuild-smw.sh                # configure + build the eboot (~10 minutes; logs in ~/smw-build/logs)
SMW_VERSION=01.00 scripts/package-smw.sh   # out/SMW-v01.00.pkg
scripts/stage-data.sh                 # ~/smw-build/data-stage/SMW: copy its contents to /data/SMW over FTP, once
```

`windows/SMW-Data-Tool.cmd` does the data part (`scripts/make-data.sh`) from Windows, without the rest.
`SMW_BUNDLE_DATA=1 scripts/package-smw.sh` puts the game data in the package (`/app0/data`, ~4 GB more) instead;
the runtime reads it there first. Big packages need `scripts/build-pkgtool.sh` once (a PkgTool with more room for
PlayGo hashes) and `scripts/gp4-fix-dirs.py` (run by `make-pkg.sh`).

Upload from Windows (Git Bash) with `scripts/upload-to-console.sh out/SMW-vXX.YY.pkg`. After a crash,
`scripts/crashlog.sh` fetches the logs and symbolizes them against the packaged build's ELF.
`scripts/save-patch.sh` commits `~/smw-build/src/wonder` and refreshes `patches/wonder-ps4.patch`.

## How it runs

- **CPU:** upstream's recompiled C++, `main` and `sdk` (17.8M AArch64 instructions), compiled for the PS4's
  Jaguar cores (`-march=btver2`, no FMA contraction). There's no emulator and no JIT.
- **Graphics:** upstream's NVN-on-Vulkan layer on Mesa's RADV, linked into the eboot (Vulkan 1.3 on the PS4's
  gfx7 GPU). `runtime/src/ps4/ps4_vk_wsi.cpp` presents on VideoOut: linear 1920x1080 images flipped GPU-side.
  Pipelines and new ASTC textures are made in the background; submits are pipelined (the CPU doesn't wait for
  the GPU at the end of a frame).
- **NaN:** the Switch's R11G11B10F targets store NaN as 0; here they are RGBA16F, so each fragment shader writes
  NaN components as 0 and reads NaN varyings as 0 (`NX_FS_NAN`, `nvn_spirv_patch.cpp`). Without it every lit
  model and the ground of a course drew black on the PS4.
- **Memory:** guest memory is mapped from direct memory on first touch (below).
- **Audio:** the game's own AudioRenderer (recompiled), out through sceAudioOut at 48 kHz.

### Cores

The PS4 gives an app cores 0-5, plus core 6 when the system grants it. SMW checks for core 6 at startup and logs
the result in `boot-trace.log`.

| PS4 core | `NX_PS4_CORES=balanced` (the default) | `NX_PS4_CORES=pinned` |
|---|---|---|
| 0 | guest threads | guest core 0: the game's main thread |
| 1 | the NVN replay + present thread, alone | the same |
| 2, 3 | guest threads | guest cores 1 and 2: the job workers |
| 4, 5, 6 | guest threads, plus audio, ASTC decoding, pipeline compiles, RADV's threads, the pad | guest core 3, plus the same host threads |

`NX_PS4_CORES=spread` puts every thread on every core.

### Memory

The PS4 has no demand-zero memory to speak of: flexible memory is small, and direct memory (4.5 GiB for this app,
shared with the GPU) is physical. Upstream commits the whole guest heap at once and gives every guest thread a
64 MiB stack. So on the PS4:

- The guest ranges at `0x40_0000_0000`-`0x70_0000_0000` are address-space reservations.
- `commit` only marks a range as usable. The fault handler maps 64 KiB chunks of direct memory there on first
  touch, zeroed.
- Kernel calls that write into guest memory (`pread`) can't fault on the runtime's behalf, so the buffer is
  touched first.
- Host stacks for guest threads come from the same lazy space at `0x78_0000_0000`.
- `nx.log` reports the guest's mapped memory and the free direct memory every 30 s.

## The port's files

`patches/wonder-ps4.patch` against upstream `f44d142` (`patches/BASE.txt`):

| File | What |
|---|---|
| `runtime/src/platform_ps4.cpp` | `main`, lazy guest memory and fault handler, threads and core placement, ScePad, sceAudioOut, settings |
| `runtime/src/ps4/ps4_vk_wsi.{h,cpp}` | the VideoOut surface and swapchain, the frame counter |
| `runtime/src/ps4/ps4_boot_screen.cpp`, `ps4_boot_draw.cpp` | the boot screen with its progress bar |
| `runtime/src/ps4/ps4_menu.cpp` | the L3 + R3 quick menu and its settings (`scripts/menu-preview.sh` draws it on a PC) |
| `runtime/src/memguard_ps4.cpp` | direct memory accounting in `nx.log` |
| `runtime/src/nvn/*` | NaN handling, background pipelines and ASTC, buffer padding, the replay timings in `nx.log` |
| `CMakeLists.txt` | `NX_PS4`: the eboot with RADV, the PS4 libraries, the game modules' flags |

The PS4 runtime in `port/` (heap, crash and hang logs, the RADV winsys) and `toolchain/` come from Resonance,
DolphinPS4 and Crema.

## Diagnostics

- `nx.log` every second: frame rate, replay time by phase, GPU wait, uploads, pipelines and ASTC decodes.
- Quick menu → *Capture a diagnostics frame* (or an FTP file `/data/SMW/diag_now`): every pass of the next frame
  as pictures in `/data/SMW/diag`, with each draw's inputs in `passes.txt`.
- `NX_FS_NAN=1` marks fragment outputs that are NaN in magenta; `=3` codes which instruction made them.
- The signal-based sampler (`/data/SMW/profile.txt`) froze the game in testing: leave it off.

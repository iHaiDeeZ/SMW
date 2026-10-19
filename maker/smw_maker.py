"""SMW Maker's pipeline: the game data for /data/SMW and your own SMW package, from YOUR Super Mario Bros. Wonder 1.0.0
dump and keys, on Windows with the tools in SMW Maker's tools/ folder only (no WSL). The same steps as the Linux
scripts (make-data.sh, prepare-game.sh, stage-data.sh, make-pkg-from-dump.sh, package-smw.sh, make-pkg.sh).

    python smw_maker.py data --game <.nsp/.xci> --prod <prod.keys> [--title <title.keys>] --out <folder> --work <dir>
    python smw_maker.py pkg  --game ... --prod ... [--title ...] --out <folder> --work <dir> [--version 00.29]

<dir> is the work folder (no spaces: the PS4 linker's flags can't take them): upstream's source, your imported dump,
the recompiled code and the build, ~40 GB. SMW-Maker.exe runs this with its own Python. Lines "== n/N name" are the
steps, "build N%" the compile, everything else is the log. Your keys are only read by the importer; nothing is uploaded.
"""
import argparse
import ctypes
import hashlib
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SMW = os.path.dirname(HERE)                        # this repository's files in SMW Maker (smw/)
MAKER = os.path.dirname(SMW)                       # SMW Maker's folder
TOOLS = os.path.join(MAKER, "tools")
UPSTREAM = os.path.join(MAKER, "src", "wonder")    # upstream at patches/BASE.txt with patches/wonder-ps4.patch
WIN = os.name == "nt"
EXE = ".exe" if WIN else ""
CONTENT_ID = "IV0000-SMWR00001_00-SMWRECOMPPS40000"
CONFIG_TXT = """# SMW settings: one NX_<KEY>=<value> per line, read at startup ('#' comments). See README.md.
# NX_PS4_CORES=pinned        guest threads on their Switch core's PS4 core (default: balanced; or spread)
# NX_BUTTONS=nintendo        Circle = A, Cross = B (by position); default Cross = A
# NX_HANDHELD=1              the game's handheld mode (720p) instead of docked (1080p)
# NX_RENDER_RES=1600x900     the size the game renders at while docked (lighter on the GPU)
# NX_FSR=1                   upscale to 1080p with FidelityFX Super Resolution 1 instead of a plain stretch
# NX_MUTE=1                  no sound
"""


def say(*a):
    print(*a, flush=True)


def step(n, total, name):
    say("")
    say(f"== {n}/{total} {name}")


def fail(msg):
    say(f"error: {msg}")
    sys.exit(1)


def tool(*parts):
    return os.path.join(TOOLS, *parts)


def fwd(p):
    """Forward slashes: the importer and the PS4 build take paths that way on Windows too."""
    return os.path.abspath(p).replace("\\", "/")


def clean_env(extra=None):
    env = dict(os.environ)
    for v in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS", "PYTHONHOME", "PYTHONPATH", "DOTNET_ROOT"):
        env.pop(v, None)
    system = os.environ.get("SystemRoot", r"C:\Windows")
    env["PATH"] = os.pathsep.join([tool("cmake", "bin"), tool("llvm", "bin"), tool("python"),
                                   os.path.join(system, "System32"), system])
    env.update({
        "DOTNET_ROOT": tool("dotnet"), "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1",
        "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT": "1", "PYTHONUTF8": "1", "PYTHONUNBUFFERED": "1",
    })
    env.update(extra or {})
    return env


def run(cmd, cwd=None, env=None, filt=None, log=None, background=False):
    """Runs a command; its output goes to our output line by line (through filt, which may drop or change a line)
    and to log. Stops the pipeline when it fails. background: at below-normal priority, which the programs it starts
    inherit (the compiler under Ninja): the PC stays usable while it runs."""
    say("> " + " ".join(os.path.basename(str(c)) if i == 0 else str(c) for i, c in enumerate(cmd))[:300])
    flags = 0x08000000 if WIN else 0  # CREATE_NO_WINDOW
    if WIN and background:
        flags |= 0x00004000  # BELOW_NORMAL_PRIORITY_CLASS
    p = subprocess.Popen([str(c) for c in cmd], cwd=cwd, env=env or clean_env(), stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, creationflags=flags)
    buf = b""
    logf = open(log, "w", encoding="utf-8", errors="replace", buffering=1) if log else None
    tail = []
    while True:
        chunk = p.stdout.read1(65536) if hasattr(p.stdout, "read1") else p.stdout.read(4096)
        if not chunk:
            break
        buf += chunk
        while True:
            cut = min([i for i in (buf.find(b"\n"), buf.find(b"\r")) if i >= 0], default=-1)
            if cut < 0:
                break
            line, buf = buf[:cut].decode("utf-8", "replace"), buf[cut + 1:]
            if logf:
                logf.write(line + "\n")
            if line.strip():
                tail = (tail + [line])[-30:]
            out = filt(line) if filt else line
            if out:
                say(out)
    rc = p.wait()
    if logf:
        logf.close()
    if rc != 0:
        if filt:
            say("\n".join(tail[-15:]))
        fail(f"{os.path.basename(str(cmd[0]))} stopped with exit code {rc}")


def python(*args, cwd=None):
    return [sys.executable] + list(args)


def memory_info():
    """(total, available) physical memory in GB."""
    if WIN:
        class MS(ctypes.Structure):
            _fields_ = [("len", ctypes.c_ulong), ("load", ctypes.c_ulong), ("total", ctypes.c_ulonglong),
                        ("avail", ctypes.c_ulonglong), ("a", ctypes.c_ulonglong), ("b", ctypes.c_ulonglong),
                        ("c", ctypes.c_ulonglong), ("d", ctypes.c_ulonglong), ("e", ctypes.c_ulonglong)]
        m = MS()
        m.len = ctypes.sizeof(MS)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
        return m.total / (1 << 30), m.avail / (1 << 30)
    page = os.sysconf("SC_PAGE_SIZE")
    return page * os.sysconf("SC_PHYS_PAGES") / (1 << 30), page * os.sysconf("SC_AVPHYS_PAGES") / (1 << 30)


def memory_gb():
    return int(memory_info()[0])


# What one compile of the recompiled code takes at its peak (the biggest code_NNN.cpp files), and what Windows and the
# user's programs keep: the build runs as many compiles at once as fit in the memory that is free when it starts.
JOB_GB, KEEP_GB = 1.6, 2.5


def compile_jobs():
    """Parallel compiles that fit the free memory, with room left for Windows: never all of the user's RAM.
    SMW_MAKER_JOBS=<n> sets it."""
    total, avail = memory_info()
    cpus = os.cpu_count() or 1
    if os.environ.get("SMW_MAKER_JOBS", "").isdigit():
        return max(1, int(os.environ["SMW_MAKER_JOBS"])), total, avail
    room = min(avail, total - KEEP_GB) - 1.0  # 1 GB more kept free of what is free now (it moves while we build)
    return max(1, min(cpus, int(room // JOB_GB))), total, avail


def free_gb(path):
    return shutil.disk_usage(path).free // (1 << 30)


def link_or_copy(src, dst):
    try:
        if os.path.exists(dst):
            os.remove(dst)
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def fix_future_times(*roots):
    """Files dated in the future (unzipped from a zip packed in a time zone ahead of this PC, or a clock that was
    wrong) make CMake regenerate build.ninja forever ("still dirty after 100 tries"): they get the current time."""
    now = time.time()
    n = 0
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x != "private"]  # the game's files: made on this PC
            for f in files:
                p = os.path.join(d, f)
                try:
                    if os.stat(p).st_mtime > now + 60:
                        os.utime(p, (now, now))
                        n += 1
                except OSError:
                    pass
    if n:
        say(f"{n} files were dated in the future (time zone or clock): set to now")


# ---- the work folder ------------------------------------------------------------------------------------------------

class Work:
    def __init__(self, root):
        if " " in root:
            fail(f"the work folder can't have spaces in its path: {root}")
        self.root = os.path.abspath(root)
        self.src = os.path.join(self.root, "wonder")
        self.game = os.path.join(self.src, "private", "wonder")
        os.makedirs(self.root, exist_ok=True)

    def prepare_source(self):
        """Upstream's patched source, copied from SMW Maker once per SMW version (the game's files under private/ stay)."""
        if "NX_PS4" not in open(os.path.join(UPSTREAM, "CMakeLists.txt"), encoding="utf-8").read():
            fail(f"{UPSTREAM} is not upstream with the PS4 port: download SMW Maker again")
        stamp = os.path.join(self.src, ".smw-maker-source")
        patch = open(os.path.join(SMW, "patches", "wonder-ps4.patch"), "rb").read()
        want = " ".join((open(os.path.join(SMW, "patches", "BASE.txt")).read().strip(), version(),
                         hashlib.sha256(patch).hexdigest()[:16]))
        if os.path.exists(stamp) and open(stamp).read().strip() == want:
            return
        say("copying upstream's source (with the PS4 port) into the work folder")
        shutil.rmtree(os.path.join(self.root, "build"), ignore_errors=True)  # configured for the old source
        for name in os.listdir(UPSTREAM):
            s, d = os.path.join(UPSTREAM, name), os.path.join(self.src, name)
            if os.path.isdir(d) and name != "private":
                shutil.rmtree(d)
            if os.path.isdir(s):
                shutil.copytree(s, d, dirs_exist_ok=True)
            else:
                os.makedirs(self.src, exist_ok=True)
                shutil.copy2(s, d)
        open(stamp, "w").write(want)

    def imported(self):
        g = self.game
        return all(os.path.exists(os.path.join(g, f)) for f in
                   ("analysis/main.bin", "analysis/sdk.bin", "exefs/main", "exefs/sdk", ".import/complete"))

    def do_import(self, a):
        if self.imported():
            say(f"already imported: {self.game}")
            return
        for f, what in ((a.game, "the game dump"), (a.prod, "prod.keys")):
            if not f or not os.path.isfile(f):
                fail(f"{what} was not found: {f}")
        if free_gb(self.root) < 6:
            fail(f"not enough space for the import: ~6 GB are needed in {self.root}")
        # The importer finds the keys by their file names: give it copies named prod.keys / title.keys.
        keys = os.path.join(self.root, "keys")
        shutil.rmtree(keys, ignore_errors=True)
        os.makedirs(keys)
        try:
            shutil.copyfile(a.prod, os.path.join(keys, "prod.keys"))
            args = [fwd(os.path.join(keys, "prod.keys"))]
            if a.title:
                shutil.copyfile(a.title, os.path.join(keys, "title.keys"))
                args.append(fwd(os.path.join(keys, "title.keys")))
            run([tool("nximport" + EXE), "--exefs", "--out", fwd(self.game)] + args + [fwd(a.game)])
        finally:
            shutil.rmtree(keys, ignore_errors=True)  # the copies of your keys go, whatever happens
        if not self.imported():
            fail("the import did not finish")


def version():
    return open(os.path.join(SMW, "VERSION")).read().strip()


# ---- the game data --------------------------------------------------------------------------------------------------

def make_shaders(w):
    """Upstream's shader steps (docs/nvn/SHADERS.md): the Maxwell shaders out of their containers, then SPIR-V."""
    g, src = w.game, w.src
    spirv = os.path.join(g, "spirv")
    if os.path.isfile(os.path.join(spirv, "results.tsv")) and os.path.exists(os.path.join(spirv, ".done")):
        say(f"already translated: {spirv}")
        return
    o, r = os.path.join(g, "shaders_extracted"), os.path.join(g, "extract", "romfs")
    x = os.path.join(src, "tools", "maxwell", "containers.py")
    shutil.rmtree(o, ignore_errors=True)
    os.makedirs(o)
    jobs = [("uber", "Shader/SecredUber.Product.100.product.Nin_NX_NVN.bfsha.zs"),
            ("secred", "Shader/Secred.Nin_NX_NVN.release.sarc.zs"),
            ("agl", "Lib/agl/agl_resource.Nin_NX_NVN.release.sarc.zs"),
            ("gsys", "Lib/gsys/gsys_resource.Nin_NX_NVN.release.sarc.zs")]
    for f in sorted(os.listdir(os.path.join(r, "Effect"))):
        if f.endswith(".Nin_NX_NVN.esetb.byml.zs"):
            jobs.append(("effect_" + f[:-len(".Nin_NX_NVN.esetb.byml.zs")], "Effect/" + f))
    quiet = lambda line: None
    for name, rel in jobs:
        run(python(x, os.path.join(r, rel), "--extract", os.path.join(o, name), "--unique"), cwd=src, filt=quiet)
    # Layout archives: 131 of 234 have no shaders (and their extraction may fail), keep only those with some.
    for f in sorted(os.listdir(os.path.join(r, "Layout"))):
        if not f.endswith(".Nin_NX_NVN.blarc.zs"):
            continue
        d = os.path.join(o, "layout_" + f[:-len(".Nin_NX_NVN.blarc.zs")])
        subprocess.run(python(x, os.path.join(r, "Layout", f), "--extract", d, "--unique"), cwd=src,
                       env=clean_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       creationflags=0x08000000 if WIN else 0)
        if not [n for n in (os.listdir(d) if os.path.isdir(d) else []) if n != "manifest.tsv"]:
            shutil.rmtree(d, ignore_errors=True)
    say(f"{len(os.listdir(o))} shader containers extracted")
    run(python(os.path.join(src, "tools", "maxwell", "exefs_shaders.py"), os.path.join(g, "analysis", "main.bin"),
               "--extract", os.path.join(o, "exefs")), cwd=src)
    shutil.rmtree(spirv, ignore_errors=True)
    run([tool("dotnet", "dotnet" + EXE), tool("harness", "spirv_harness.dll"), "--batch", o, "--out", spirv,
         "--jobs", str(max(1, min(os.cpu_count() or 4, 6, int(memory_info()[1] - KEEP_GB) * 3))), "--no-val"], cwd=src,
        background=True,
        filt=lambda l: l if ("shader" in l.lower() and "%" in l) or "error" in l.lower() or "done" in l.lower() else None)
    n = len([f for f in os.listdir(spirv) if f.endswith(".spv")])
    say(f"{n} shaders (12,751 expected)")
    open(os.path.join(spirv, ".done"), "w").write(str(n))


def stage_data(w, out):
    g = w.game
    smw = os.path.join(out, "SMW")
    say(f"laying out {smw}")
    for d in ("analysis", "spirv", "extract"):
        os.makedirs(os.path.join(smw, d), exist_ok=True)
    for f in ("main.bin", "sdk.bin"):
        link_or_copy(os.path.join(g, "analysis", f), os.path.join(smw, "analysis", f))
    for f in os.listdir(os.path.join(g, "spirv")):
        if f.endswith(".spv") or f == "results.tsv":
            link_or_copy(os.path.join(g, "spirv", f), os.path.join(smw, "spirv", f))
    dst = os.path.join(smw, "extract", "romfs")
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(os.path.join(g, "extract", "romfs"), dst, copy_function=link_or_copy)
    cfg = os.path.join(smw, "config.txt")
    if not os.path.exists(cfg):
        open(cfg, "w", newline="\n").write(CONFIG_TXT)
    n = sum(len(f) for _, _, f in os.walk(smw))
    say(f"done: {n} files in {smw}")
    say("copy the CONTENTS of that folder to /data/SMW on your PS4 (FTP), once.")


def cmd_data(a):
    w = Work(a.work)
    step(1, 4, "tools")
    say(f"SMW Maker {version()}, work folder {w.root} ({free_gb(w.root)} GB free)")
    fix_future_times(SMW, UPSTREAM, TOOLS, w.src)
    w.prepare_source()
    step(2, 4, "import (your dump and keys)")
    w.do_import(a)
    step(3, 4, "shaders (10-30 minutes the first time)")
    make_shaders(w)
    step(4, 4, "the SMW folder")
    os.makedirs(a.out, exist_ok=True)
    stage_data(w, a.out)


# ---- the package ----------------------------------------------------------------------------------------------------

def recompile(w):
    g = w.game
    gen = os.path.join(g, "gen")
    if all(os.path.exists(os.path.join(gen, m, ".done")) for m in ("main", "sdk")):
        say(f"already recompiled: {gen}")
        return
    shutil.rmtree(gen, ignore_errors=True)
    if memory_info()[1] < 3.0:
        say("(under 3 GB of memory free: the recompile needs about 2.5 GB, close other programs if it fails)")
    for m, base in (("main", "0x4000000000"), ("sdk", "0x4010000000")):
        run(python("-m", "recomp", os.path.join(g, "exefs", m), os.path.join(gen, m), "--name", m, "--base", base),
            cwd=w.src, background=True)
        open(os.path.join(gen, m, ".done"), "w").write("")


def build_env(w):
    oo = fwd(tool("openorbis"))
    return clean_env({"OPENORBIS": oo, "OO_PS4_TOOLCHAIN": oo, "PS4_SYSROOT": fwd(tool("sdk", "sysroot")),
                      "SMW_LLVM": fwd(tool("llvm"))})


def build(w):
    b = os.path.join(w.root, "build")
    env = build_env(w)
    tc = fwd(os.path.join(SMW, "toolchain"))
    run([tool("cmake", "bin", "cmake" + EXE), "-S", fwd(w.src), "-B", fwd(b), "-G", "Ninja",
         f"-DCMAKE_TOOLCHAIN_FILE={tc}/ps4-smw.cmake",
         f"-DCMAKE_PROJECT_SwitchGamesRecomp_INCLUDE={tc}/ps4-love-style.cmake",
         "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DPS4_PAID=0x3800000000000035",
         f"-DPS4_MESA_BUILD={fwd(tool('sdk', 'build', 'mesa'))}", "-DNX_PS4=ON", "-DNX_GAME=wonder",
         f"-DNX_GEN_DIR={fwd(os.path.join(w.game, 'gen'))}",
         f"-DNX_VULKAN_INCLUDE={fwd(tool('sdk', 'Vulkan-Headers', 'include'))}"],
        env=env, filt=lambda l: l if "error" in l.lower() else None, log=os.path.join(w.root, "configure.log"))
    eboot = os.path.join(b, "wonder_eboot", "eboot.bin")
    if os.path.exists(eboot):
        os.remove(eboot)  # a link that fails must not leave the last eboot behind
    jobs, total, avail = compile_jobs()
    say(f"compiling with {jobs} jobs at a time: {avail:.1f} of {total:.1f} GB of memory free, about {JOB_GB} GB each, "
        f"{KEEP_GB} GB kept for Windows (log: {os.path.join(w.root, 'build.log')})")
    if jobs == 1 and avail < JOB_GB + 1.0:
        say("(little memory is free: close other programs, or the build may be slow or fail)")
    last = [-1]

    def meter(line):
        if line.startswith("[") and "/" in line.split("]")[0]:
            try:
                done, total = line[1:line.index("]")].split("/")
                p = int(100 * int(done) / int(total))
            except ValueError:
                return None
            if p != last[0]:
                last[0] = p
                return f"build {p}%"
            return None
        return line if ("error:" in line or "FAILED:" in line) else None

    run([tool("cmake", "bin", "ninja" + EXE), "-C", fwd(b), f"-j{jobs}"], env=env, filt=meter,
        log=os.path.join(w.root, "build.log"), background=True)
    if not os.path.exists(eboot):
        fail("the build made no eboot.bin")
    return eboot


def pkgtool(*args, cwd=None):
    run([tool("dotnet", "dotnet" + EXE), tool("pkgtool", "PkgTool.Core.dll")] + list(args), cwd=cwd,
        filt=lambda l: l if "error" in l.lower() or "exception" in l.lower() else None)


def package(w, eboot, out, ver):
    """package-smw.sh + make-pkg.sh: the app folder, its param.sfo, the .gp4 project and the .pkg."""
    st = os.path.join(w.root, "pkg-stage")
    shutil.rmtree(st, ignore_errors=True)
    os.makedirs(os.path.join(st, "sce_sys"))
    os.makedirs(os.path.join(st, "fonts"))
    os.makedirs(os.path.join(st, "sce_module"))
    shutil.copy2(eboot, os.path.join(st, "eboot.bin"))
    for f in ("icon0.png", "pic1.png"):
        shutil.copy2(os.path.join(SMW, "sce_sys", f), os.path.join(st, "sce_sys", f))
    open(os.path.join(st, "version.txt"), "w", newline="\n").write(ver + "\n")
    fonts = os.path.join(w.src, "android", "wonder", "assets", "fonts")
    for f in ("shared_5.ttf", "Fredoka.ttf"):
        shutil.copy2(os.path.join(fonts, f), os.path.join(st, "fonts", f))
    shutil.copy2(os.path.join(w.src, "android", "wonder", "assets", "licenses", "OFL-Fredoka.txt"),
                 os.path.join(st, "fonts", "OFL-Fredoka.txt"))
    run(python(os.path.join(SMW, "scripts", "make-art.py"), os.path.join(fonts, "Fredoka.ttf"),
               os.path.join(st, "boot"), "--boot"))
    prev = os.path.join(st, "boot", "preview.png")
    if os.path.exists(prev):
        os.remove(prev)
    piglet = tool("openorbis", "samples", "piglet", "sce_module")
    for f in os.listdir(piglet):
        if f.endswith(".prx"):
            shutil.copy2(os.path.join(piglet, f), os.path.join(st, "sce_module", f))
    for root, dirs, files in os.walk(st, topdown=False):  # PkgTool stops on empty folders
        if not os.listdir(root):
            os.rmdir(root)
    sfo = os.path.join(st, "sce_sys", "param.sfo")
    pkgtool("sfo_new", sfo)
    # Plain OpenOrbis values (Vulkan on GNM runs under the plain homebrew identity); 0x2: dialogs confirm with Cross.
    for key, typ, size, val in (("APP_TYPE", "Integer", 4, "1"), ("ATTRIBUTE", "Integer", 4, "0x2"),
                                ("CATEGORY", "Utf8", 4, "gd"), ("SYSTEM_VER", "Integer", 4, "0"),
                                ("APP_VER", "Utf8", 8, ver), ("CONTENT_ID", "Utf8", 48, CONTENT_ID),
                                ("DOWNLOAD_DATA_SIZE", "Integer", 4, "0"), ("TITLE", "Utf8", 128, "SMW"),
                                ("TITLE_ID", "Utf8", 12, "SMWR00001"), ("VERSION", "Utf8", 8, ver)):
        pkgtool("sfo_setentry", sfo, key, "--type", typ, "--maxsize", str(size), "--value", val)
    run([tool("openorbis", "bin", "create-gp4" + EXE), "-out", "pkg.gp4", f"--content-id={CONTENT_ID}", "--path", "."],
        cwd=st, filt=lambda l: None)
    run(python(os.path.join(SMW, "scripts", "gp4-fix-dirs.py"), os.path.join(st, "pkg.gp4")))
    built = os.path.join(w.root, "pkg-out")
    shutil.rmtree(built, ignore_errors=True)
    os.makedirs(built)
    pkgtool("pkg_build", "pkg.gp4", built, cwd=st)
    src = os.path.join(built, CONTENT_ID + ".pkg")
    if not os.path.exists(src):
        fail("PkgTool made no package")
    os.makedirs(out, exist_ok=True)
    dst = os.path.join(out, f"SMW-v{ver}.pkg")
    shutil.copy2(src, dst)
    shutil.rmtree(built, ignore_errors=True)
    say("")
    say(f"done: {dst} ({os.path.getsize(dst) // (1 << 20)} MB)")
    say("install it with GoldHEN's Package Installer (put it in /data/pkg on the PS4). It is your game: never share it.")


def cmd_pkg(a):
    w = Work(a.work)
    ver = a.version or version()
    step(1, 5, "checks")
    mem, free = memory_gb(), free_gb(w.root)
    say(f"SMW Maker {version()}: memory {mem} GB, free in {w.root}: {free} GB, cores {os.cpu_count()}")
    if free < 30:
        fail(f"not enough space: about 40 GB are needed in {w.root}")
    if mem < 8:
        say("(less than 8 GB of memory: the build runs one file at a time and takes long)")
    step(2, 5, "the PS4 SDK and toolchain")
    fix_future_times(SMW, UPSTREAM, TOOLS, w.src)
    for t in ("llvm/bin/clang" + EXE, "openorbis/lib/crt1.o", "sdk/sysroot/lib/libc++.a", "cmake/bin/ninja" + EXE):
        if not os.path.exists(tool(t)):
            fail(f"SMW Maker is missing tools/{t}: download it again")
    w.prepare_source()
    say("SDK: ready")
    step(3, 5, "the game's code (your dump and keys)")
    w.do_import(a)
    recompile(w)
    step(4, 5, "the build")
    eboot = build(w)
    step(5, 5, "the package")
    package(w, eboot, a.out, ver)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("what", choices=("data", "pkg"))
    ap.add_argument("--game")
    ap.add_argument("--prod")
    ap.add_argument("--title")
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--version")
    a = ap.parse_args()
    t0 = time.time()
    (cmd_data if a.what == "data" else cmd_pkg)(a)
    say(f"({(time.time() - t0) / 60:.0f} minutes)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Uploads the staged game data (scripts/stage-data.sh) to /data/SMW on the console over FTP.

One connection for every file; folders are created as needed; a file already on the console with the same size is
skipped, so an interrupted upload resumes where it stopped. Run it from Windows (uploads sent from inside WSL were
undone on the console, see upload-to-console.sh):

    py scripts/upload-data.py [source] [--host 192.168.0.90] [--port 2121] [--dest /data/SMW]

source defaults to \\\\wsl.localhost\\Ubuntu\\home\\<user>\\smw-build\\data-stage\\SMW (the WSL user from
%USERNAME% lowercased, or SMW_WSL_USER). The data is your game: never upload it anywhere else.
"""
import argparse
import ftplib
import os
import posixpath
import sys
import time


def remote_sizes(ftp, path):
    """name -> size of the files in a remote folder ({} if it does not exist)."""
    lines = []
    try:
        ftp.retrlines("LIST " + path, lines.append)
    except ftplib.error_perm:
        return {}
    sizes = {}
    for line in lines:
        parts = line.split(None, 8)
        if len(parts) == 9 and not line.startswith("d"):
            try:
                sizes[parts[8]] = int(parts[4])
            except ValueError:
                pass
    return sizes


def connect(host, port):
    ftp = ftplib.FTP()
    ftp.connect(host, port, timeout=60)
    ftp.login()
    ftp.voidcmd("TYPE I")
    return ftp


def main():
    user = os.environ.get("SMW_WSL_USER", os.environ.get("USERNAME", "user").lower())
    ap = argparse.ArgumentParser()
    ap.add_argument("source", nargs="?", default=rf"\\wsl.localhost\Ubuntu\home\{user}\smw-build\data-stage\SMW")
    ap.add_argument("--host", default=os.environ.get("PS4_HOST", "192.168.0.90"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("PS4_FTP_PORT", "2121")))
    ap.add_argument("--dest", default="/data/SMW")
    a = ap.parse_args()
    if not os.path.isdir(a.source):
        sys.exit(f"no staged data at {a.source} (scripts/stage-data.sh)")

    plan = []  # (local path, remote folder, name, size)
    for d, dirs, files in os.walk(a.source):
        dirs.sort()
        rel = os.path.relpath(d, a.source).replace(os.sep, "/")
        rdir = a.dest if rel == "." else posixpath.join(a.dest, rel)
        for f in sorted(files):
            p = os.path.join(d, f)
            plan.append((p, rdir, f, os.path.getsize(p)))
    total = sum(s for *_, s in plan)
    print(f"{len(plan)} files, {total / 2**30:.2f} GB -> ftp://{a.host}:{a.port}{a.dest}", flush=True)

    ftp = connect(a.host, a.port)
    known_dirs, listing = set(), {}
    sent = skipped = done_bytes = 0
    t0 = last = time.time()
    for k, (p, rdir, name, size) in enumerate(plan):
        if rdir not in known_dirs:
            parts = rdir.strip("/").split("/")
            for i in range(1, len(parts) + 1):
                sub = "/" + "/".join(parts[:i])
                if sub in known_dirs:
                    continue
                try:
                    ftp.mkd(sub)
                except ftplib.error_perm:
                    pass  # already there
                known_dirs.add(sub)
            listing[rdir] = remote_sizes(ftp, rdir)
        if listing.get(rdir, {}).get(name) == size:
            skipped += 1
        else:
            for attempt in range(3):
                try:
                    with open(p, "rb") as fh:
                        ftp.storbinary("STOR " + posixpath.join(rdir, name), fh, blocksize=1 << 20)
                    break
                except (ftplib.all_errors) as e:
                    print(f"  retry {name}: {e}", flush=True)
                    try:
                        ftp.close()
                    except Exception:
                        pass
                    time.sleep(3)
                    ftp = connect(a.host, a.port)
            else:
                sys.exit(f"could not upload {p}")
            sent += 1
        done_bytes += size
        now = time.time()
        if now - last > 15 or k == len(plan) - 1:
            last = now
            rate = done_bytes / max(now - t0, 1e-6) / 2**20
            print(f"  {k + 1}/{len(plan)} files ({sent} sent, {skipped} already there), "
                  f"{done_bytes / 2**30:.2f}/{total / 2**30:.2f} GB, {rate:.1f} MiB/s", flush=True)
    ftp.quit()
    print(f"done in {(time.time() - t0) / 60:.1f} min: {sent} sent, {skipped} already there", flush=True)


if __name__ == "__main__":
    main()

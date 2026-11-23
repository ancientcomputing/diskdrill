#!/usr/bin/env python3
"""Makes a fake home folder for the App Store screenshots: build/demo/Home (about 230 GB "on disk").

    python3 packaging/screenshots/make_demo_home.py [--root DIR]

Folder Drill reports allocated blocks, like `du`, so sparse files would show as empty. Instead every
file is an APFS clone of one 2 GiB file of zeros, truncated to the size it should have. A clone's
blocks count in full for `du` and Folder Drill but are shared on disk, so the whole tree really
uses about 2 GiB. Needs an APFS volume. Delete build/demo when you're done.
"""
import argparse
import ctypes
import os
import random
import shutil
import stat
import sys
from pathlib import Path

GB = 1_000_000_000
MB = 1_000_000
KB = 1_000
BASE_SIZE = 2 * 1024 ** 3

libc = ctypes.CDLL("libc.dylib", use_errno=True)


def clone(src, dst, size):
    if libc.clonefile(os.fsencode(src), os.fsencode(dst), 0) != 0:
        err = ctypes.get_errno()
        sys.exit(f"clonefile failed for {dst}: {os.strerror(err)} (is build/ on APFS?)")
    os.truncate(dst, size)


class Fill:
    """A folder whose contents aren't shown in any screenshot: `size` bytes in generated files."""
    def __init__(self, size, files=None):
        self.size, self.files = size, files


def spread(total, rnd, lo=40 * MB, hi=900 * MB):
    """Splits `total` into file sizes between lo and hi."""
    out = []
    while total > 0:
        s = min(total, rnd.randint(lo, hi))
        out.append(s)
        total -= s
    return out


# name: dict (folder), int (file of that many bytes, at most 2 GiB) or Fill.
HOME = {
    "Library": {
        "Developer": {
            "Xcode": {
                "DerivedData": {f"{p}-{h}": Fill(s) for p, h, s in [
                    ("PhotoFrame", "gkvbxqzrdjwuyahcfmnoptesil", 9_400 * MB),
                    ("TrailLog", "bwfeqxhmzdnaorsjyliucvgtkp", 7_100 * MB),
                    ("Budgeteer", "dphtcmkwyrzaqxlbnifvseguoj", 6_300 * MB),
                    ("RecipeBox", "aqmxzrtkwhsnlfydcpvobgjeui", 4_800 * MB),
                    ("SoundBoard", "fznqhkyrwcboapsvxmeldtijgu", 3_100 * MB),
                    ("ModuleCache.noindex", "", 1_200 * MB),
                ]},
                "iOS DeviceSupport": {
                    "iPhone17,1 26.1 (23B85)": Fill(4_900 * MB),
                    "iPhone17,1 26.0 (23A341)": Fill(4_700 * MB),
                },
                "Archives": {
                    "2026-10-02": Fill(2_400 * MB),
                    "2026-08-19": Fill(2_100 * MB),
                    "2026-06-11": Fill(1_700 * MB),
                },
                "Products": Fill(640 * MB),
                "UserData": Fill(4 * MB),
            },
            "CoreSimulator": Fill(11_800 * MB),
            "XCPGDevices": Fill(320 * MB),
            "Toolchains": Fill(1_900 * MB),
        },
        "Containers": Fill(14_300 * MB),
        "Application Support": Fill(12_600 * MB),
        "Caches": Fill(9_800 * MB),
        "Messages": Fill(4_100 * MB),
        "Mail": Fill(3_400 * MB),
        "Group Containers": Fill(2_200 * MB),
        "Mobile Documents": Fill(1_600 * MB),
        "Logs": Fill(310 * MB),
        "Preferences": Fill(24 * MB),
        "Fonts": Fill(96 * MB),
        "Saved Application State": Fill(41 * MB),
        "Keychains": Fill(6 * MB),
    },
    "Movies": {
        "Summer Trip.fcpbundle": Fill(23_400 * MB),
        "Screen Recordings": Fill(6_200 * MB),
        "Wedding Highlights 4K.mov": 2_140 * MB,
        "Drone Flight 03.mov": 1_870 * MB,
        "Birthday.mov": 930 * MB,
        "TV": Fill(3_100 * MB),
    },
    "Pictures": {
        "Photos Library.photoslibrary": Fill(26_700 * MB),
        "Exports": Fill(1_400 * MB),
        "Screenshots": Fill(380 * MB),
    },
    "Downloads": {
        "Course Videos": Fill(7_800 * MB),
        "Linux-arm64-desktop.iso": 2_130 * MB,
        "Photo Backup 2025.zip": 2_050 * MB,
        "Game Assets Pack.zip": 1_640 * MB,
        "Design Kit.sketch": 412 * MB,
        "Presentation Final v3.key": 286 * MB,
        "Old Projects": Fill(3_300 * MB),
        "Installer.dmg": 1_210 * MB,
        "Podcast Raw Audio": Fill(980 * MB),
        "Statement-2026-10.pdf": 2 * MB,
        "IMG_4821.HEIC": 3 * MB,
        "Receipt.pdf": 180 * KB,
        "notes.txt": 12 * KB,
    },
    "Developer": {
        "web-dashboard": Fill(3_900 * MB, files=4000),
        "ml-experiments": Fill(6_100 * MB),
        "mobile-app": Fill(2_700 * MB, files=3000),
        "dotfiles": Fill(3 * MB, files=60),
    },
    "Documents": Fill(8_400 * MB),
    "Music": Fill(6_000 * MB),
    "Desktop": {
        "Taxes 2025.pdf": 4 * MB,
        "Mockups": Fill(860 * MB),
        "Screenshot 2026-11-20 at 09.14.22.png": 2 * MB,
    },
    "Applications": Fill(940 * MB),
    ".Trash": Fill(4_800 * MB),
    ".cache": {"huggingface": Fill(6_800 * MB), "pip": Fill(540 * MB)},
    ".npm": Fill(1_900 * MB, files=3000),
    ".docker": Fill(410 * MB),
    ".vscode": Fill(380 * MB),
    ".zsh_history": 220 * KB,
    ".zshrc": 3 * KB,
    ".gitconfig": 1 * KB,
}


def build(folder: Path, spec, base, rnd):
    folder.mkdir(parents=True, exist_ok=True)
    if isinstance(spec, Fill):
        sizes = spread(spec.size, rnd)
        for i, s in enumerate(sizes):
            sub = folder / f"{i % 4:02x}"
            sub.mkdir(exist_ok=True)
            clone(base, sub / f"data-{i:04d}.bin", s)
        small = spec.files if spec.files is not None else min(1500, max(8, spec.size // (8 * MB)))
        for i in range(small):
            sub = folder / f"{i % 16:x}" / f"{(i // 16) % 16:x}"
            sub.mkdir(parents=True, exist_ok=True)
            clone(base, sub / f"item-{i:05d}", rnd.randint(1, 40) * KB)
        return
    for name, child in spec.items():
        if isinstance(child, int):
            clone(base, folder / name, child)
        else:
            build(folder / name, child, base, rnd)


def main():
    here = Path(__file__).resolve().parents[2]
    p = argparse.ArgumentParser()
    p.add_argument("--root", default=str(here / "build" / "demo"))
    a = p.parse_args()
    root = Path(a.root)
    home = root / "Home"
    if home.exists():
        shutil.rmtree(home)
    root.mkdir(parents=True, exist_ok=True)
    base = root / ".base"
    if not base.exists() or base.stat().st_size != BASE_SIZE:
        with open(base, "wb") as f:  # real zeros (not sparse), so clones have blocks to share
            chunk = b"\0" * (8 * 1024 * 1024)
            for _ in range(BASE_SIZE // len(chunk)):
                f.write(chunk)
    build(home, HOME, base, random.Random(7))
    os.chflags(home / "Library", stat.UF_HIDDEN)  # like the real ~/Library
    print(home)


if __name__ == "__main__":
    main()

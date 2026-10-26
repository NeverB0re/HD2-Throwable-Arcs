"""Build Throwable Arcs into a mod zip (HD2 Arsenal, Modocracy):  python build.py -> dist/Throwable Arcs v<version>.zip

A test version (e.g. 0.1.0-test.1) is also copied to test-builds/, a release to release/. The patch holds the Lua and
C4's two mode icons (src/c4_*.png, made by tools/c4_icons.py) at a few sizes. Its header comes from Extended Pickup
Icons Range's build.py (taken from Boot Mod Loader, MIT), the writer from Chef Shared Loader's tools/hd2_patch.py.
"""
import json
import os
import re
import shutil
import struct
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "extended-pickup-icons-range"))
from build import SCAFFOLD, murmur64  # noqa: E402
sys.path.insert(0, os.path.join(HERE, "tools"))
import png_rgba  # noqa: E402

SOURCE = os.path.join(HERE, "src", "throwable_arcs.lua")
ARMOUR = os.path.join(HERE, "src", "armour_table.lua")
ICONS = {"deploy": os.path.join(HERE, "src", "c4_deploy.png"), "detonate": os.path.join(HERE, "src", "c4_detonate.png")}
ICON_SIZES = (24, 32, 48, 76)    # px: the icon is drawn 26-52 px tall (1080p to 4K), and the UI has no mipmaps
DIST = os.path.join(HERE, "dist")
TEST_BUILDS = os.path.join(HERE, "test-builds")
RELEASE = os.path.join(HERE, "release")
NAME = "Throwable Arcs"
FOLDER = "Addon"
RESOURCE = "mods/codex/throwable_arcs"
ARCHIVE = "9ba626afa44a3aa3.patch_0"

MANIFEST = {
    "Version": 1,
    "Guid": "7d2c9b4e-31a8-4f6c-b0e5-9a4f2d6c8e17",
    "Name": NAME,
    "Description": "Shows where a stratagem ball or a C4 charge will fly while you aim it, and C4's mode by "
                   "the crosshair. Requires Chef Shared Loader.",
    "Options": [{"Name": NAME, "Description": "Requires Chef Shared Loader.", "Include": [FOLDER]}],
}


def icon_id(mode, size):
    return murmur64(("%s/c4_%s_%d" % (RESOURCE, mode, size)).encode("utf-8"))


def built_source():
    """The mod's Lua with the armour table in its "@ARMOUR@" slot and the icons' textures in "@ICONS@"."""
    with open(SOURCE, encoding="utf-8") as f:
        source = f.read()
    with open(ARMOUR, encoding="utf-8") as f:
        armour = f.read()
    for slot in ('"@ARMOUR@"', '"@ICONS@"'):
        if source.count(slot) != 1:
            raise SystemExit("throwable_arcs.lua has no single %s slot" % slot)
    icons = ", ".join("%s = { %s }" % (mode, ", ".join("%d, '%016x'" % (n, icon_id(mode, n)) for n in ICON_SIZES))
                      for mode in sorted(ICONS))
    return source.replace('"@ARMOUR@"', "(function()\n" + armour + "end)()").replace('"@ICONS@"', "{ %s }" % icons)


# Parts adapted from Chef Shared Loader by Th3chef (tools/hd2_patch.py: texture_rgba_header, write_lua_archive)
LUA_TYPE, TEXTURE_TYPE, MAGIC = murmur64(b"lua"), 0xcd4238c6a0c69e32, 0xF0000011


def texture_rgba_header(w, h):
    """A texture's main part for w x h RGBA8 pixels, one mip (the pixels go to .gpu_resources)."""
    head = struct.pack("<III", 0, 0, 0xFFFFFFFF) + b"\0" * 180
    dds = b"DDS " + struct.pack("<7I", 124, 0x100F, h, w, w * 4, 0, 1) + b"\0" * 44
    dds += struct.pack("<2I4s5I", 32, 4, b"DX10", 0, 0, 0, 0, 0)
    dds += struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    dds += struct.pack("<5I", 28, 3, 0, 1, 0)
    return head + dds


def write_archive(path, lua, textures):
    """lua: [(id, source bytes)]; textures: [(id, w, h, RGBA bytes)]. The header's engine part from a working patch."""
    entries = [(fid, struct.pack("<II", len(src), 2) + src) for fid, src in lua]
    n = len(entries) + len(textures)
    head = struct.pack("<III", MAGIC, 2 if textures else 1, n) + SCAFFOLD[12:72]
    head += struct.pack("<QQQII", 0, LUA_TYPE, len(entries), 16, 16)
    if textures:
        head += struct.pack("<QQQII", 0, TEXTURE_TYPE, len(textures), 16, 64)
    cursor, rows, body, gpu = len(head) + 80 * n, b"", b"", bytearray()
    for i, (fid, data) in enumerate(entries):
        pad = -cursor % 16
        body += b"\0" * pad
        cursor += pad
        rows += struct.pack("<7Q6I", fid, LUA_TYPE, cursor, 0, 0, 0, 0, len(data), 0, 0, 16, 16, i)
        body += data
        cursor += len(data)
    for j, (fid, w, h, pixels) in enumerate(textures, len(entries)):
        data = texture_rgba_header(w, h)
        pad = -cursor % 16
        body += b"\0" * pad
        cursor += pad
        gpu += b"\0" * (-len(gpu) % 64)
        goff = len(gpu)
        gpu += pixels
        rows += struct.pack("<7Q6I", fid, TEXTURE_TYPE, cursor, 0, goff, 0, 0, len(data), 0, len(pixels), 16, 64, j)
        body += data
        cursor += len(data)
    out = head + rows + body
    out += b"\0" * (-len(out) % 16)
    with open(path, "wb") as f:
        f.write(out)
    with open(path + ".gpu_resources", "wb") as f:
        f.write(bytes(gpu))
    open(path + ".stream", "wb").close()


def icon_textures():
    out = []
    for mode in sorted(ICONS):
        _, _, rows = png_rgba.read(ICONS[mode])
        for n in ICON_SIZES:
            px = rows if n == len(rows) else png_rgba.shrink(rows, n)
            out.append((icon_id(mode, n), n, n, bytes(v for r in px for p in r for v in p)))
    return out


def build():
    source = built_source()
    if not source.startswith("-- HD2-Addon: " + RESOURCE + "\n"):
        raise SystemExit("the first line must declare " + RESOURCE)
    for banned in ("require('ffi')", 'require("ffi")', "ffi.", "bit.", "jit.", "popen", "os.execute", "goto "):
        if banned in source:
            raise SystemExit("the mod names %r" % banned)
    version = re.search(r"local VERSION = '([0-9A-Za-z.-]+)'", source).group(1)
    out_dir = os.path.join(DIST, "%s v%s" % (NAME, version))
    if os.path.exists(out_dir):
        raise SystemExit("%s exists: bump VERSION or delete it" % out_dir)
    os.makedirs(os.path.join(out_dir, FOLDER))
    write_archive(os.path.join(out_dir, FOLDER, ARCHIVE), [(murmur64(RESOURCE.encode("utf-8")), source.encode("utf-8"))],
                  icon_textures())
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(MANIFEST, f, indent=2)
        f.write("\n")
    zip_path = out_dir + ".zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for base, _dirs, files in os.walk(out_dir):
            for name in sorted(files):
                full = os.path.join(base, name)
                z.write(full, os.path.relpath(full, out_dir))
    keep = TEST_BUILDS if "-test." in version else RELEASE
    os.makedirs(keep, exist_ok=True)
    shutil.copy(zip_path, keep)
    print("wrote %s" % zip_path)


if __name__ == "__main__":
    sys.exit(build())

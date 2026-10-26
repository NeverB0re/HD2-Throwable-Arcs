"""Build Throwable Arcs into a mod zip (HD2 Arsenal, Modocracy):  python build.py -> dist/Throwable Arcs v<version>.zip

A test version (e.g. 0.1.0-test.1) is also copied to test-builds/, a release to release/. The archive writer is Extended Pickup Icons Range's
build.py (write_module), taken from Boot Mod Loader (MIT).
"""
import json
import os
import re
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "extended-pickup-icons-range"))
from build import write_module  # noqa: E402

SOURCE = os.path.join(HERE, "src", "throwable_arcs.lua")
ARMOUR = os.path.join(HERE, "src", "armour_table.lua")
DIST = os.path.join(HERE, "dist")
TEST_BUILDS = os.path.join(HERE, "test-builds")
RELEASE = os.path.join(HERE, "release")
NAME = "Throwable Arcs"
FOLDER = "Addon"
RESOURCE = "mods/codex/throwable_arcs"

MANIFEST = {
    "Version": 1,
    "Guid": "7d2c9b4e-31a8-4f6c-b0e5-9a4f2d6c8e17",
    "Name": NAME,
    "Description": "Shows where a stratagem ball or a C4 charge will fly while you aim it, and C4's mode by "
                   "the crosshair. Requires Chef Shared Loader.",
    "Options": [{"Name": NAME, "Description": "Requires Chef Shared Loader.", "Include": [FOLDER]}],
}


def built_source():
    """The mod's Lua with the armour table put in its "@ARMOUR@" slot."""
    with open(SOURCE, encoding="utf-8") as f:
        source = f.read()
    with open(ARMOUR, encoding="utf-8") as f:
        armour = f.read()
    if source.count('"@ARMOUR@"') != 1:
        raise SystemExit('throwable_arcs.lua has no single "@ARMOUR@" slot')
    return source.replace('"@ARMOUR@"', "(function()\n" + armour + "end)()")


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
    write_module(os.path.join(out_dir, FOLDER), RESOURCE, source)
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

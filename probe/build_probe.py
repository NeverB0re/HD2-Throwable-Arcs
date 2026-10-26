"""Build Engine Probe into a mod zip (HD2 Arsenal, Modocracy):  python build_probe.py -> dist/Engine Probe v<version>.zip

The archive writer is Extended Pickup Icons Range's build.py (write_module), taken from Boot Mod Loader (MIT).
"""
import json
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "extended-pickup-icons-range"))
from build import write_module  # noqa: E402

SOURCE = os.path.join(HERE, "engine_probe.lua")
DIST = os.path.join(HERE, "dist")
NAME = "Engine Probe"
FOLDER = "Addon"
RESOURCE = "mods/codex/engine_probe"

MANIFEST = {
    "Version": 1,
    "Guid": "c3e1f6a2-4d7b-4f0e-9b2a-8e5d1c7a3f90",
    "Name": NAME,
    "Description": "Test mod: checks terrain height, unit boxes and line depth for a throw-arc mod, and logs thrown "
                   "units to engine_probe.log. Requires Chef Shared Loader.",
    "Options": [{"Name": NAME, "Description": "Requires Chef Shared Loader.", "Include": [FOLDER]}],
}


def build():
    with open(SOURCE, encoding="utf-8") as f:
        source = f.read()
    if not source.startswith("-- HD2-Addon: " + RESOURCE + "\n"):
        raise SystemExit("the first line must declare " + RESOURCE)
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
    print("wrote %s" % zip_path)


if __name__ == "__main__":
    sys.exit(build())

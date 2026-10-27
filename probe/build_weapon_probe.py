"""Build Weapon Probe into a mod zip:  python build_weapon_probe.py -> dist/Weapon Probe v<version>.zip

Weapon unit names come from filediver's hash list (research/filediver/all.txt): every .unit under an equipment
*_weapons folder, as "kind folder/file". The archive writer is Extended Pickup Icons Range's build.py (write_module),
taken from Boot Mod Loader (MIT).
"""
import json
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "extended-pickup-icons-range"))
from build import write_module  # noqa: E402

SOURCE = os.path.join(HERE, "weapon_probe.lua")
HASHES = os.path.join(HERE, "..", "..", "..", "research", "filediver", "all.txt")
DIST = os.path.join(HERE, "dist")
NAME = "Weapon Probe"
FOLDER = "Addon"
RESOURCE = "mods/codex/weapon_probe"

MANIFEST = {
    "Version": 1,
    "Guid": "5b0c2f7e-91d4-4a63-8f1e-2c7a9d4b6e15",
    "Name": NAME,
    "Description": "Test mod: logs the weapon in hand and what each shot fires to weapon_probe.log, for a weapon-arc "
                   "mod. Draws nothing. Requires Chef Shared Loader.",
    "Options": [{"Name": NAME, "Description": "Requires Chef Shared Loader.", "Include": [FOLDER]}],
}

UNIT = re.compile(r"^content/[a-z_]+/equipment/([a-z_]*_weapons/[a-z0-9_/]+)\.unit, 0x([0-9a-f]{16})\.")


def weapon_names():
    """'kind folder/file' lines, one per weapon unit"""
    out = {}
    with open(HASHES, encoding="utf-8") as f:
        for line in f:
            m = UNIT.match(line)
            if m:
                parts = m.group(1).split("/")
                out[m.group(2)] = "%s/%s" % (parts[0], parts[-1])
    return "\n".join("%s %s" % (k, v) for k, v in sorted(out.items(), key=lambda kv: kv[1]))


def source_text():
    with open(SOURCE, encoding="utf-8") as f:
        source = f.read()
    if not source.startswith("-- HD2-Addon: " + RESOURCE + "\n"):
        raise SystemExit("the first line must declare " + RESOURCE)
    if source.count("@WEAPONS@") != 1:
        raise SystemExit("@WEAPONS@ must appear once")
    return source.replace("@WEAPONS@", weapon_names())


def build():
    source = source_text()
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

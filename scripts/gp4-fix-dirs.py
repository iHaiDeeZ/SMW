#!/usr/bin/env python3
"""Adds the folders create-gp4 left out of a .gp4 project's <rootdir> tree.

create-gp4 drops a folder whose name another folder already used elsewhere (the game data has romfs/Model and
romfs/Bake/Model, romfs/Scene and romfs/Bake/Scene), and PkgTool's pkg_build then stops on the first file in one
("Sequence contains no elements" in PfsProperties.FindDir). Every file's folder chain is put back.
    gp4-fix-dirs.py pkg.gp4
"""
import sys
import xml.etree.ElementTree as ET


def main():
    path = sys.argv[1]
    tree = ET.parse(path)
    root = tree.getroot()
    rootdir = root.find(".//rootdir")
    if rootdir is None:
        return

    def child(parent, name):
        for d in parent.findall("dir"):
            if d.get("targ_name") == name:
                return d
        d = ET.SubElement(parent, "dir")
        d.set("targ_name", name)
        added.append(name)
        return d

    added = []
    for f in root.iter("file"):
        parts = f.get("targ_path", "").split("/")[:-1]
        node = rootdir
        for name in parts:
            node = child(node, name)
    if added:
        tree.write(path, encoding="utf-8", xml_declaration=True)
        print("gp4: added", len(added), "folders create-gp4 left out:", ", ".join(added[:6]))


if __name__ == "__main__":
    main()

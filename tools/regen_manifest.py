#!/usr/bin/env python3
"""Regenerate <repo>/canon/MANIFEST.json (the deploy manifest) after
dev-loop edits to canon/root/.

Only the file inventory + sha256 map + file_count are refreshed;
canon_version, canary, gitignore, description and any envelope/
orchestrator keys are preserved from the existing manifest. Version
bumps and envelope stamps belong to canon_pub.sh, not this tool.

Usage: python3 tools/regen_manifest.py [repo_root ...]
"""
import hashlib, json, os, sys


def regen(base):
    mp = os.path.join(base, "canon/MANIFEST.json")
    man = json.load(open(mp))
    root = os.path.join(base, man["canon_home"])  # canon/root
    files, hashes = [], {}
    for dp, dn, fn in os.walk(root):
        if "__pycache__" in dp:
            continue
        for f in fn:
            if f.endswith(".pyc") or f == "MANIFEST.json":
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root)
            files.append(rel)
            hashes[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    man["files"] = sorted(files)
    man["sha256"] = {k: hashes[k] for k in man["files"]}
    man["file_count"] = len(files)
    with open(mp, "w") as f:
        f.write(json.dumps(man, indent=2, sort_keys=True) + "\n")
    print(mp, len(files), "files")


if __name__ == "__main__":
    roots = sys.argv[1:] or [
        os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    ]
    for r in roots:
        regen(r)

#!/usr/bin/env python3
"""Regenerate both MANIFEST.json files for the CCSDD canon tree.

Usage: python3 tools/regen_manifest.py [repo_root ...]

- <repo>/canon/MANIFEST.json      (deploy manifest: files/sha256/file_count,
                                   preserves canary/canon_version/gitignore)
- <repo>/canon/root/canon/MANIFEST.json (inner integrity manifest)
"""
import hashlib, json, os, sys


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


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
            hashes[rel] = sha(p)
    man["files"] = sorted(files)
    man["sha256"] = {k: hashes[k] for k in man["files"]}
    man["file_count"] = len(files)
    with open(mp, "w") as f:
        f.write(json.dumps(man, indent=2, sort_keys=True) + "\n")

    inner = os.path.join(base, "canon/root/canon")
    im = {"files": {}}
    for dp, dn, fn in os.walk(inner):
        if "__pycache__" in dp:
            continue
        for f in fn:
            if f.endswith(".pyc") or f == "MANIFEST.json":
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, inner)
            im["files"][rel] = {
                "sha256": sha(p),
                "mode": "755" if os.access(p, os.X_OK) else "644",
            }
    im["files"] = dict(sorted(im["files"].items()))
    with open(os.path.join(inner, "MANIFEST.json"), "w") as f:
        f.write(json.dumps(im, indent=2, sort_keys=True) + "\n")
    print(base, len(files), "files")


if __name__ == "__main__":
    roots = sys.argv[1:] or [
        os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    ]
    for r in roots:
        regen(r)

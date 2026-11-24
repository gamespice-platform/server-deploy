#!/usr/bin/env python3
"""Static check of a BUILT shell artifact (or an install tree), not the repo source.

  check_artifact_static.py ROOT [ROOT...]

Each ROOT is one res:// tree: a directory, or a directory tools/artifact_unpack.gd filled from an exported pck (it also
holds _paths.txt, the full file list). Roots are judged together, so a shell tree plus a game pack's overlay is one
namespace, as it is at runtime. FAILS (exit 1) on:
  - any addons/dot_* directory, or a dot_*.gd script anywhere (the pre-rename addons a shell must no longer carry)
  - a Dot* class_name
  - a text file naming a dev-only origin or the dev panel (DEV_ORIGIN: tmcdev.net, tmcdevgames.net, x-tmc-dev): a prod shell
    or game pack must not send players to the dev box (override the pattern with ARTIFACT_DEV_ORIGIN; "" turns it off)
  - one uid:// claimed by two different files (the 2026-11-23 prod outage: dot_combat/dot_pellet_tracer.gd and
    gs_combat/gs_pellet_tracer.gd both owned uid://cbebxr4alar6d, and the server would not boot)
Exit 2 when a root is unreadable or holds nothing to judge.
"""
import os, re, sys
from collections import defaultdict

HDR = re.compile(r'^\[gd_(?:scene|resource)[^\]]*\buid="(uid://[a-z0-9]+)"', re.M)
UID = re.compile(r'uid://[a-z0-9]+')


DEV_ORIGIN = re.compile(os.environ.get("ARTIFACT_DEV_ORIGIN", r'tmcdev(?:games)?\.net|x-tmc-dev')) if os.environ.get("ARTIFACT_DEV_ORIGIN", "x") else None
TEXT = (".gd", ".tscn", ".tres", ".cfg", ".json", ".html", ".js", ".txt", ".yml", ".yaml", ".remap")


def ns_of(rel):
    """The published shell bundles every game under games/<id>/, each its own res:// tree once
    that game is mounted, so a uid is only a clash inside one tree (games/<id>/ or the shell root)."""
    m = re.match(r'(games/[^/]+)/', rel)
    return m.group(1) if m else ""


def owner_of(rel):
    for suf in (".uid", ".remap", ".import"):
        if rel.endswith(suf):
            rel = rel[: -len(suf)]
            break
    return re.sub(r'\.gdc$', '.gd', rel)


def scan(roots):
    owners = defaultdict(set)   # uid -> resource paths (root-relative)
    paths, classes, devs = [], [], []
    for root in roots:
        listed = os.path.join(root, "_paths.txt")
        has_list = os.path.isfile(listed)
        if has_list:
            paths += [l.strip().removeprefix("res://") for l in open(listed) if l.strip()]
        for d, _, files in os.walk(root):
            for fn in files:
                if fn == "_paths.txt":
                    continue
                full = os.path.join(d, fn)
                rel = os.path.relpath(full, root)
                if not has_list:
                    paths.append(rel)
                try:
                    text = open(full, errors="replace").read()
                except OSError:
                    continue
                if DEV_ORIGIN and fn.endswith(TEXT):
                    m = DEV_ORIGIN.search(text)
                    if m:
                        devs.append(f"{rel} names {m.group(0)}")
                if fn.endswith(".uid"):
                    for u in UID.findall(text):
                        owners[(ns_of(rel), u)].add(owner_of(rel))
                elif fn.endswith((".remap", ".import")):
                    m = re.search(r'^uid="(uid://[a-z0-9]+)"', text, re.M)
                    if m:
                        owners[(ns_of(rel), m.group(1))].add(owner_of(rel))
                elif fn.endswith((".tscn", ".tres")):
                    m = HDR.search(text)
                    if m:
                        owners[(ns_of(rel), m.group(1))].add(rel)
                elif fn.endswith(".gd"):
                    for m in re.finditer(r'^class_name\s+(Dot\w*)', text, re.M):
                        classes.append(f"Dot* class {m.group(1)} in {rel}")
    return owners, paths, classes, devs


def main(argv):
    roots = argv[1:]
    if not roots:
        print(__doc__)
        return 2
    for r in roots:
        if not os.path.isdir(r):
            print(f"check_artifact_static: {r} is not a directory")
            return 2
    owners, paths, classes, devs = scan(roots)
    if not paths:
        print("check_artifact_static: nothing to judge in the roots")
        return 2
    bad = []
    if classes:   # one line with a count and the first few: a stale addon has dozens
        bad.append(f"{len(classes)} Dot* class_name(s), first: " + "; ".join(classes[:3]))
    if devs:
        bad.append(f"{len(devs)} file(s) name a dev-only origin, first: " + "; ".join(devs[:3]))
    dirs = {}
    for p in sorted(set(paths)):
        m = re.match(r'((?:games/[^/]+/)?addons/dot_[^/]+)(/|$)', p)
        if m:
            dirs[m.group(1)] = dirs.get(m.group(1), 0) + 1
        elif re.search(r'(^|/)dot_[^/]*\.(gd|gdc)$', p):
            bad.append(f"stale dot_* script in the artifact: {p}")
    for d, n in dirs.items():
        bad.append(f"stale addon directory {d} ({n} files): a pre-rename addon must not ship beside its gs_* successor")
    for (_ns, u), who in sorted(owners.items()):
        if len(who) > 1:
            bad.append(f"duplicate uid {u} claimed by: {', '.join(sorted(who))}")
    if bad:
        for b in bad:
            print(f"ERROR: {b}")
        print(f"check_artifact_static: FAIL ({len(bad)} problem(s), {len(set(paths))} files in {len(roots)} root(s))")
        return 1
    print(f"check_artifact_static: ok ({len(set(paths))} files, {len({u for _, u in owners})} uids, {len(roots)} root(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

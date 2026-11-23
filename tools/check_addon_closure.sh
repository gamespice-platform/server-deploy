#!/usr/bin/env bash
# Dependency closure of the addon lock: an addon whose runtime scripts name a class (or a res://addons/ path) that only
# ANOTHER addon defines needs that addon in the lock, and a shell addon needs it in the shell. Text only, no Godot.
#
#   tools/check_addon_closure.sh [addons.lock]      exit 0 closed, 1 an addon is missing, 2 setup
#   TMC_SIBLINGS=DIR                                 where the addon clones are (default: as tools/check_shell_parse.sh)
#   CLOSURE_SHELL_LIST=FILE                          another shell list (default tools/shell-addons.list)
#
# 2026-11-21: gs-player-char v0.1.76 extends gs-animation's class and gs-spectate gs-camera's; the lock had neither, and
# pack_ready/requires judged addon LEVELS only, so nothing saw it until a client segfaulted joining Fatal Contact and
# Hungario. Class definitions are read from every sibling gs-* clone (its newest tag), so an addon the lock lacks still
# resolves. check_shell_parse.sh proves the same on a real parse (needs Godot); this is the fast text twin.
# Arm it by deleting the gs-camera line from addons.lock.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIB="${TMC_SIBLINGS:-}"
if [ -z "$SIB" ]; then
  _common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$_common" ] && [ "$(dirname "$_common")" != "$ROOT" ]; then SIB="$(dirname "$(dirname "$_common")")"; else SIB="$ROOT/.."; fi
fi
LOCK="${1:-$ROOT/addons.lock}"
[ -f "$LOCK" ] || { echo "check_addon_closure: no $LOCK" >&2; exit 2; }
exec python3 -I - "$LOCK" "$SIB" "${CLOSURE_SHELL_LIST:-$ROOT/tools/shell-addons.list}" <<'PY'
import os, re, subprocess, sys, tarfile, io, glob
lockp, sib, listp = sys.argv[1:4]
lock = {}
for l in open(lockp):
    if l.strip() and not l.startswith("#") and "\t" in l:
        r, t = l.split("\t")[:2]; lock[r.strip()] = t.strip()
shell = {re.sub(r"\s", "", l.split("#")[0]) for l in open(listp)} - {""} if os.path.isfile(listp) else set()
def git(d, *a, raw=False):
    r = subprocess.run(["git", "-C", d, *a], capture_output=True)
    return r.stdout if raw else r.stdout.decode("utf-8", "replace")
def newest(d):
    vt = []
    for t in git(d, "tag", "-l", "v*").split():
        m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", t)
        if m: vt.append((tuple(map(int, m.groups())), t))
    return max(vt)[1] if vt else "HEAD"
SKIP = re.compile(r"/(examples|tests?|tools|editor)/")
def scripts(d, ref):
    out = {}
    raw = git(d, "archive", ref, "addons", raw=True)
    if not raw: return out
    with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
        for m in tf:
            if m.isfile() and m.name.endswith(".gd") and not SKIP.search("/" + m.name):
                out[m.name] = tf.extractfile(m).read().decode("utf-8", "replace")
    return out
def code(text):
    keep = []
    for ln in text.splitlines():
        if ln.lstrip().startswith("#"): continue
        if "#" in ln and ln.count('"') % 2 == 0 and ln.count("'") % 2 == 0: ln = ln.split("#")[0]
        keep.append(ln)
    return "\n".join(keep)
repos = sorted(set(lock) | {os.path.basename(p) for p in glob.glob(sib + "/gs-*") if os.path.exists(p + "/.git")})
src, defs, dirs = {}, {}, {}
for r in repos:
    d = sib + "/" + r
    if not os.path.exists(d + "/.git"):
        print("check_addon_closure: lock names %s but %s is not cloned" % (r, d)); sys.exit(2)
    src[r] = scripts(d, lock.get(r) or newest(d))
    for p, t in src[r].items():
        parts = p.split("/")
        if len(parts) > 1: dirs.setdefault(parts[1], set()).add(r)
        for m in re.finditer(r"^\s*class_name\s+([A-Za-z_]\w*)", t, re.M): defs.setdefault(m[1], set()).add(r)
bad = []
strlit = re.compile(r'&?"(?:[^"\\\n]|\\.)*"|&?\'(?:[^\'\\\n]|\\.)*\'')
ident = re.compile(r"\b[A-Z][A-Za-z0-9_]*\b")
pathre = re.compile(r"res://addons/(\w+)/")
for r in sorted(lock):
    need = {}
    for p, t in src[r].items():
        c = code(t)
        for n in set(ident.findall(strlit.sub('""', c))):
            ds = defs.get(n)
            if ds and r not in ds: need.setdefault(frozenset(ds), (n, p))
        for dn in set(pathre.findall(c)):
            ds = dirs.get(dn)
            if ds and r not in ds: need.setdefault(frozenset(ds), ("res://addons/%s/" % dn, p))
    for ds, (what, p) in sorted(need.items(), key=lambda kv: sorted(kv[0])):
        if not (ds & set(lock)):
            bad.append("%s %s uses %s (in %s), defined only by %s, which addons.lock does not carry" % (r, lock[r], what, p, "/".join(sorted(ds))))
        elif r in shell and not (ds & shell):
            bad.append("%s %s uses %s (in %s), defined only by %s, which tools/shell-addons.list does not carry: the shell would not compile" % (r, lock[r], what, p, "/".join(sorted(ds))))
if bad:
    print("FAIL addon closure: %d missing dependenc%s" % (len(bad), "y" if len(bad) == 1 else "ies"))
    for b in bad: print("     " + b)
    print("     add each missing addon to addons.lock, content-lists/addons.yml and (a shell addon) tools/shell-addons.list")
    sys.exit(1)
print("ok   addon closure: %d locked addons name nothing the lock (or the shell list) lacks" % len(lock))
PY

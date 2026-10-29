#!/usr/bin/env python3
"""full-render-diff.py: the render-diff gate of the prod roll inputs. ONE tool (CHAOS-11737); it replaces full-render-diff.py and
render-docs-diff-v4.py of the 11652 window.

  full-render-diff.py filter < manifest > out.yaml
      Drops every Secret doc and redacts every secret-like value, in memory, before anything is written (for a live manifest).
  full-render-diff.py names < manifest > out.names
      One sorted `Kind/name` line per doc, Secrets included, and nothing else (no data, no field).
  full-render-diff.py A B --rc-a N --rc-b N  ( --expect-added Kind/name[,...] | --expect-rows FILE | --info )
                      [--live] [--min-docs N] [--names NA NB --expect-names-added Kind/name[,...]]

A and B are two renders (helm template, or a filtered live manifest). The tool does not call helm: --rc-a/--rc-b are the helm return
codes the caller saw (keep `set -o pipefail` around a pipe). Both are REQUIRED. Exactly one of --expect-added / --expect-rows / --info.

FLOOR (STOP, exit 1, before any diff): a helm rc != 0, fewer than --min-docs docs on a side (default 1), a render that is not valid YAML,
an empty --names file. Both sides always print `render A|B: helm rc=<n> docs=<n>`. A doc counts when it is a mapping with a kind.
--min-docs N: the least docs a side must hold. Set the real count in a roll input. Note: a live helm get manifest / dry-run .manifest has no hooks; a helm template render has them
(say which with --live (hook-free) or not (hook-included)).

SECRETS: a Secret doc enters only as Kind/name, with no data, stringData or key value, in EVERY mode. Values of env entries whose name
matches PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE|DSN|CREDENTIAL|_URI$|KEY$, ConfigMap data/binaryData under a key matching
password|secret|token|key|dsn|credential, args/command entries holding both :// and @, and any string with scheme://user@ are redacted
on load. No value is printed; paths carry names only.

LISTS: a list whose elements are all mappings with a non-empty string `name` is compared BY NAME (containers, initContainers, env,
volumes, volumeMounts, ports, ...); a list of mappings that all carry containerPort or port is keyed number/protocol; a duplicate key is a
STOP found by one pass over every doc of both sides (added and removed docs too) BEFORE any comparison: the DUPLICATE lines, then STOP/HOLD, and no row line at all. One element only on one side is ONE row (ELEMENT-ADDED / ELEMENT-REMOVED). A different order of the common names is a REORDERED
row (order has meaning: initContainers run order, containers[0], env $(VAR) references): it passes only when --expect-rows lists it.
A missing key, null, [] and {} are FOUR distinct values, at any position: the same form on both sides is no row, two different forms are ONE CHANGED row (helm's patch sends `<field>: null`, which deletes a live non-empty value). An empty list against a non-empty named list is one row per element.
Every other list (args, command, rules, ...) is compared by index.

MODES: --expect-added: PASS iff the added docs are exactly the list, nothing is removed and there are 0 rows. --expect-rows FILE (JSON
{"added":[], "removed":[], "rows":[{"doc","path","verb","old","new","before","after","show"}]}): PASS iff docs and rows equal the file
exactly; before/after are checked silently, a value is printed only for a row with "show": true. --info: print the diff, exit 0.
--live: the docs came from a live manifest (hook-free) and the window summary line is printed too.
--names NA NB --expect-names-added L: the Kind/name sets of the two names files differ by exactly L and nothing is removed.
Exit 0 PASS, 1 STOP/HOLD, 2 usage, an unreadable file or a duplicate doc.
"""
import json
import os
import re
import sys

import yaml

SECRETY = re.compile(r"(PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE|DSN|CREDENTIAL|_URI$|KEY$)", re.I)
CMKEY = re.compile(r"(password|secret|token|key|dsn|credential)", re.I)
USERINFO = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s/]*@")
POSTGRES_STS = "StatefulSet/dev-health-ops-postgresql"
LIST_VERBS = ("ELEMENT-ADDED", "ELEMENT-REMOVED", "REORDERED")


def redact(o):
    if isinstance(o, dict):
        o = dict(o)
        if isinstance(o.get("name"), str) and "value" in o and SECRETY.search(o["name"]):
            o["value"] = "<redacted>"
        if o.get("kind") == "ConfigMap":
            for sec in ("data", "binaryData"):
                if isinstance(o.get(sec), dict):
                    o[sec] = {k: ("<redacted>" if CMKEY.search(str(k)) else v) for k, v in o[sec].items()}
        for argk in ("args", "command"):
            if isinstance(o.get(argk), list):
                o[argk] = [("<redacted>" if isinstance(x, str) and "://" in x and "@" in x else x) for x in o[argk]]
        return {k: redact(v) for k, v in o.items()}
    if isinstance(o, list):
        return [redact(v) for v in o]
    if isinstance(o, str) and USERINFO.search(o):
        return "<redacted>"
    return o


def docs_of(stream):
    return [d for d in yaml.safe_load_all(stream) if isinstance(d, dict) and d.get("kind")]


def key(d):
    return "%s/%s" % (d["kind"], (d.get("metadata") or {}).get("name"))


def usage(msg=None):
    if msg:
        print(msg)
    print(__doc__)
    sys.exit(2)


class Side:
    def __init__(self, label, path, rc):
        self.label, self.path, self.rc = label, path, rc
        self.docs = {}
        self.error = None
        self.count = 0
        self.live_count = 0
        try:
            with open(path) as f:
                parsed = docs_of(f)
        except OSError as exc:
            usage("cannot read %s: %s" % (path, exc.strerror))
        except yaml.YAMLError:
            self.error = "render %s is not valid YAML" % label
            parsed = []
        self.count = len(parsed)
        for d in parsed:
            k = key(d)
            if k in self.docs:
                print("DUPLICATE doc %s in %s" % (k, path))
                sys.exit(2)
            if d["kind"] == "Secret":
                self.docs[k] = {"kind": "Secret", "metadata": {"name": (d.get("metadata") or {}).get("name")}}
            else:
                self.docs[k] = redact(d)
                self.live_count += 1


def flat(o, pre=""):
    """The leaves of o. An EMPTY container ({} or []) is a leaf too: added or removed at a list index or under a missing key it must
    be a row (NetworkPolicy ingress [] -> [{}] turns deny-all into allow-all)."""
    if isinstance(o, dict) and o:
        for k in sorted(o, key=str):
            yield from flat(o[k], pre + "." + str(k))
    elif isinstance(o, list) and o:
        for i, v in enumerate(o):
            yield from flat(v, "%s[%d]" % (pre, i))
    else:
        yield pre, o


def same(x, y):
    """Equal WITH the type: python's True == 1 == 1.0 would hide replicas 1 -> true; 1 vs "1" and 1 vs 1.0 are changes too."""
    return type(x) is type(y) and x == y


def form(v):
    """The empty forms: a missing key, null, [] and {} are FOUR distinct values (helm's three-way patch sends `<field>: null` for
    missing -> null, which deletes a live non-empty value). None for a value that is not one of them."""
    if v is _NONE:
        return "missing"
    if v is None:
        return "null"
    if isinstance(v, list) and not v:
        return "list"
    if isinstance(v, dict) and not v:
        return "map"
    return None


def list_keys(lst):
    """(kind, [keys]) when the list is keyed by name or by port, else None."""
    if lst and all(isinstance(e, dict) and isinstance(e.get("name"), str) and e["name"] for e in lst):
        return "name", [e["name"] for e in lst]
    if lst and all(isinstance(e, dict) and isinstance(e.get("containerPort", e.get("port")), int) for e in lst):
        return "port", ["%d/%s" % (e.get("containerPort", e.get("port")), e.get("protocol") or "TCP") for e in lst]
    return None


class Diff:
    def __init__(self, doc):
        self.doc = doc
        self.rows = []  # (path, verb, old, new, before, after)

    def row(self, path, verb, old=None, new=None, before=None, after=None):
        self.rows.append((path, verb, old, new, before, after))

    def walk(self, a, b, path):
        fa, fb = form(a), form(b)
        if fa and fb:
            if fa != fb:
                self.row(path, "CHANGED", before=a, after=b)
            return
        if isinstance(a, dict) and isinstance(b, dict):
            for k in sorted(set(a) | set(b), key=str):
                p = "%s.%s" % (path, k)
                va, vb = a.get(k, _NONE), b.get(k, _NONE)
                fa, fb = form(va), form(vb)
                if fa and fb:
                    if fa != fb:
                        self.row(p, "CHANGED", before=va, after=vb)
                    continue
                if fa in ("missing", "null", "list") and isinstance(vb, list) and list_keys(vb):
                    self.walk([], vb, p)
                elif fb in ("missing", "null", "list") and isinstance(va, list) and list_keys(va):
                    self.walk(va, [], p)
                elif k not in b or k not in a:
                    self.leaves(va, vb, p)
                else:
                    self.walk(va, vb, p)
        elif isinstance(a, list) and isinstance(b, list):
            ka, kb = list_keys(a), list_keys(b)
            if not a and kb:
                ka = (kb[0], [])
            if not b and ka:
                kb = (ka[0], [])
            if ka and kb and ka[0] == kb[0]:
                self.keyed(a, b, ka, kb, path)
            else:
                for i in range(max(len(a), len(b))):
                    p = "%s[%d]" % (path, i)
                    if i >= len(a) or i >= len(b):
                        self.leaves(a[i] if i < len(a) else _NONE, b[i] if i < len(b) else _NONE, p)
                    else:
                        self.walk(a[i], b[i], p)
        else:
            self.leaves(a, b, path)

    def leaves(self, a, b, path):
        fa = dict(flat(a, path)) if a is not _NONE else {}
        fb = dict(flat(b, path)) if b is not _NONE else {}
        if a is not _NONE and not isinstance(a, (dict, list)):
            fa = {path: a}
        if b is not _NONE and not isinstance(b, (dict, list)):
            fb = {path: b}
        for p in sorted(set(fa) | set(fb)):
            if not same(fa.get(p, _NONE), fb.get(p, _NONE)) or (p in fa) != (p in fb):
                self.row(p, "CHANGED", before=fa.get(p, _NONE), after=fb.get(p, _NONE))

    def keyed(self, a, b, ka, kb, path):
        kind = ka[0]
        names_a, names_b = ka[1], kb[1]
        ia = dict(zip(names_a, a))
        ib = dict(zip(names_b, b))
        common_a = [n for n in names_a if n in ib]
        common_b = [n for n in names_b if n in ia]
        if common_a != common_b:
            self.row(path, "REORDERED", old=list(names_a), new=list(names_b))
        for n in sorted(set(names_a) | set(names_b)):
            p = "%s[%s=%s]" % (path, kind, n)
            if n not in ia:
                self.row(p, "ELEMENT-ADDED")
            elif n not in ib:
                self.row(p, "ELEMENT-REMOVED")
            else:
                self.walk(ia[n], ib[n], p)


class _NoneType:
    def __repr__(self):
        return "<none>"


_NONE = _NoneType()


def find_dups(o, doc, path, label, out):
    """Every duplicate key of every keyed list under o (a doc of render `label`)."""
    if isinstance(o, dict):
        for k in sorted(o, key=str):
            find_dups(o[k], doc, "%s.%s" % (path, k), label, out)
    elif isinstance(o, list):
        keyed = list_keys(o)
        if keyed:
            seen = set()
            for n in keyed[1]:
                if n in seen:
                    out.append("DUPLICATE name %s in %s %s (render %s)" % (n, doc, path, label))
                seen.add(n)
        for i, e in enumerate(o):
            find_dups(e, doc, "%s[%d]" % (path, i), label, out)


def duplicate_lines(a, b):
    """One pass over EVERY doc of BOTH sides (added and removed docs included), before any comparison."""
    lines = []
    for label, side in (("A", a), ("B", b)):
        for k in sorted(side):
            find_dups(side[k], k, "", label, lines)
    return lines


def stop_duplicates(final, bad_word, lines):
    for line in lines:
        print(line)
    print("%s: %s (duplicate names)" % (final, bad_word))
    return 1


def parse_args(argv):
    opts = {"live": False, "min_docs": 1, "names": None, "expect_names": None, "expect_added": None, "expect_rows": None, "info": False}
    pos = []
    i = 0

    def val(name):
        nonlocal i
        if i + 1 >= len(argv):
            usage("%s needs a value" % name)
        i += 1
        return argv[i]

    rcs = {}
    while i < len(argv):
        a = argv[i]
        if a in ("--rc-a", "--rc-b"):
            v = val(a)
            if not re.fullmatch(r"-?[0-9]+", v):
                usage("%s must be an integer" % a)
            rcs[a] = int(v)
        elif a == "--expect-added":
            opts["expect_added"] = sorted(x for x in val(a).split(",") if x)
        elif a == "--expect-rows":
            opts["expect_rows"] = val(a)
        elif a == "--info":
            opts["info"] = True
        elif a == "--live":
            opts["live"] = True
        elif a == "--min-docs":
            v = val(a)
            if not re.fullmatch(r"[0-9]+", v):
                usage("--min-docs must be a non-negative integer")
            opts["min_docs"] = int(v)
        elif a == "--names":
            if i + 2 >= len(argv):
                usage("--names needs two files")
            opts["names"] = (argv[i + 1], argv[i + 2])
            i += 2
        elif a == "--expect-names-added":
            opts["expect_names"] = sorted(x for x in val(a).split(",") if x)
        elif a == "--expect":
            usage("--expect MODE was removed with the window modes (pin, pin11696, flip, flip11696, hbaonly): use --expect-rows FILE")
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        elif a.startswith("--"):
            usage("unknown option %s" % a)
        else:
            pos.append(a)
        i += 1
    if len(pos) != 2:
        usage("give exactly two render files")
    if "--rc-a" not in rcs or "--rc-b" not in rcs:
        usage("--rc-a and --rc-b are required (the helm return code of each render)")
    modes = [opts["expect_added"] is not None, opts["expect_rows"] is not None, opts["info"]]
    if modes.count(True) != 1:
        usage("give exactly one of --expect-added, --expect-rows, --info")
    if opts["expect_names"] is not None and opts["names"] is None:
        usage("--expect-names-added needs --names NA NB (in every mode)")
    if opts["names"] is not None and opts["expect_names"] is None and not opts["info"]:
        usage("--names needs --expect-names-added (only --info may print the names sets alone)")
    return pos, rcs["--rc-a"], rcs["--rc-b"], opts


def read_names(path):
    try:
        with open(path) as f:
            return set(line.strip() for line in f if line.strip())
    except OSError as exc:
        usage("cannot read %s: %s" % (path, exc.strerror))


def main(argv):
    if argv == ["filter"]:
        yaml.safe_dump_all([redact(d) for d in docs_of(sys.stdin) if d["kind"] != "Secret"], sys.stdout, sort_keys=True)
        return 0
    if argv == ["names"]:
        for n in sorted(key(d) for d in docs_of(sys.stdin)):
            print(n)
        return 0
    (pa, pb), rc_a, rc_b, opts = parse_args(argv)
    sa, sb = Side("A", pa, rc_a), Side("B", pb, rc_b)
    for s in (sa, sb):
        shown = s.live_count if opts["live"] else s.count
        print("render %s: helm rc=%d docs=%d" % (s.label, s.rc, shown))
    names = None
    if opts["names"] is not None:
        names = (read_names(opts["names"][0]), read_names(opts["names"][1]))
    reasons = []
    for s in (sa, sb):
        shown = s.live_count if opts["live"] else s.count
        if s.error:
            reasons.append(s.error)
        if s.rc != 0:
            reasons.append("render %s: helm rc=%d" % (s.label, s.rc))
        if shown < opts["min_docs"]:
            reasons.append("render %s: docs=%d below --min-docs %d" % (s.label, shown, opts["min_docs"]))
    if names is not None:
        for label, n in (("A", names[0]), ("B", names[1])):
            if not n:
                reasons.append("names %s is empty" % label)
    final = "GATE %s" % os.path.basename(opts["expect_rows"]) if opts["expect_rows"] is not None else "FULL RENDER DIFF"
    bad_word = "HOLD" if opts["expect_rows"] is not None else "STOP"
    if reasons:
        print("%s: %s (render floor: %s)" % (final, bad_word, "; ".join(reasons)))
        return 1

    a, b = sa.docs, sb.docs
    dup_lines = duplicate_lines(a, b)
    if dup_lines:
        return stop_duplicates(final, bad_word, dup_lines)
    added, removed, rows = [], [], []
    for k in sorted(set(a) | set(b)):
        if k not in a:
            added.append(k)
            print("%s ADDED" % k)
            continue
        if k not in b:
            removed.append(k)
            print("%s REMOVED" % k)
            continue
        d = Diff(k)
        d.walk(a[k], b[k], "")
        for path, verb, old, new, before, after in d.rows:
            rows.append((k, path, verb, old, new, before, after))
            if verb == "REORDERED":
                print("%s %s REORDERED old=[%s] new=[%s]" % (k, path, ",".join(old), ",".join(new)))
            else:
                print("%s %s %s" % (k, path, verb))
    changed = [r for r in rows if r[2] == "CHANGED"]
    el_add = [r for r in rows if r[2] == "ELEMENT-ADDED"]
    el_rm = [r for r in rows if r[2] == "ELEMENT-REMOVED"]
    reord = [r for r in rows if r[2] == "REORDERED"]
    podmeta = [r for r in rows if ".template.metadata." in r[1]]
    sts = [r for r in rows if r[0] == POSTGRES_STS]
    kinds = {}
    for k in a:
        kinds[k.split("/")[0]] = kinds.get(k.split("/")[0], 0) + 1
    context = "hook-free: a live manifest" if opts["live"] else "hook-included: a helm template render"
    print("docs A %d B %d (all kinds, Secrets as Kind/name only; %s); kinds in A: %s" % (
        len(a), len(b), context, ", ".join("%s=%d" % kv for kv in sorted(kinds.items()))))
    print("added %s; removed %s; changed field rows %d; element rows added %d removed %d; reordered rows %d; pod-template label/annotation rows %d; postgres sts rows %d" % (
        added, removed, len(changed), len(el_add), len(el_rm), len(reord), len(podmeta), len(sts)))
    if opts["live"]:
        print("docs (non-Secret) A %d B %d; added %d removed %d changed fields %d" % (
            sa.live_count, sb.live_count, len([x for x in added if not x.startswith("Secret/")]),
            len([x for x in removed if not x.startswith("Secret/")]), len(changed)))
    names_ok = True
    if names is not None:
        plus, minus = sorted(names[1] - names[0]), sorted(names[0] - names[1])
        print("names: A %d B %d; added %s; removed %s" % (len(names[0]), len(names[1]), plus, minus))
        if opts["expect_names"] is not None:
            names_ok = plus == opts["expect_names"] and not minus
    if opts["info"]:
        print("%s: INFO (no expectation; the floor held)" % final)
        return 0 if names_ok else 1
    if opts["expect_added"] is not None:
        ok = sorted(added) == opts["expect_added"] and not removed and not rows and names_ok
        print("%s: %s (expected added %s)" % (final, "PASS" if ok else "STOP", opts["expect_added"]))
        return 0 if ok else 1
    return rows_gate(opts["expect_rows"], final, added, removed, rows, names_ok)


def rows_gate(path, final, added, removed, rows, names_ok):
    try:
        with open(path) as f:
            want = json.load(f)
    except (OSError, ValueError) as exc:
        usage("cannot read the rows file %s: %s" % (path, exc))
    ok = names_ok
    if sorted(want.get("added", [])) != sorted(added) or sorted(want.get("removed", [])) != sorted(removed):
        print("docs added/removed differ from the rows file: added %s removed %s; file added %s removed %s" % (
            added, removed, sorted(want.get("added", [])), sorted(want.get("removed", []))))
        ok = False

    def sig(doc, p, verb, old, new):
        return (doc, p, verb, tuple(old) if old is not None else None, tuple(new) if new is not None else None)

    observed = {sig(r[0], r[1], r[2], r[3], r[4]): r for r in rows}
    expected = {}
    for e in want.get("rows", []):
        expected[sig(e["doc"], e["path"], e["verb"], e.get("old"), e.get("new"))] = e
    for s in sorted(set(observed) - set(expected), key=str):
        print("unexpected row %s %s %s" % (s[0], s[1], s[2]))
        ok = False
    for s in sorted(set(expected) - set(observed), key=str):
        print("missing row %s %s %s" % (s[0], s[1], s[2]))
        ok = False
    for s in sorted(set(expected) & set(observed), key=str):
        e, r = expected[s], observed[s]
        before, after = r[5], r[6]
        for field, got in (("before", before), ("after", after)):
            if field in e:
                same = got is not _NONE and str(got) == str(e[field])
                if not same:
                    print("value-check FAIL %s %s (%s)" % (s[0], s[1], field))
                    ok = False
        if (("before" in e) or ("after" in e)) and ok:
            print("value-check ok %s %s" % (s[0], s[1]))
        if e.get("show"):
            print("value %s %s %s -> %s" % (s[0], s[1], "<none>" if before is _NONE else before, "<none>" if after is _NONE else after))
    print("%s: %s" % (final, "PASS" if ok else "HOLD"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

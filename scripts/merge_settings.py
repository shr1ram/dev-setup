#!/usr/bin/env python3
"""Merge the repo's Claude Code settings into the live settings file without losing anything else in it.

Other tools write to ~/.claude/settings.json too (Orca adds its agent hooks), and some settings are set by
hand. Copying the repo file over the live one would wipe them, so this does a three-way merge:

  repo   configs/claude_settings.json: the source of truth for the keys and list entries it contains
  live   ~/.claude/settings.json
  base   what this script installed last time, plus (--past) every earlier version of the repo file, so
         entries the repo has since dropped can be told apart from ones added by hand

Rules, applied recursively:
  - a key in repo:                objects merge recursively; lists merge (below); anything else takes repo's value
  - a key only in base/past:      the repo dropped it. Objects and lists lose the repo's old entries and keep
                                  any added by hand; anything else is removed unless it was changed by hand
  - a key only in live:           kept
  - lists (hooks, permissions):   repo's entries first, then live entries that no base/past version has
                                  (added by hand or by another tool); entries the repo dropped are removed

Usage: merge_settings.py <repo.json> <live.json> <base.json> [--past <old-repo.json>]... [--dry-run]
Exit codes: 0 = written (or nothing to change), 10 = --dry-run and something would change, 2 = error.
"""

import json
import os
import sys
import tempfile


def plural(n):
    return f"{n} entr{'y' if n == 1 else 'ies'}"


def merge(live, bases, repo, path, changes):
    out = {}
    for key in list(live) + [k for k in repo if k not in live]:
        p = f"{path}.{key}" if path else key
        l = live.get(key)
        olds = [b[key] for b in bases if key in b]
        if key in repo:
            r = repo[key]
            if isinstance(r, dict) and isinstance(l, dict):
                out[key] = merge(l, [o for o in olds if isinstance(o, dict)], r, p, changes)
            elif isinstance(r, list) and isinstance(l, list):
                out[key] = merge_list(l, [o for o in olds if isinstance(o, list)], r, p, changes)
            else:
                out[key] = r
                if key not in live:
                    changes.append(f"+ {p}")
                elif l != r:
                    changes.append(f"~ {p}")
        elif olds:
            # The repo dropped this key. Remove what the repo put there; keep what was added by hand.
            inner = []
            if isinstance(l, dict) and any(isinstance(o, dict) for o in olds):
                v = merge(l, [o for o in olds if isinstance(o, dict)], {}, p, inner)
            elif isinstance(l, list) and any(isinstance(o, list) for o in olds):
                v = merge_list(l, [o for o in olds if isinstance(o, list)], [], p, inner)
            else:
                v = None if l in olds else l
            if v in (None, {}, []):
                changes.append(f"- {p} (dropped from the repo)")
            else:
                out[key] = v
                changes.extend(inner)
        else:
            out[key] = l
    return out


def merge_list(live, bases, repo, path, changes):
    seen = [x for b in bases for x in b]
    kept = [x for x in live if x not in seen and x not in repo]
    out = list(repo) + kept
    added = [x for x in repo if x not in live]
    removed = [x for x in live if x in seen and x not in repo]
    if added:
        note = ""
        if kept:
            note = (f" (also keeping {plural(len(kept))} not from the repo; if one is an edited copy of a repo"
                    f" entry, both now apply)")
        changes.append(f"+ {path}: {plural(len(added))} from the repo{note}")
    if removed:
        changes.append(f"- {path}: {plural(len(removed))} dropped from the repo")
    if not added and not removed and out != live:
        changes.append(f"~ {path}: reordered (repo entries first)")
    return out


class BadFile(Exception):
    pass


def load(path, missing_ok=False):
    if missing_ok and not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        data = json.loads(text) if text.strip() else {}
    except (OSError, ValueError) as e:
        raise BadFile(f"{path}: {e}") from e
    if not isinstance(data, dict):
        raise BadFile(f"{path}: expected a JSON object, found {type(data).__name__}")
    return data


def write_atomic(path, data):
    path = os.path.realpath(path)  # write through a symlink, don't replace it
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv):
    dry, pasts, args = False, [], []
    it = iter(argv)
    for a in it:
        if a == "--dry-run":
            dry = True
        elif a == "--past":
            pasts.append(next(it, ""))
        else:
            args.append(a)
    if len(args) != 3 or any(a.startswith("-") or not a for a in args + pasts):
        print(__doc__, file=sys.stderr)
        return 2
    repo_path, live_path, base_path = args
    try:
        repo = load(repo_path)
        live = load(live_path, missing_ok=True)
    except BadFile as e:
        print(f"Can't read settings: {e}", file=sys.stderr)
        return 2
    bases = []
    for p in [base_path] + pasts:
        try:
            bases.append(load(p, missing_ok=True))
        except BadFile as e:
            # Only our own bookkeeping: ignore it rather than block every future run.
            print(f"  (ignoring unreadable {e})", file=sys.stderr)
            bases.append(None)
    base, bases = bases[0], [b for b in bases if b is not None]

    changes = []
    merged = merge(live, bases, repo, "", changes)
    for c in changes:
        print(f"  {c}")
    if dry:
        return 10 if merged != live else 0
    try:
        if merged != live:
            write_atomic(live_path, merged)
        if base != repo:
            write_atomic(base_path, repo)
    except OSError as e:
        print(f"Can't write settings: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

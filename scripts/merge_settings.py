#!/usr/bin/env python3
"""Merge the repo's Claude Code settings into the live settings file without losing anything else in it.

Other tools write to ~/.claude/settings.json too (Orca adds its agent hooks), and some settings are set by
hand. Copying the repo file over the live one would wipe them, so this does a three-way merge:

  repo   configs/claude_settings.json: the source of truth for the keys and list entries it contains
  live   ~/.claude/settings.json
  base   what this script installed last time, so entries the repo has since dropped can be removed

Rules, applied recursively:
  - a key in repo:                objects merge recursively; lists merge (below); anything else takes repo's value
  - a key only in base:           the repo dropped it; removed, unless the live value was changed since
  - a key only in live:           kept
  - lists (hooks, permissions):   repo's entries first, then live entries that neither repo nor base has
                                  (added by hand or by another tool); entries the repo dropped are removed

Usage: merge_settings.py <repo.json> <live.json> <base.json> [--dry-run]
Exit codes: 0 = written (or nothing to change), 10 = --dry-run and something would change, 2 = error.
"""

import json
import os
import sys
import tempfile


def merge(live, base, repo, path, changes):
    out = {}
    for key in list(live) + [k for k in repo if k not in live]:
        p = f"{path}.{key}" if path else key
        if key in repo:
            r, l, b = repo[key], live.get(key), base.get(key)
            if isinstance(r, dict) and isinstance(l, dict):
                out[key] = merge(l, b if isinstance(b, dict) else {}, r, p, changes)
            elif isinstance(r, list) and isinstance(l, list):
                out[key] = merge_list(l, b if isinstance(b, list) else [], r, p, changes)
            else:
                out[key] = r
                if key not in live:
                    changes.append(f"+ {p}")
                elif l != r:
                    changes.append(f"~ {p}")
        elif key in base:
            if live[key] == base[key]:
                changes.append(f"- {p} (dropped from the repo)")
            else:
                out[key] = live[key]  # changed by hand since it was installed: keep it
        else:
            out[key] = live[key]
    return out


def merge_list(live, base, repo, path, changes):
    kept = [x for x in live if x not in base and x not in repo]
    out = list(repo) + kept
    added = [x for x in repo if x not in live]
    removed = [x for x in live if x in base and x not in repo]
    if added:
        changes.append(f"+ {path}: {len(added)} entr{'y' if len(added) == 1 else 'ies'} from the repo")
    if removed:
        changes.append(f"- {path}: {len(removed)} entr{'y' if len(removed) == 1 else 'ies'} dropped from the repo")
    if not added and not removed and out != live:
        changes.append(f"~ {path}: reordered (repo entries first)")
    return out


def load(path, missing_ok):
    if missing_ok and not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def write_atomic(path, data):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)


def main(argv):
    dry = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    if len(args) != 3 or any(a.startswith("-") for a in args):
        print(__doc__, file=sys.stderr)
        return 2
    repo_path, live_path, base_path = args
    try:
        repo = load(repo_path, False)
        live = load(live_path, True)
        base = load(base_path, True)
    except (OSError, ValueError) as e:
        print(f"Can't read settings: {e}", file=sys.stderr)
        return 2

    changes = []
    merged = merge(live, base, repo, "", changes)
    for c in changes:
        print(f"  {c}")
    if dry:
        return 10 if merged != live else 0
    if merged != live:
        write_atomic(live_path, merged)
    if base != repo:
        write_atomic(base_path, repo)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

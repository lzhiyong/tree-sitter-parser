#!/usr/bin/env python3
"""
Keep filetypes.json in step with parsers.json:
    - languages that are NEW in parsers.json get their extensions / file names added
    - languages that were REMOVED from parsers.json lose their entry

Where the data comes from:
    GitHub Linguist's languages.yml (https://github.com/github-linguist/linguist), which lists
    "extensions" (".adb") and "filenames" ("Dockerfile") for every language. A parser is matched
    to a Linguist language by name or alias, ignoring case and punctuation
    (c_sharp ~ "C#", cpp ~ "C++", fsharp ~ "F#").

Rules:
    - Only languages that differ between the two parsers.json files are touched
      (--old-parsers is the previous version, e.g. from `git show HEAD:grammar/parsers.json`).
    - Removed languages: the entry "tree_sitter_<name>" is deleted. Entries of languages that
      were never in the old parsers.json (for example ones you added by hand) are left alone.
    - Existing entries of languages that stay in parsers.json are never modified.
    - A language without any extension or file name (nothing matched in Linguist, or everything
      it lists is already taken) is NOT added, so filetypes.json never gets empty lists.
    - An extension or file name that already belongs to another language is skipped, so
      the first owner keeps it (for example ".h" stays where it is).
    - Keys are "tree_sitter_<name>"; the file is written sorted, one entry per line.

Example:
    python3 scripts/update_filetypes.py --parsers grammar/parsers.json --old-parsers old_parsers.json \\
        --filetypes config/filetypes.json --linguist languages.yml
"""

import argparse
import json
import re
import sys

import yaml  # PyYAML (apt: python3-yaml)

KEY_PREFIX = "tree_sitter_"


def norm(name: str) -> str:
    """Comparable form of a language name: 'C#' -> 'csharp', 'C++' -> 'cpp', 'c_sharp' -> 'csharp'."""
    s = name.lower().replace("#", "sharp").replace("+", "p")
    return re.sub(r"[^a-z0-9]", "", s)


def load_names(path: str):
    """Language names in a parsers.json; a missing file means 'no languages'."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return []
    names = []
    for entry in data:
        n = entry["name"]
        names.extend(n if isinstance(n, list) else [n])
    return names


def load_filetypes(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def build_linguist_index(path: str):
    """norm(name or alias) -> Linguist entry. Real names win over aliases."""
    with open(path, encoding="utf-8") as f:
        languages = yaml.safe_load(f)
    index = {}
    for name, props in languages.items():
        index.setdefault(norm(name), props or {})
    for name, props in languages.items():
        for alias in (props or {}).get("aliases", []):
            index.setdefault(norm(alias), props or {})
    return index


def write_filetypes(path: str, data: dict):
    """Same layout as before: sorted keys, one entry per line."""
    keys = sorted(data)
    lines = ["{"]
    for i, k in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        lines.append(f"  {json.dumps(k)}: {json.dumps(data[k], ensure_ascii=False)}{comma}")
    lines.append("}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description="Add / remove file types in filetypes.json to match parsers.json")
    ap.add_argument("--parsers", default="grammar/parsers.json", help="current parsers.json")
    ap.add_argument("--old-parsers", required=True, help="previous parsers.json (missing file = all languages are new)")
    ap.add_argument("--filetypes", default="config/filetypes.json", help="filetypes.json to update in place")
    ap.add_argument("--linguist", required=True, help="path to Linguist's languages.yml")
    args = ap.parse_args()

    current = set(load_names(args.parsers))
    previous = set(load_names(args.old_parsers))
    new_langs = sorted(current - previous)
    removed_langs = sorted(previous - current)
    if not new_langs and not removed_langs:
        print("parsers.json has no added or removed languages, nothing to do")
        return

    filetypes = load_filetypes(args.filetypes)

    # Removed languages: drop their entry. Only languages that were in the old parsers.json are
    # considered, so hand-written entries for languages outside parsers.json stay untouched.
    removed = 0
    for name in removed_langs:
        key = KEY_PREFIX + name
        if key in filetypes:
            del filetypes[key]
            removed += 1
            print(f"[del]  {key}")
        else:
            print(f"[none] {key} was not in filetypes.json")

    index = build_linguist_index(args.linguist)

    # Everything that is already taken: extension / file name -> owning key
    owner = {}
    for key, values in filetypes.items():
        for v in values:
            owner.setdefault(v, key)

    added = 0
    for name in new_langs:
        key = KEY_PREFIX + name
        if key in filetypes:
            print(f"[keep] {key} already exists")
            continue

        entry = index.get(norm(name))
        if entry is None:
            print(f"[skip] {name}: no matching language in Linguist")
            continue

        values = []
        for v in list(entry.get("extensions", [])) + list(entry.get("filenames", [])):
            if v in values:
                continue
            if v in owner:
                print(f"[skip] {name}: '{v}' already belongs to {owner[v]}")
                continue
            values.append(v)

        if not values:
            print(f"[skip] {name}: no extensions or file names left")
            continue

        filetypes[key] = values
        for v in values:
            owner[v] = key
        added += 1
        print(f"[add]  {key}: {values}")

    if added or removed:
        write_filetypes(args.filetypes, filetypes)
    print(f"Done: {added} language(s) added of {len(new_langs)} new, "
          f"{removed} removed of {len(removed_langs)} dropped from parsers.json")


if __name__ == "__main__":
    sys.exit(main())

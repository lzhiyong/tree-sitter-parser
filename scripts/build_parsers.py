#!/usr/bin/env python3
"""
Batch download and build tree-sitter parsers listed in parsers.json.

Input format (as produced by the sync-parsers workflow): a flat list with one entry per language.
Several languages may point at the same repository, e.g. typescript and tsx:

    [
      {"name": "typescript", "revision": "75b3874e...", "url": "https://github.com/tree-sitter/tree-sitter-typescript"},
      {"name": "tsx",        "revision": "75b3874e...", "url": "https://github.com/tree-sitter/tree-sitter-typescript"}
    ]

(A "name" given as a list of languages is still accepted.)

How it works:
    1. Entries are grouped by (url, revision), so each repository is cloned exactly once.
    2. For every language in a group, the matching grammar directory is located inside the repo
       (multi-language repos keep one sub-directory per language; single-language repos use the root).
    3. If the repo does not ship a pre-generated src/parser.c, it is generated with the
       tree-sitter CLI (see "Generation" below).
    4. src/parser.c (+ src/scanner.c / scanner.cc) is compiled into a shared library.
    5. The output is tree_sitter_<name>.so (e.g. tree_sitter_c.so) in the output directory.

Generation (only for grammars without src/parser.c):
    - src/grammar.json present -> `tree-sitter generate src/grammar.json` (no Node.js needed)
    - otherwise grammar.js     -> `npm install --ignore-scripts` (for grammars that require other
                                  grammars, e.g. cpp -> c) and then `tree-sitter generate`
    Requires the `tree-sitter` CLI on PATH (or --tree-sitter), plus node/npm for the grammar.js case.
    Disable with --no-generate.

Examples:
    # Build on the host machine (Termux / Linux)
    python3 scripts/build_parsers.py --json grammar/parsers.json --cache ./ts-cache --output ./libs

    # Build only some languages
    python3 build_parsers.py --only python,lua,typescript,tsx

    # Cross-compile for Android with the NDK clang
    python3 scripts/build_parsers.py \\
        --cc  /path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang \\
        --cxx /path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang++ \\
        --output /path/to/libs-arm64
"""

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path

# Keeps terminal output from interleaving when several threads log at once
PRINT_LOCK = threading.Lock()

# Results collected across threads (list.append is thread-safe in CPython)
SUCCEEDED = []
FAILED = []


def log(msg: str):
    with PRINT_LOCK:
        print(msg, flush=True)


def run(cmd, cwd=None):
    log(f"$ {' '.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, check=True)


def group_entries(entries):
    """
    Merge entries that share the same (url, revision) so that each repository is cloned once.
    Returns a list of (url, revision, [language names]).
    Without this, two languages from one repo (typescript/tsx) would race to clone the same directory.
    """
    groups = {}
    for entry in entries:
        names = entry["name"] if isinstance(entry["name"], list) else [entry["name"]]
        groups.setdefault((entry["url"], entry["revision"]), []).extend(names)
    return [(url, rev, names) for (url, rev), names in groups.items()]


def repo_cache_dir(cache_dir: Path, url: str, revision: str) -> Path:
    """
    Cache directory name = <owner>__<repo>__<short revision>.
    Including the revision means a bumped revision in parsers.json gets a fresh clone
    instead of silently reusing a stale checkout; including the owner avoids clashes
    between same-named repos from different users.
    """
    parts = url.rstrip("/").removesuffix(".git").split("/")
    owner, repo = parts[-2], parts[-1]
    return cache_dir / f"{owner}__{repo}__{revision[:8]}"


def clone_repo(url: str, revision: str, dest: Path):
    """Shallow-fetch the exact revision into dest; skipped if dest already exists."""
    if dest.exists():
        log(f"[skip clone] {dest} already exists")
        return

    dest.parent.mkdir(parents=True, exist_ok=True)

    # Work in a temporary directory and rename at the end, so an interrupted clone
    # never leaves a half-populated directory that would be mistaken for a valid cache
    tmp = dest.parent / (dest.name + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)

    run(["git", "init", "-q", "--initial-branch=main", str(tmp)])
    run(["git", "-C", str(tmp), "remote", "add", "origin", url])
    try:
        # Preferred: shallow fetch of the pinned commit (needs server-side support, GitHub has it)
        run(["git", "-C", str(tmp), "fetch", "--depth", "1", "origin", revision])
        run(["git", "-C", str(tmp), "checkout", "FETCH_HEAD"])
    except subprocess.CalledProcessError:
        log(f"[warn] shallow fetch of {revision} from {url} failed, falling back to a full fetch")
        run(["git", "-C", str(tmp), "fetch", "origin"])
        run(["git", "-C", str(tmp), "checkout", revision])

    tmp.rename(dest)


def normalize(name: str) -> str:
    """Make directory names and language names comparable: 'tree-sitter-c-sharp' ~ 'c_sharp'."""
    n = name.lower()
    if n.startswith("tree-sitter-"):
        n = n[len("tree-sitter-"):]
    return n.replace("-", "_")


def list_grammar_dirs(repo_dir: Path):
    """
    Every directory in the repo that looks like a grammar: it has a pre-generated src/parser.c,
    or the sources to generate one (src/grammar.json or grammar.js).
    node_modules and hidden directories are ignored.
    """
    found = set()
    for pattern, depth in (("src/parser.c", 2), ("src/grammar.json", 2), ("grammar.js", 1)):
        for p in repo_dir.rglob(pattern):
            rel = p.relative_to(repo_dir).parts
            if "node_modules" in rel or any(part.startswith(".") for part in rel):
                continue
            found.add(p.parents[depth - 1])  # depth 2 -> grandparent of the file, depth 1 -> parent
    return sorted(found)


def find_grammar_dir(repo_dir: Path, name: str) -> Path:
    """
    Locate the grammar directory for a language. The JSON carries no sub-directory information,
    so the lookup order is:
      1. <repo>/<name>                              (typescript/, tsx/, ...)
      2. any sub-directory whose normalized name equals the language name
         (e.g. tree-sitter-markdown-inline/ for markdown_inline), searched recursively
      3. the repository root                        (single-language repos)
      4. the only grammar in the repo, if there is exactly one
    """
    grammar_dirs = list_grammar_dirs(repo_dir)

    exact = repo_dir / name
    if exact in grammar_dirs:
        return exact

    target = normalize(name)
    for d in grammar_dirs:
        if d != repo_dir and normalize(d.name) == target:
            return d

    if repo_dir in grammar_dirs:
        return repo_dir

    if len(grammar_dirs) == 1:
        return grammar_dirs[0]

    raise FileNotFoundError(
        f"no grammar matching '{name}' in {repo_dir} "
        f"(it may live in a sub-directory that parsers.json does not record)"
    )


def install_js_deps(grammar_dir: Path, repo_dir: Path):
    """
    Some grammar.js files require other grammars or helper packages
    (e.g. cpp requires tree-sitter-c, typescript requires tree-sitter-javascript).
    Run `npm install` in the nearest directory with a package.json, once per checkout.
    --ignore-scripts skips native builds / CLI binary downloads, which are not needed here.
    Failures are only warnings: `tree-sitter generate` reports the real error if a require fails.
    """
    d = grammar_dir
    while not (d / "package.json").exists():
        if d == repo_dir:
            return  # No package.json anywhere: nothing to install
        d = d.parent

    if (d / "node_modules").exists():
        return  # Already installed (e.g. by an earlier language from the same repo)
    if shutil.which("npm") is None:
        log(f"[warn] npm not found, skipping dependency install in {d}")
        return
    try:
        run(["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=d)
    except subprocess.CalledProcessError as e:
        log(f"[warn] npm install failed in {d}: {e}")


def ensure_parser_source(grammar_dir: Path, repo_dir: Path, ts_cli: str,
                         allow_generate: bool, abi):
    """Make sure src/parser.c exists, generating it with the tree-sitter CLI when it is missing."""
    if (grammar_dir / "src" / "parser.c").exists():
        return  # Pre-generated parser shipped in the repo: nothing to do

    if not allow_generate:
        raise FileNotFoundError(f"{grammar_dir}/src/parser.c is missing and --no-generate is set")
    resolved = shutil.which(ts_cli)
    if resolved is None:
        raise RuntimeError(f"src/parser.c is missing and the tree-sitter CLI ('{ts_cli}') was not found")
    # Make the path absolute: the CLI is run with cwd=grammar_dir, so a relative path would break
    ts_cli = os.path.abspath(resolved)

    abi_args = ["--abi", str(abi)] if abi else []
    grammar_json = grammar_dir / "src" / "grammar.json"
    grammar_js = grammar_dir / "grammar.js"

    if grammar_json.exists():
        # Preferred path: the JSON grammar is already evaluated, so Node.js is not needed
        run([ts_cli, "generate"] + abi_args + ["src/grammar.json"], cwd=grammar_dir)
    elif grammar_js.exists():
        if shutil.which("node") is None:
            raise RuntimeError("generating from grammar.js requires Node.js, which was not found")
        install_js_deps(grammar_dir, repo_dir)
        run([ts_cli, "generate"] + abi_args, cwd=grammar_dir)
    else:
        raise FileNotFoundError(f"no parser.c, grammar.json or grammar.js in {grammar_dir}")

    if not (grammar_dir / "src" / "parser.c").exists():
        raise RuntimeError(f"tree-sitter generate did not produce {grammar_dir}/src/parser.c")


def compile_parser(grammar_dir: Path, name: str, output_dir: Path,
                   cc: str, cxx: str, extra_cflags):
    """Compile parser.c and an optional scanner (C or C++) into tree_sitter_<name>.so."""
    src_dir = grammar_dir / "src"
    parser_c = src_dir / "parser.c"
    scanner_c = src_dir / "scanner.c"
    scanner_cc = src_dir / "scanner.cc"

    output_dir.mkdir(parents=True, exist_ok=True)
    # Library name uses underscores only (tree_sitter_c.so, tree_sitter_c_sharp.so)
    out_so = output_dir / f"tree_sitter_{name.replace('-', '_')}.so"

    # Per-language build directory: languages sharing a repo are built in sequence,
    # and the unique name keeps their object files apart
    build_dir = grammar_dir / f"build_tmp_{name}"
    build_dir.mkdir(exist_ok=True)

    def compile_obj(compiler, src: Path, obj: Path):
        run([compiler, "-fPIC", "-O2", "-c", str(src),
             "-I", str(src_dir), "-o", str(obj)] + extra_cflags)

    try:
        objects = []
        parser_o = build_dir / "parser.o"
        compile_obj(cc, parser_c, parser_o)
        objects.append(parser_o)

        # A C++ scanner forces the final link to use the C++ driver (pulls in libc++/libstdc++)
        linker = cc
        if scanner_cc.exists():
            scanner_o = build_dir / "scanner.o"
            compile_obj(cxx, scanner_cc, scanner_o)
            objects.append(scanner_o)
            linker = cxx
        elif scanner_c.exists():
            scanner_o = build_dir / "scanner.o"
            compile_obj(cc, scanner_c, scanner_o)
            objects.append(scanner_o)

        # Extra cflags (e.g. --target=...) are needed at link time too when cross-compiling
        run([linker, "-shared", "-o", str(out_so)] + [str(o) for o in objects] + extra_cflags)
    finally:
        shutil.rmtree(build_dir, ignore_errors=True)  # Clean up even if compilation failed
    return out_so


def process_group(url: str, revision: str, names, args, extra_cflags, only):
    """Clone one repository (once) and build every requested language that lives in it."""
    if only:
        names = [n for n in names if n in only]
    if not names:
        return

    repo_dir = repo_cache_dir(Path(args.cache), url, revision)

    if not args.skip_clone:
        try:
            clone_repo(url, revision, repo_dir)
        except subprocess.CalledProcessError as e:
            log(f"[ERROR] clone {url} failed: {e}")
            FAILED.extend(names)
            return
    elif not repo_dir.exists():
        log(f"[ERROR] {repo_dir} does not exist (--skip-clone is set)")
        FAILED.extend(names)
        return

    for name in names:
        try:
            grammar_dir = find_grammar_dir(repo_dir, name)
            ensure_parser_source(grammar_dir, repo_dir, args.tree_sitter,
                                 not args.no_generate, args.abi)
            out_so = compile_parser(grammar_dir, name, Path(args.output),
                                    args.cc, args.cxx, extra_cflags)
            log(f"[OK] {name} -> {out_so}")
            SUCCEEDED.append(name)
        except Exception as e:
            log(f"[ERROR] building {name} failed: {e}")
            FAILED.append(name)


def main():
    parser = argparse.ArgumentParser(description="Download and build tree-sitter parsers in bulk")
    parser.add_argument("--json", default="grammar/parsers.json", help="path to parsers.json")
    parser.add_argument("--cache", default="./cache", help="directory for cloned repositories")
    parser.add_argument("--output", default="./libs", help="output directory for .so files")
    parser.add_argument("--only", help="comma-separated language names to build, e.g. python,lua,typescript,tsx")
    parser.add_argument("--jobs", type=int, default=4, help="number of worker threads")
    parser.add_argument("--cc", default="clang", help="C compiler (pass an NDK clang to cross-compile)")
    parser.add_argument("--cxx", default="clang++", help="C++ compiler (for grammars with scanner.cc)")
    parser.add_argument("--cflags", default="",
                        help='extra compiler flags, space separated, e.g. "--target=aarch64-linux-android24"')
    parser.add_argument("--tree-sitter", default="tree-sitter",
                        help="tree-sitter CLI used to generate missing parser.c files")
    parser.add_argument("--no-generate", action="store_true",
                        help="do not generate missing parser.c files (such languages will fail)")
    parser.add_argument("--abi", type=int,
                        help="language ABI version passed to `tree-sitter generate --abi`; "
                             "set it to what your bundled tree-sitter runtime supports")
    parser.add_argument("--skip-clone", action="store_true",
                        help="do not clone, rebuild from the existing cache directory only")
    parser.add_argument("--strict", action="store_true",
                        help="exit with status 1 if any language failed (useful in CI)")
    args = parser.parse_args()

    with open(args.json, encoding="utf-8") as f:
        entries = json.load(f)

    only = set(args.only.split(",")) if args.only else None
    extra_cflags = args.cflags.split() if args.cflags else []

    # One task per repository; languages inside a repository are built sequentially
    groups = group_entries(entries)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [
            pool.submit(process_group, url, rev, names, args, extra_cflags, only)
            for url, rev, names in groups
        ]
        for fut in concurrent.futures.as_completed(futures):
            fut.result()  # Re-raise unexpected exceptions from worker threads

    log(f"Done: {len(SUCCEEDED)} succeeded, {len(FAILED)} failed")
    if FAILED:
        log("Failed: " + ", ".join(sorted(FAILED)))
        if args.strict:
            sys.exit(1)


if __name__ == "__main__":
    main()

# tree-sitter-parsers

Prebuilt [tree-sitter](https://tree-sitter.github.io/tree-sitter/) parsers for Android, together with the
highlight queries, file type mappings and themes that go with them. They are made for the
xedit-app Android text editor. The language list, pinned revisions and queries are
kept in sync with [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter), and everything is built
and published automatically by GitHub Actions.

## Downloads

Everything is published on one release, **`android-tree-sitter`**. Its assets are overwritten in place on each
update, so the download links stay stable.

| Asset | Contents |
| --- | --- |
| `tree-sitter-languages-aarch64.zip` | Parsers for `arm64-v8a` |
| `tree-sitter-languages-arm.zip` | Parsers for `armeabi-v7a` |
| `tree-sitter-languages-i686.zip` | Parsers for `x86` |
| `tree-sitter-languages-x86_64.zip` | Parsers for `x86_64` |
| `tree-sitter-queries.zip` | The `queries/` directory |
| `tree-sitter-configs.zip` | `config/` and the `themes/` directory |

Each parser zip contains one shared library per language, named `tree_sitter_<language>.so`
(for example `tree_sitter_python.so`, `tree_sitter_c_sharp.so`). The libraries are built with the latest stable
Android NDK for API level 24 and stripped. A few grammars may fail to build; the build log of the
*Build tree-sitter parsers* workflow lists them.

## Repository layout

| Path | Description |
| --- | --- |
| `grammar/parsers.json` | Languages to build: `name`, pinned `revision` and upstream `url`. Generated, do not edit by hand |
| `queries/` | Highlight and other queries, mirrored from nvim-treesitter. Generated, do not edit by hand |
| `config/filetypes.json` | Maps each library (`tree_sitter_<language>`) to file extensions and file names |
| `themes/` | Color themes exported from Neovim |
| `scripts/build_parsers.py` | Clones the grammars and compiles them into shared libraries |
| `scripts/update_filetypes.py` | Adds and removes `filetypes.json` entries when `parsers.json` gains or loses languages |
| `scripts/nvim_export_captures.lua` | Exports a Neovim colorscheme to a theme file |
| `scripts/nvim_export_keymaps.lua` | Writes the editor's basic key bindings to `keymaps.json` |
| `.github/workflows/` | The workflows described below |

## Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `sync-parsers.yml` | Every Monday 03:00 UTC, or manually | Converts nvim-treesitter's `parsers.lua` into `grammar/parsers.json` and mirrors `runtime/queries` into `queries/`. New languages are added to `config/filetypes.json` and removed ones are deleted. Commits only when something really changed, uploads `tree-sitter-queries.zip` when the queries changed, and starts the build / configs workflows when their inputs changed |
| `build-parsers.yml` | `grammar/parsers.json` or `scripts/build_parsers.py` changes, or manually | Builds every parser for each Android architecture and uploads the four `tree-sitter-languages-*.zip` files |
| `publish-configs.yml` | `config/filetypes.json` or `themes/` changes, or manually | Packs both into `tree-sitter-configs.zip` and uploads it |
| `cleanup-runs.yml` | 1st of every month 03:20 UTC, or manually | Deletes finished workflow run records. The manual run can keep recent runs (`keep_days`) or only list what would be deleted (`dry_run`) |

The release and its tag are created once. Later runs only overwrite the assets, and the release notes always show
the latest commit.

## Using the libraries

Every library exports a single entry point, `tree_sitter_<language>`, which returns the language definition:

```c
#include <dlfcn.h>
#include <tree_sitter/api.h>

void *handle = dlopen("tree_sitter_python.so", RTLD_NOW);
const TSLanguage *(*get_language)(void) = dlsym(handle, "tree_sitter_python");

TSParser *parser = ts_parser_new();
ts_parser_set_language(parser, get_language());
```

Parsers generated from `grammar.js` use the language ABI of the tree-sitter CLI used by the build. Make sure the
tree-sitter runtime you link against supports that ABI.

### File types

`config/filetypes.json` maps a library name to the file extensions and file names it handles:

```json
{
  "tree_sitter_c": [".c", ".h"],
  "tree_sitter_cmake": ["CMakeLists.txt", ".cmake", ".cmake.in"]
}
```

Keys are sorted alphabetically, one entry per line. Languages without any extension or file name (for example
injection-only ones such as `comment` or `markdown_inline`) are not listed. When the sync finds new languages in
`parsers.json`, their extensions come from [GitHub Linguist](https://github.com/github-linguist/linguist); entries
you edited by hand are never changed.

### Queries

The queries are taken unchanged from nvim-treesitter, so they use its conventions:

- `; inherits: <language>` and `; extends` comments at the top of a file have to be resolved by the consumer.
- Some queries use Neovim-specific predicates and directives such as `#lua-match?` or `#set!`.

### Themes

A theme file is made by `scripts/nvim_export_captures.lua` from a Neovim colorscheme and has three blocks:

- `meta`: colorscheme, background (`dark` / `light`) and Neovim, nvim-treesitter and AstroNvim versions
- `editor`: UI colors (background, cursor, line numbers, ...) with Android-style snake_case names
- `captures`: tree-sitter capture highlights; the keys have no leading `@`

Inside `captures` a value is either a style (`{ "fg": "#ff9e64", "bold": true }`) or a reference to another capture
written with `@` (`"preproc": "@keyword.directive"`), so a string starting with `@` always means a reference.

Run it in Neovim (for example in Termux). The file is named after the colorscheme (`astrodark.json`,
`astrolight.json`), or `<colorscheme>-<background>.json` when the name does not say dark or light:

```bash
BACKGROUND=dark  nvim --headless "+luafile scripts/nvim_export_captures.lua" +q
BACKGROUND=light nvim --headless "+luafile scripts/nvim_export_captures.lua" +q
```

### Key bindings

The editor is not a terminal Neovim, so it supports only a short list of basic keys: GUI-style shortcuts that work
in every mode (`Ctrl+C` copy, `Ctrl+V` paste, `Ctrl+Z` undo, `Ctrl+S` save, ...) and a small set of basic Vim keys.
The list is the `BASIC` table in `scripts/nvim_export_keymaps.lua`; the script writes it to `keymaps.json`, each entry
with `group`, `mode`, `keys` (Neovim notation), `action` and `description`:

```bash
lua scripts/export_keymaps.lua                            # no Neovim needed
nvim --headless "+luafile scripts/nvim_export_keymaps.lua" +q
```

## Building locally

Requirements: Python 3.9 or newer, git, a C/C++ compiler, and for grammars that ship without a pre-generated
`parser.c` the [tree-sitter CLI](https://github.com/tree-sitter/tree-sitter) plus Node.js and npm.

```bash
# Build on the host machine (reads grammar/parsers.json by default)
python3 scripts/build_parsers.py --cache ./ts-cache --output ./libs

# Build only some languages
python3 scripts/build_parsers.py --only python,lua,typescript,tsx

# Cross-compile for Android with the NDK clang (here: arm64, API 24)
NDK_BIN=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
python3 scripts/build_parsers.py \
    --cc  "$NDK_BIN/aarch64-linux-android24-clang" \
    --cxx "$NDK_BIN/aarch64-linux-android24-clang++" \
    --output ./libs-arm64
```

Run `python3 scripts/build_parsers.py --help` for the remaining options (`--jobs`, `--abi`, `--no-generate`,
`--strict`, ...).

## Licenses

This repository is licensed under the [Apache License 2.0](LICENSE). Each parser is built from its own upstream
repository (listed in `grammar/parsers.json`) and stays under that repository's license. The queries come from
nvim-treesitter, which is also licensed under Apache 2.0.

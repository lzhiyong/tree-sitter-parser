-- Exports Neovim's colorscheme to a JSON file for an Android text editor.
--
-- Output file name:
--   * the colorscheme name when it already encodes the variant (astrodark.json, astrolight.json,
--     github_dark.json: any name containing "dark" or "light")
--   * <colorscheme>-<background>.json otherwise (tokyonight-dark.json, tokyonight-light.json)
--
-- The file has three top-level blocks:
--   "meta"     colorscheme, background, Neovim / nvim-treesitter / AstroNvim info
--   "editor"   UI colors (editor background, cursor, line numbers, ...) with Android-style names
--   "captures" tree-sitter capture highlights, nothing else is mixed into this block
--
-- Capture names (the keys) are written WITHOUT the leading "@", which matches the theme format.
-- A value that is a string and starts with "@" is a reference to another capture, so a program
-- can tell references apart from everything else just by looking at the first character:
--   "preproc": "@keyword.directive"  -> link to another capture, kept as a reference
--   "diff.delta": { "bg": "#..." }   -> link to a regular group (DiffChange) is resolved to its real style
--   "boolean": { "fg": "#ff9e64" }   -> direct definitions are exported as a style table
--   "x": "@markup.heading"           -> the link target lacked the "@" but that capture exists
--   "x": "foo.bar"                   -> link to a group that is not defined anywhere stays as the link name
--
-- Usage (loads your config, so groups defined by your colorscheme and plugins are included):
--   nvim --headless "+luafile export_captures.lua" +q
-- For Neovim's built-in defaults only, add --clean:
--   nvim --headless --clean "+luafile export_captures.lua" +q
-- Set SKIP_LSP=1 to leave out the @lsp.* semantic token groups (they are not tree-sitter captures).
-- Set BACKGROUND=light (or dark) to export that variant of the colorscheme, one run per variant:
--   BACKGROUND=dark  nvim --headless "+luafile nvim_export_captures.lua" +q
--   BACKGROUND=light nvim --headless "+luafile nvim_export_captures.lua" +q

local skip_lsp = os.getenv("SKIP_LSP") == "1"

-- Optionally switch the background before anything is read. Neovim reloads the active colorscheme
-- when 'background' changes; reload it explicitly as well so every colorscheme picks it up.
local want_bg = os.getenv("BACKGROUND")
if want_bg == "light" or want_bg == "dark" then
  vim.o.background = want_bg
  if vim.g.colors_name then pcall(vim.cmd.colorscheme, vim.g.colors_name) end
  -- Some colorschemes force their own background; the export would then not be the requested variant
  if vim.o.background ~= want_bg then
    io.stderr:write(string.format("warning: BACKGROUND=%s requested but 'background' is %s\n", want_bg, vim.o.background))
  end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function hex(n)
  return n and string.format("#%06x", n) or nil
end

-- Convert a highlight definition into a plain style table (colors as #rrggbb)
local function style(def)
  local s = { fg = hex(def.fg), bg = hex(def.bg), sp = hex(def.sp) }
  for _, attr in ipairs({
    "bold", "italic", "underline", "undercurl", "underdouble", "underdotted",
    "underdashed", "strikethrough", "reverse", "standout", "nocombine",
  }) do
    if def[attr] then s[attr] = true end
  end
  -- An empty Lua table would be encoded as the JSON array [] instead of an object {}
  if vim.tbl_isempty(s) then return vim.empty_dict() end
  return s
end

-- Drop the leading "@" from a capture name: "@keyword.directive" -> "keyword.directive"
local function bare(name)
  return (name:gsub("^@", ""))
end

-- True if a highlight group with this name exists (either as a style or as a link)
local function is_defined(name)
  return not vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name }))
end

-- Follow a chain of links (Foo -> Bar -> Baz) until a real definition is reached.
-- The `seen` table guards against circular links.
local function resolve(name)
  local seen = {}
  local def = vim.api.nvim_get_hl(0, { name = name })
  while def.link and not seen[def.link] do
    seen[def.link] = true
    def = vim.api.nvim_get_hl(0, { name = def.link })
  end
  return def
end

-- Run a command and return its trimmed stdout, or nil if it fails or prints nothing
local function sh(cmd)
  local ok, res = pcall(vim.fn.system, cmd)
  if not ok or vim.v.shell_error ~= 0 then return nil end
  res = vim.trim(res)
  return res ~= "" and res or nil
end

-- Write a table as a JSON object with one entry per line (stable and diff-friendly).
-- `entries` is a list of { key, value } pairs; nil values become null.
local function json_object(entries, indent)
  local lines = {}
  for _, kv in ipairs(entries) do
    local v = kv[2]
    lines[#lines + 1] = string.format("%s%s: %s", indent, vim.json.encode(kv[1]), vim.json.encode(v == nil and vim.NIL or v))
  end
  return table.concat(lines, ",\n")
end

---------------------------------------------------------------------------
-- Captures
---------------------------------------------------------------------------

local captures = {}
for name, def in pairs(vim.api.nvim_get_hl(0, {})) do
  -- Every group starting with "@"; @lsp.* is only skipped when SKIP_LSP=1
  if name:sub(1, 1) == "@" and not (skip_lsp and name:match("^@lsp")) then
    local key = bare(name)
    if def.link and def.link:sub(1, 1) == "@" then
      captures[key] = def.link                  -- keep the reference to another capture, "@" included
    elseif def.link then
      local resolved = style(resolve(def.link)) -- resolve links to regular groups (DiffChange, ...)
      if not vim.tbl_isempty(resolved) then
        captures[key] = resolved
      elseif is_defined("@" .. def.link) then
        -- The link target lacks the "@" prefix (e.g. "markup.heading") but the capture
        -- "@markup.heading" exists: add the prefix so it is a proper capture reference
        captures[key] = "@" .. def.link
      else
        -- Dangling link: the target is not defined at all. Keep the plain link name (no "@")
        -- rather than exporting an empty style that would look like "no highlight".
        captures[key] = def.link
      end
    else
      captures[key] = style(def)                -- defined directly
    end
  end
end

local names = vim.tbl_keys(captures)
table.sort(names)
local capture_entries = {}
for _, n in ipairs(names) do capture_entries[#capture_entries + 1] = { n, captures[n] } end

---------------------------------------------------------------------------
-- Editor UI colors
---------------------------------------------------------------------------

-- Fully resolved style of a highlight group (links followed). A group that is drawn with
-- `reverse` is converted to explicit colors by swapping foreground and background, so the
-- consumer never has to deal with reverse video. Missing colors fall back to Normal.
local normal = resolve("Normal")

local function ui_style(group)
  local def = resolve(group)
  if vim.tbl_isempty(def) then return nil end
  if def.reverse then
    def = vim.tbl_extend("force", def, {
      fg = def.bg or normal.bg,
      bg = def.fg or normal.fg,
      reverse = false,
    })
  end
  local s = style(def)
  if vim.tbl_isempty(s) then return nil end
  return s
end

-- { name used in the output, highlight group, fallback group }
-- Names are snake_case in the style of Android resources (line_number, cursor_line, ...).
local ui_map = {
  { "background",              "Normal" },                 -- fg = default text, bg = editor background
  { "cursor",                  "Cursor" },
  { "cursor_line",             "CursorLine" },
  { "cursor_column",           "CursorColumn" },
  { "line_number",             "LineNr" },
  { "line_number_current",     "CursorLineNr" },
  { "line_number_above",       "LineNrAbove" },
  { "line_number_below",       "LineNrBelow" },
  { "gutter",                  "SignColumn" },
  { "fold_gutter",             "FoldColumn" },
  { "folded_text",             "Folded" },
  { "selection",               "Visual" },
  { "search_match",            "Search" },
  { "search_match_current",    "CurSearch", "IncSearch" },
  { "bracket_match",           "MatchParen" },
  { "whitespace",              "Whitespace" },
  { "non_text",                "NonText" },
  { "end_of_buffer",           "EndOfBuffer" },
  { "color_column",            "ColorColumn" },
  { "window_separator",        "WinSeparator", "VertSplit" },
  { "status_bar",              "StatusLine" },
  { "status_bar_inactive",     "StatusLineNC" },
  { "tab_bar",                 "TabLineFill" },
  { "tab",                     "TabLine" },
  { "tab_selected",            "TabLineSel" },
  { "popup",                   "Pmenu" },
  { "popup_selected",          "PmenuSel" },
  { "popup_scrollbar",         "PmenuSbar" },
  { "popup_scrollbar_thumb",   "PmenuThumb" },
  { "floating_window",         "NormalFloat" },
  { "floating_window_border",  "FloatBorder" },
  { "title",                   "Title" },
  { "directory",               "Directory" },
  { "error_text",              "ErrorMsg" },
  { "warning_text",            "WarningMsg" },
  { "diagnostic_error",        "DiagnosticError" },
  { "diagnostic_warning",      "DiagnosticWarn" },
  { "diagnostic_info",         "DiagnosticInfo" },
  { "diagnostic_hint",         "DiagnosticHint" },
  { "diagnostic_ok",           "DiagnosticOk" },
  { "diff_added",              "DiffAdd" },
  { "diff_changed",            "DiffChange" },
  { "diff_removed",            "DiffDelete" },
  { "diff_text",               "DiffText" },
  { "spell_error",             "SpellBad" },
  { "spell_warning",           "SpellCap" },
}

local editor_entries = {}
for _, m in ipairs(ui_map) do
  local s = ui_style(m[2]) or (m[3] and ui_style(m[3])) or nil
  -- The cursor is usually drawn with reverse video and no colors of its own; derive it from Normal
  if m[1] == "cursor" and s == nil then
    s = style({ fg = normal.bg, bg = normal.fg })
  end
  if s ~= nil then editor_entries[#editor_entries + 1] = { m[1], s } end
end

---------------------------------------------------------------------------
-- Meta
---------------------------------------------------------------------------

-- The output file is named after the colorscheme. Colorschemes whose name already says dark or
-- light (astrodark / astrolight) keep their own name; the others get the background appended so
-- the two exports do not overwrite each other. Unsafe file name characters become "_".
local scheme = vim.g.colors_name or "default"
local safe = scheme:gsub("[^%w%._%-]", "_")
local lower = scheme:lower()
local has_variant_in_name = lower:find("dark", 1, true) ~= nil or lower:find("light", 1, true) ~= nil
local filename = (has_variant_in_name and safe or (safe .. "-" .. vim.o.background)) .. ".json"

-- Git revision and branch of the nvim-treesitter plugin (nil if it is not on the runtimepath,
-- or not a git checkout). nvim-treesitter has no version number, so the revision identifies it.
local function nvim_treesitter_info()
  pcall(require, "nvim-treesitter")  -- lets lazy-loading plugin managers load it first
  local init = vim.api.nvim_get_runtime_file("lua/nvim-treesitter/init.lua", false)[1]
  if not init then return nil, nil end
  local root = init:gsub("[/\\]lua[/\\]nvim%-treesitter[/\\]init%.lua$", "")
  return sh({ "git", "-C", root, "rev-parse", "--short", "HEAD" }),
         sh({ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" })  -- "HEAD" = detached
end
local nts_revision, nts_branch = nvim_treesitter_info()

-- AstroNvim is itself a plugin managed by lazy.nvim. Look it up there; if lazy.nvim or the
-- plugin is missing, the distribution fields below simply become null.
local astro
local has_lazy, lazy = pcall(require, "lazy")
if has_lazy and type(lazy.plugins) == "function" then
  local ok, list = pcall(lazy.plugins)
  if ok and type(list) == "table" then
    for _, p in ipairs(list) do
      if p.name == "AstroNvim" then
        astro = p
        break
      end
    end
  end
end

-- Its nearest git tag and revision identify the version in use
local astro_version = astro and astro.dir and sh({ "git", "-C", astro.dir, "describe", "--tags", "--abbrev=0" })
local astro_revision = astro and astro.dir and sh({ "git", "-C", astro.dir, "rev-parse", "--short", "HEAD" })

local v = vim.version()
local meta_entries = {
  { "colorscheme", scheme },
  { "background", vim.o.background },                  -- "dark" or "light"
  { "nvim_version", string.format("%d.%d.%d%s", v.major, v.minor, v.patch, v.prerelease and "-dev" or "") },
  { "nvim_treesitter_revision", nts_revision },
  { "nvim_treesitter_branch", nts_branch },
  { "distribution", astro and "AstroNvim" or nil },
  { "distribution_version", astro_version },
  { "distribution_revision", astro_revision },
  { "exported_at", os.date("!%Y-%m-%dT%H:%M:%SZ") },
  { "includes_lsp_groups", not skip_lsp },
  { "capture_count", #names },
  { "editor_count", #editor_entries },
}

---------------------------------------------------------------------------
-- Write
---------------------------------------------------------------------------

local f = assert(io.open(filename, "w"))
f:write("{\n")
f:write('  "meta": {\n' .. json_object(meta_entries, "    ") .. "\n  },\n")
f:write('  "editor": {\n' .. json_object(editor_entries, "    ") .. "\n  },\n")
f:write('  "captures": {\n' .. json_object(capture_entries, "    ") .. "\n  }\n")
f:write("}\n")
f:close()
print(string.format("Wrote %d captures and %d editor colors to %s", #names, #editor_entries, filename))

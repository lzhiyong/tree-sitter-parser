-- Exports Neovim's built-in key mappings to keymaps.json for an Android text editor.
--
-- By default only mappings that Neovim itself defines are exported: the ones a pristine Neovim
-- has (which ones depends on the version; recent releases define for example Y, & and gc).
-- Mappings from your config, from AstroNvim and from plugins are left out.
-- Plain Vim commands such as dd, yy, hjkl or the <C-w> window commands are not mappings: they are
-- part of the editor itself and cannot be listed through any API, so they are not in the file.
--
-- How: the script starts a second Neovim with --clean (no config, no plugins) and exports the
-- mappings of that one, so the result does not depend on your own config. Your session is only
-- used to start it. Set INCLUDE_USER=1 to export the mappings of your own session instead.
--
-- The file has two top-level blocks, in the same style as export_captures.lua:
--   "meta"     scope, Neovim version (with INCLUDE_USER=1 also leader keys and AstroNvim info)
--   "keymaps"  one entry per mapping, keyed by a snake_case id, one entry per line
--
-- Entry format (fields that are empty or false are left out):
--   "normal_find_files": {
--     "mode": "normal",                  normal, insert, visual, select, operator_pending,
--                                        command_line, terminal or language
--     "keys": "<Space>ff",               key sequence in Neovim notation, <leader> already expanded
--     "description": "Find files",       the `desc` of the mapping
--     "command": ":Telescope find_files<CR>",   the right-hand side; left out for Lua callbacks,
--                                        whose code cannot be exported
--     "lua_callback": true,              the mapping runs a Lua function
--     "buffer_local": true,              only exists in the current buffer
--     "recursive": true,                 remapped (map instead of noremap)
--     "silent": true, "nowait": true, "expr": true
--   }
--
-- The id is "<mode>_<description>" (for example normal_find_files), or "<mode>_<keys>"
-- (normal_ctrl_s) when the mapping has no ASCII description. Ids that would repeat get _2, _3, ...
-- Entries are sorted by mode, then keys, so the ids stay stable between runs.
--
-- Usage (built-in mappings only; the script quits by itself, no +q needed):
--   nvim --headless "+luafile nvim_export_keymaps.lua"
-- Your own and plugin mappings instead (waits for startup to finish, so lazy-loaded plugins have
-- set theirs; buffer-local ones such as LSP keys only exist in a loaded buffer, and LSP keys need
-- the server to have attached within the delay):
--   INCLUDE_USER=1 nvim --headless "+luafile nvim_export_keymaps.lua"
--   INCLUDE_USER=1 nvim --headless main.kt "+luafile nvim_export_keymaps.lua"
--
-- Environment variables:
--   INCLUDE_USER=1          export the mappings of your config and plugins (default: built-in only)
--   KEYMAPS_OUT=path        output file (default keymaps.json)
--   INCLUDE_PLUG=1          also export <Plug> / <SNR> mappings (internal, hidden by default)
--   EXPORT_DELAY_MS=500     INCLUDE_USER only: wait after startup so lazy-loaded plugins are done
--   NO_WAIT=1               do not wait for startup and do not quit by itself: add +q yourself,
--                           as in export_captures.lua
--
-- Not exported: which-key group names (such as "Find" for <Leader>f), they are not mappings,
-- and mappings that a plugin only creates later, for example when a command or filetype loads it.

local OUT = os.getenv("KEYMAPS_OUT") or "keymaps.json"
local include_plug = os.getenv("INCLUDE_PLUG") == "1"
local include_user = os.getenv("INCLUDE_USER") == "1"
local delay_ms = tonumber(os.getenv("EXPORT_DELAY_MS")) or 500
local no_wait = os.getenv("NO_WAIT") == "1"
local headless = #vim.api.nvim_list_uis() == 0

-- True in the clean Neovim that the first one starts. Two markers are checked, so that a
-- missing one can never make the clean Neovim start another clean Neovim, and so on
local is_child = vim.g.export_keymaps_child == 1 or os.getenv("EXPORT_KEYMAPS_CHILD") == "1"

---------------------------------------------------------------------------
-- Modes
---------------------------------------------------------------------------

-- query = mode letter for nvim_get_keymap, name = name used in the output
local MODES = {
  { query = "n", name = "normal" },
  { query = "i", name = "insert" },
  { query = "x", name = "visual" },
  { query = "s", name = "select" },
  { query = "o", name = "operator_pending" },
  { query = "c", name = "command_line" },
  { query = "t", name = "terminal" },
  { query = "l", name = "language" },
}
local MODE_NAME, MODE_ORDER = {}, {}
for i, m in ipairs(MODES) do
  MODE_NAME[m.query] = m.name
  MODE_ORDER[m.query] = i
end

-- The mode field of a mapping can stand for several modes: "v" is visual and select, " " is
-- normal, visual, select and operator-pending, "!" is insert and command-line
local EXPAND = {
  v = { "x", "s" },
  [" "] = { "n", "x", "s", "o" },
  ["!"] = { "i", "c" },
}

---------------------------------------------------------------------------
-- Names for ids
---------------------------------------------------------------------------

local MOD = { c = "ctrl", m = "alt", a = "alt", s = "shift", d = "cmd" }

local NAMED = {
  space = "space", cr = "enter", enter = "enter", ["return"] = "enter", esc = "escape",
  tab = "tab", bs = "backspace", del = "delete", up = "up", down = "down", left = "left",
  right = "right", home = "home", ["end"] = "end", pageup = "page_up", pagedown = "page_down",
  insert = "insert", lt = "less_than", bar = "bar", bslash = "backslash", nul = "nul",
}

local PUNCT = {
  [" "] = "space", ["!"] = "bang", ['"'] = "quote", ["#"] = "hash", ["$"] = "dollar",
  ["%"] = "percent", ["&"] = "amp", ["'"] = "apostrophe", ["("] = "lparen", [")"] = "rparen",
  ["*"] = "star", ["+"] = "plus", [","] = "comma", ["-"] = "minus", ["."] = "dot",
  ["/"] = "slash", [":"] = "colon", [";"] = "semicolon", ["<"] = "less_than", ["="] = "equals",
  [">"] = "greater_than", ["?"] = "question", ["@"] = "at", ["["] = "lbracket",
  ["\\"] = "backslash", ["]"] = "rbracket", ["^"] = "caret", ["_"] = "underscore",
  ["`"] = "backtick", ["{"] = "lbrace", ["|"] = "bar", ["}"] = "rbrace", ["~"] = "tilde",
}

-- Name of one typed character: f -> f, F -> shift_f, / -> slash
local function char_name(c)
  if c:match("^%l$") or c:match("^%d$") then return c end
  if c:match("^%u$") then return "shift_" .. c:lower() end
  return PUNCT[c] or string.format("x%02x", c:byte())
end

-- Name of a key in angle brackets: <C-s> -> ctrl_s, <S-Tab> -> shift_tab, <CR> -> enter
local function token_name(tok)
  local inner = tok:sub(2, -2)
  local mods = {}
  while true do
    local m, rest = inner:match("^(%a)%-(.+)$")
    if m and MOD[m:lower()] then
      mods[#mods + 1] = MOD[m:lower()]
      inner = rest
    else
      break
    end
  end
  local base
  if #inner == 1 then
    base = char_name(inner)
  else
    base = NAMED[inner:lower()] or inner:lower():gsub("[^%w]+", "_")
  end
  mods[#mods + 1] = base
  return table.concat(mods, "_")
end

-- Name for a whole key sequence: "<Space>ff" -> space_f_f, "<C-s>" -> ctrl_s
local function keys_slug(lhs)
  local parts, i = {}, 1
  while i <= #lhs do
    local tok = lhs:match("^<[^<>]+>", i)
    if tok then
      parts[#parts + 1] = token_name(tok)
      i = i + #tok
    else
      parts[#parts + 1] = char_name(lhs:sub(i, i))
      i = i + 1
    end
  end
  return table.concat(parts, "_")
end

-- Name from a description: "Find files" -> find_files. Anything that is not an ASCII letter or
-- digit becomes "_", so a description in another script gives an empty result.
local function desc_slug(desc)
  if not desc then return "" end
  local s = desc:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if #s > 40 then s = s:sub(1, 40):gsub("_+$", "") end
  return s
end

---------------------------------------------------------------------------
-- Collect the mappings
---------------------------------------------------------------------------

local function flag(v)
  return (v == 1 or v == true) or nil
end

local function collect()
  local items, seen = {}, {}

  local function add(map, buffer_local)
    local lhs = map.lhs
    -- <Plug> and <SNR> mappings are internal entry points for other mappings
    if not include_plug and (lhs:find("^<Plug>") or lhs:find("^<SNR>")) then return end
    for _, q in ipairs(EXPAND[map.mode] or { map.mode }) do
      if MODE_NAME[q] then
        local key = table.concat({ q, lhs, buffer_local and "b" or "g" }, "\0")
        if not seen[key] then
          seen[key] = true
          items[#items + 1] = {
            query = q, mode = MODE_NAME[q], keys = lhs, map = map, buffer_local = buffer_local,
          }
        end
      end
    end
  end

  for _, m in ipairs(MODES) do
    for _, map in ipairs(vim.api.nvim_get_keymap(m.query)) do add(map, false) end
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, m.query)) do add(map, true) end
  end

  -- Sort first, then assign ids, so a repeated id always gets its number in the same order
  table.sort(items, function(a, b)
    if a.query ~= b.query then return MODE_ORDER[a.query] < MODE_ORDER[b.query] end
    if a.keys ~= b.keys then return a.keys < b.keys end
    return (a.buffer_local and 1 or 0) < (b.buffer_local and 1 or 0)
  end)

  local used = {}
  for _, it in ipairs(items) do
    local desc = it.map.desc
    local slug = desc_slug(desc)
    local base = it.mode .. "_" .. (slug ~= "" and slug or keys_slug(it.keys))
    local id, n = base, 1
    while used[id] do
      n = n + 1
      id = base .. "_" .. n
    end
    used[id] = true
    it.id = id
  end
  return items
end

---------------------------------------------------------------------------
-- JSON output
---------------------------------------------------------------------------

-- vim.json.encode fails on strings that are not valid UTF-8; fall back to a printable form
local function jenc(v)
  local ok, res = pcall(vim.json.encode, v)
  if ok then return res end
  return vim.json.encode(vim.fn.strtrans(tostring(v)))
end

-- One object on one line with the fields in a fixed order; nil fields are left out
local function ordered(fields)
  local parts = {}
  for _, kv in ipairs(fields) do
    if kv[2] ~= nil then parts[#parts + 1] = jenc(kv[1]) .. ": " .. jenc(kv[2]) end
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function entry_line(it)
  local map = it.map
  return ordered({
    { "mode", it.mode },
    { "keys", it.keys },
    { "description", (map.desc and map.desc ~= "") and map.desc or nil },
    { "command", (map.rhs and map.rhs ~= "") and map.rhs or nil },
    { "lua_callback", map.callback ~= nil or nil },
    { "buffer_local", it.buffer_local or nil },
    { "recursive", (not flag(map.noremap)) or nil },
    { "silent", flag(map.silent) },
    { "nowait", flag(map.nowait) },
    { "expr", flag(map.expr) },
  })
end

-- Run a command and return its trimmed stdout, or nil if it fails or prints nothing
local function sh(cmd)
  local ok, res = pcall(vim.fn.system, cmd)
  if not ok or vim.v.shell_error ~= 0 then return nil end
  res = vim.trim(res)
  return res ~= "" and res or nil
end

-- The leader keys in key notation
local function leader_notation(c)
  if c == nil or c == "" then return "\\" end
  if c == " " then return "<Space>" end
  return c
end

-- AstroNvim is itself a plugin managed by lazy.nvim. Look it up there; if lazy.nvim or the
-- plugin is missing, the distribution fields simply become null.
local function astro_info()
  local has_lazy, lazy = pcall(require, "lazy")
  if not (has_lazy and type(lazy.plugins) == "function") then return nil end
  local ok, list = pcall(lazy.plugins)
  if not (ok and type(list) == "table") then return nil end
  for _, p in ipairs(list) do
    if p.name == "AstroNvim" and p.dir then
      return {
        version = sh({ "git", "-C", p.dir, "describe", "--tags", "--abbrev=0" }),
        revision = sh({ "git", "-C", p.dir, "rev-parse", "--short", "HEAD" }),
      }
    end
  end
end

local function export()
  local items = collect()

  local keymap_lines = {}
  for _, it in ipairs(items) do
    keymap_lines[#keymap_lines + 1] = string.format("    %s: %s", jenc(it.id), entry_line(it))
  end

  local v = vim.version()
  local meta = {
    { "scope", include_user and "session" or "builtin" },
    { "nvim_version", string.format("%d.%d.%d%s", v.major, v.minor, v.patch, v.prerelease and "-dev" or "") },
    { "api_level", v.api_level },
  }
  if include_user then
    -- Only meaningful for your own session; the clean Neovim has no config, leader or AstroNvim
    local astro = astro_info()
    meta[#meta + 1] = { "leader", leader_notation(vim.g.mapleader) }
    meta[#meta + 1] = { "local_leader", leader_notation(vim.g.maplocalleader) }
    meta[#meta + 1] = { "distribution", astro and "AstroNvim" or nil }
    meta[#meta + 1] = { "distribution_version", astro and astro.version or nil }
    meta[#meta + 1] = { "distribution_revision", astro and astro.revision or nil }
    meta[#meta + 1] = { "buffer_filetype", vim.bo.filetype ~= "" and vim.bo.filetype or nil }
  end
  meta[#meta + 1] = { "includes_plug_mappings", include_plug }
  meta[#meta + 1] = { "exported_at", os.date("!%Y-%m-%dT%H:%M:%SZ") }
  meta[#meta + 1] = { "keymap_count", #items }

  local meta_lines = {}
  for _, kv in ipairs(meta) do
    meta_lines[#meta_lines + 1] = string.format("    %s: %s", jenc(kv[1]), jenc(kv[2] == nil and vim.NIL or kv[2]))
  end

  local f = assert(io.open(OUT, "w"))
  f:write("{\n")
  f:write('  "meta": {\n' .. table.concat(meta_lines, ",\n") .. "\n  },\n")
  f:write('  "keymaps": {\n' .. table.concat(keymap_lines, ",\n") .. "\n  }\n")
  f:write("}\n")
  f:close()
  return #items
end

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------

-- Export in this Neovim; returns ok and a message
local function run_export()
  local ok, res = pcall(export)
  if ok then return true, string.format("Wrote %d keymaps to %s", res, OUT) end
  return false, "keymap export failed: " .. tostring(res)
end

-- Export from a clean Neovim (no config, no plugins) started as a child process; returns ok and
-- the child's output. The child runs this same script, recognises itself by the markers and
-- exports at once.
local function run_in_clean_nvim()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) ~= "@" then
    return false, "keymap export failed: cannot find the path of this script "
      .. "(run it as: INCLUDE_USER=1 nvim --clean --headless \"+luafile nvim_export_keymaps.lua\")"
  end
  local script = vim.fn.fnamemodify(src:sub(2), ":p")

  vim.env.EXPORT_KEYMAPS_CHILD = "1"  -- second marker, inherited by the child process
  local out = vim.trim(vim.fn.system({
    vim.v.progpath, "--clean", "--headless",
    "--cmd", "let g:export_keymaps_child = 1",  -- first marker
    "+luafile " .. vim.fn.fnameescape(script),
  }))

  if vim.v.shell_error ~= 0 then
    return false, "keymap export failed in the clean Neovim" .. (out ~= "" and (":\n" .. out) or "")
  end
  return true, out ~= "" and out or ("Wrote keymaps to " .. OUT)
end

-- Report the result and, when asked to, leave Neovim ourselves: the delayed export runs after the
-- startup commands, so there is no "+q" to do it
local function finish(ok, message, quit)
  if ok then
    print(message)
  else
    io.stderr:write(message .. "\n")
  end
  if quit then
    vim.cmd(ok and "qa!" or "cquit 1")
  end
end

local quit = headless and not no_wait

if is_child then
  -- The clean Neovim: nothing to wait for, export and leave
  local ok, message = run_export()
  finish(ok, message, true)
elseif not include_user then
  -- Default: built-in mappings, taken from a clean Neovim
  local ok, message = run_in_clean_nvim()
  finish(ok, message, quit)
elseif no_wait then
  -- Own session, straight away, like export_captures.lua; the caller adds +q
  local ok, message = run_export()
  finish(ok, message, false)
elseif vim.v.vim_did_enter == 1 then
  -- Already running (for example :luafile inside Neovim): run once the current command is done
  vim.schedule(function()
    local ok, message = run_export()
    finish(ok, message, quit)
  end)
else
  -- Own session: "+luafile" runs before VimEnter. Wait for it, then give lazy-loaded plugins
  -- (lazy.nvim fires VeryLazy right after VimEnter) a moment to set their mappings
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      vim.defer_fn(function()
        local ok, message = run_export()
        finish(ok, message, quit)
      end, delay_ms)
    end,
  })
end

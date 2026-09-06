-- Big-file safety + slicing.
--
-- Files >= 5MB open in "bigfile" mode: filetype=bigfile, no syntax/treesitter/
-- LSP/undo, no line numbers/folds/etc. so big-but-loadable files stay fast and
-- plugins can't crash on them. (Files bigger than ~your RAM still can't open —
-- use the slice commands instead.)
--
-- CSV slices (open into editable scratch buffers; the original file is never
-- touched; bare :w is blocked — save with `:w /path/out.csv`):
--   :CsvHead [n] [path]          first n rows (default 100k)
--   :CsvTail [n] [path]          last n rows (default 100k)
--   :CsvGrep [max] {pattern} [path]   matching rows via rg (default 10k)
--
-- JSON slices (need jq; streaming variants are safe on huge files):
--   :JsonHead [n] [path]         first n array elements, compact (streaming)
--   :JsonTail [n] [path]         last n array elements (streaming)
--   :JsonKey {keypath} [path]    extract a subtree (pretty; few-GB ceiling)
--   :JsonFind [max] {jq-cond} [path]  filter elements, e.g. .status=="error"
--   :JsonPretty                  pretty-print current buffer to a new buffer
--
-- Visual-selection pretty-print (in place, undoable):
--   V-select JSON object(s) then <Space>jp (or :JsonPrettySel)
--
-- Paths are shell-escaped; "%" means the current buffer's file.
local M = {}

local BIGFILE_THRESHOLD = 5 * 1024 * 1024 -- 5MB

local SLICE_DEFAULTS = {
  head = 100000,
  tail = 100000,
  grep = 10000,
  json_head = 1000,
  json_tail = 1000,
  json_find = 1000,
}

local function have_jq()
  if vim.fn.executable("jq") == 1 then
    return true
  end
  vim.notify("jq is not installed.", vim.log.levels.ERROR, { title = "Json" })
  return false
end

local function is_big(fname)
  return vim.fn.getfsize(fname) >= BIGFILE_THRESHOLD
end

function M.setup()
  vim.api.nvim_create_autocmd("BufReadPre", {
    callback = function()
      local fname = vim.fn.expand("<afile>")
      if is_big(fname) then
        vim.b.bigfile = true
        -- Set filetype before auto-detection so treesitter/LSP never
        -- attach to the huge file.
        vim.bo.filetype = "bigfile"
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    callback = function()
      if not vim.b.bigfile then
        return
      end

      vim.bo.filetype = "bigfile"

      vim.wo.number = false
      vim.wo.relativenumber = false
      vim.wo.signcolumn = "no"
      vim.wo.cursorline = false
      vim.wo.colorcolumn = ""
      vim.wo.foldmethod = "manual"
      vim.wo.foldenable = false
      vim.wo.spell = false
      vim.bo.matchpairs = ""

      vim.bo.syntax = ""
      vim.bo.synmaxcol = 0
      vim.bo.undofile = false
      vim.bo.swapfile = false

      vim.g.matchup_matchparen_disable = 1
      vim.b.autoformat = false
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    callback = function()
      vim.b.bigfile = false
    end,
  })
end

local function open_lines(lines, desc)
  if not lines then
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].syntax = ""
  vim.bo[bufnr].modifiable = true

  vim.api.nvim_buf_set_name(bufnr, desc)

  vim.api.nvim_win_set_buf(0, bufnr)
end

local function open_slice(cmd, desc)
  local lines = vim.fn.systemlist(cmd, "", 1)
  if vim.v.shell_error ~= 0 then
    vim.notify(
      ("Slice command failed:\n%s"):format(table.concat(lines, "\n")),
      vim.log.levels.ERROR,
      { title = "Slice" }
    )
    return
  end
  open_lines(lines, desc)
end

local function resolve_path(path)
  if not path or path == "" then
    local current = vim.fn.expand("%")
    if current == "" then
      vim.notify("No path given and no file in current buffer.", vim.log.levels.ERROR, { title = "Slice" })
      return nil
    end
    return current
  end
  if path == "%" then
    path = vim.fn.expand("%")
  end
  return path
end

local function parse_count(raw, default)
  if not raw or raw == "" then
    return default
  end
  return tonumber(raw) or default
end

function M.commands()
  vim.api.nvim_create_user_command("CsvHead", function(ctx)
    local count = parse_count(ctx.fargs[1], SLICE_DEFAULTS.head)
    local path = resolve_path(ctx.fargs[2])
    if not path then
      return
    end
    open_slice(
      "head -n " .. count .. " " .. vim.fn.shellescape(path),
      ("csv-head-%d-%s"):format(count, ctx.fargs[2] or "file")
    )
  end, { nargs = "*", complete = "file" })

  vim.api.nvim_create_user_command("CsvTail", function(ctx)
    local count = parse_count(ctx.fargs[1], SLICE_DEFAULTS.tail)
    local path = resolve_path(ctx.fargs[2])
    if not path then
      return
    end
    open_slice(
      "tail -n " .. count .. " " .. vim.fn.shellescape(path),
      ("csv-tail-%d-%s"):format(count, ctx.fargs[2] or "file")
    )
  end, { nargs = "*", complete = "file" })

  vim.api.nvim_create_user_command("CsvGrep", function(ctx)
    local max = parse_count(ctx.fargs[1], SLICE_DEFAULTS.grep)
    local pattern = ctx.fargs[2]
    local path = resolve_path(ctx.fargs[3])
    if not pattern or not path then
      vim.notify("Usage: CsvGrep [max] {pattern} [path]", vim.log.levels.ERROR, { title = "Slice" })
      return
    end
    open_slice(
      "rg -n --no-heading -m " .. max .. " -- " .. vim.fn.shellescape(pattern) .. " " .. vim.fn.shellescape(path),
      ("csv-grep-%s-%s"):format(pattern, ctx.fargs[3] or "file")
    )
  end, { nargs = "*", complete = "file" })
end

local function run_jq(lines, program)
  local cmd = "jq " .. vim.fn.shellescape(program)
  local out = vim.fn.systemlist(cmd, lines, 1)
  if vim.v.shell_error ~= 0 then
    vim.notify(
      ("jq failed:\n%s"):format(table.concat(out, "\n")),
      vim.log.levels.ERROR,
      { title = "Json" }
    )
    return nil
  end
  return out
end

function M.pretty_selection_in_place()
  if not have_jq() then
    return
  end

  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  if start_line < 1 or end_line < 1 then
    vim.notify("No visual selection to pretty-print.", vim.log.levels.ERROR, { title = "JsonPrettySel" })
    return
  end
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local out = run_jq(lines, ".")
  if not out or #out == 0 then
    return
  end

  vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line, false, out)
  vim.api.nvim_win_set_cursor(0, { start_line, 0 })
end

local function first_non_ws_char(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local chunk = f:read(256)
  f:close()
  if not chunk then
    return nil
  end
  return chunk:match("%S")
end

function M.json_commands()
  vim.api.nvim_create_user_command("JsonHead", function(ctx)
    if not have_jq() then
      return
    end
    local count = parse_count(ctx.fargs[1], SLICE_DEFAULTS.json_head)
    local path = resolve_path(ctx.fargs[2])
    if not path then
      return
    end
    open_slice(
      "jq -nc --stream " .. vim.fn.shellescape("fromstream(1|truncate_stream(inputs))")
        .. " " .. vim.fn.shellescape(path) .. " | head -n " .. count,
      ("json-head-%d-%s"):format(count, ctx.fargs[2] or "file")
    )
  end, { nargs = "*", complete = "file" })

  vim.api.nvim_create_user_command("JsonTail", function(ctx)
    if not have_jq() then
      return
    end
    local count = parse_count(ctx.fargs[1], SLICE_DEFAULTS.json_tail)
    local path = resolve_path(ctx.fargs[2])
    if not path then
      return
    end
    open_slice(
      "jq -nc --stream " .. vim.fn.shellescape("fromstream(1|truncate_stream(inputs))")
        .. " " .. vim.fn.shellescape(path) .. " | tail -n " .. count,
      ("json-tail-%d-%s"):format(count, ctx.fargs[2] or "file")
    )
  end, { nargs = "*", complete = "file" })

  vim.api.nvim_create_user_command("JsonKey", function(ctx)
    if not have_jq() then
      return
    end
    local keypath = ctx.fargs[1]
    local path = resolve_path(ctx.fargs[2])
    if not keypath or not path then
      vim.notify("Usage: JsonKey {keypath} [path]", vim.log.levels.ERROR, { title = "Json" })
      return
    end
    if keypath:sub(1, 1) ~= "." then
      keypath = "." .. keypath
    end
    local program = keypath
    if first_non_ws_char(path) == "[" then
      program = ".[] | " .. keypath
    end
    open_slice(
      "jq " .. vim.fn.shellescape(program) .. " " .. vim.fn.shellescape(path),
      ("json-key-%s-%s"):format(program, ctx.fargs[2] or "file")
    )
  end, { nargs = "*", complete = "file" })

  vim.api.nvim_create_user_command("JsonFind", function(ctx)
    if not have_jq() then
      return
    end
    local max = parse_count(ctx.fargs[1], SLICE_DEFAULTS.json_find)
    local condition = ctx.fargs[2]
    local path = resolve_path(ctx.fargs[3])
    if not condition or not path then
      vim.notify("Usage: JsonFind [max] {jq-condition} [path]", vim.log.levels.ERROR, { title = "Json" })
      return
    end
    open_slice(
      "jq -c " .. vim.fn.shellescape(".[] | select(" .. condition .. ")") .. " " .. vim.fn.shellescape(path)
        .. " | head -n " .. max,
      ("json-find-%s-%s"):format(condition, ctx.fargs[3] or "file")
    )
  end, { nargs = "*", complete = "file" })

  vim.api.nvim_create_user_command("JsonPretty", function()
    if not have_jq() then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local out = run_jq(lines, ".")
    if not out then
      return
    end
    open_lines(out, "json-pretty")
  end, {})

  vim.api.nvim_create_user_command("JsonPrettySel", M.pretty_selection_in_place, {})

  vim.keymap.set("v", "<leader>jp", M.pretty_selection_in_place, {
    noremap = true,
    desc = "Pretty-print selected JSON in place",
  })
end

function M.setup_all()
  M.setup()
  M.commands()
  M.json_commands()
end

return M

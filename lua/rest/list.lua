local M = {}

local SKIP_DIRS = { [".git"] = true, ["node_modules"] = true }

local function notify(msg, level)
  vim.notify("rest.nvim: " .. msg, level or vim.log.levels.ERROR)
end

---Pad `text` on the right so it spans `width` display columns.
local function pad(text, width, display_width)
  return text .. string.rep(" ", math.max(width - display_width(text), 0))
end

---Highlight group per standard HTTP method; names must match the `RestMethod*`
---groups defined in `rest.ui`.
local METHOD_HL = {
  GET = "RestMethodGet",
  POST = "RestMethodPost",
  PUT = "RestMethodPut",
  PATCH = "RestMethodPatch",
  DELETE = "RestMethodDelete",
  HEAD = "RestMethodHead",
  OPTIONS = "RestMethodOptions",
  TRACE = "RestMethodTrace",
  CONNECT = "RestMethodConnect",
}

---Highlight group for an HTTP method: `RestMethodGet` and friends for the
---standard methods, `RestMethod` for anything else.
function M.method_hl(method)
  return METHOD_HL[tostring(method):upper()] or "RestMethod"
end

---Build picker entries from parsed files.
---
---`files` is an ordered array of `{ file, abs, requests }`: `file` is the path
---shown in the picker, `abs` the path to jump to, `requests` the requests of a
---parsed document (as returned by `rest.parser`). `width` maps a string to its
---display width and defaults to byte length.
---
---Every entry is `{ method, label, file, abs, line, method_hl, display,
---chunks }`, where `label` is the request's `### name`, falling back to its
---`@name <tag>` and then to its URL, and `display` is the picker row:
---`METHOD<sp>LABEL<sp>FILE`, with the method and label columns padded so rows
---line up. `chunks` splits the row into `{ text, hl_group? }` pieces (the
---method column carries `method_hl`) for pickers that highlight items.
function M.entries(files, width)
  local display_width = width or function(text)
    return #text
  end

  local entries = {}
  local method_width, label_width = 0, 0
  for _, f in ipairs(files) do
    for _, r in ipairs(f.requests) do
      local label = r.name or r.tag or r.url
      entries[#entries + 1] = {
        method = r.method,
        label = label,
        file = f.file,
        abs = f.abs,
        line = r.start_line,
        method_hl = M.method_hl(r.method),
      }
      method_width = math.max(method_width, display_width(r.method))
      label_width = math.max(label_width, display_width(label))
    end
  end

  for _, entry in ipairs(entries) do
    local method_col = pad(entry.method, method_width, display_width)
    local rest = "  " .. pad(entry.label, label_width, display_width) .. "  " .. entry.file
    entry.display = method_col .. rest
    entry.chunks = { { method_col, entry.method_hl }, { rest } }
  end
  return entries
end

---Recursively collect `*.http` files under `dirs`, sorted and deduplicated.
local function find_http_files(dirs)
  local seen, paths, stack = {}, {}, {}
  for _, dir in ipairs(dirs) do
    stack[#stack + 1] = (vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/+$", ""))
  end

  while #stack > 0 do
    local dir = table.remove(stack)
    local ok, iter = pcall(vim.fs.dir, dir)
    if ok then
      for name, ftype in iter do
        if ftype == "directory" then
          if not SKIP_DIRS[name] then
            stack[#stack + 1] = dir .. "/" .. name
          end
        elseif name:match("%.http$") then
          local abs = vim.fs.normalize(dir .. "/" .. name)
          if not seen[abs] then
            seen[abs] = true
            paths[#paths + 1] = abs
          end
        end
      end
    end
  end

  table.sort(paths)
  return paths
end

---Read a file, preferring a loaded buffer so unsaved edits show up.
local function read_file(abs)
  for _, info in ipairs(vim.fn.getbufinfo({ loaded = 1 })) do
    if info.name ~= "" and vim.fs.normalize(info.name) == abs then
      return table.concat(vim.api.nvim_buf_get_lines(info.bufnr, 0, -1, false), "\n")
    end
  end
  local ok, lines = pcall(vim.fn.readfile, abs)
  if not ok then
    return nil
  end
  return table.concat(lines, "\n")
end

---Parse every discovered file into `{ file, abs, requests }` entries.
---URLs are resolved against the file's own definitions (best effort: an
---unresolvable URL is kept as written).
local function collect(dirs)
  local parser = require("rest.parser")
  local variables = require("rest.variables")
  local files = {}

  for _, abs in ipairs(find_http_files(dirs)) do
    local text = read_file(abs)
    if text then
      local doc, err = parser.parse(text)
      if not doc then
        notify(("skipped %s: %s"):format(abs, err), vim.log.levels.WARN)
      else
        local requests = {}
        for _, r in ipairs(doc.requests) do
          local url = variables.resolve(r.url, doc.definitions, {
            responses = {},
            decode = vim.json.decode,
            encode = vim.json.encode,
          }) or r.url
          requests[#requests + 1] = {
            name = r.name,
            tag = r.tag,
            method = r.method,
            url = url,
            start_line = r.start_line,
          }
        end
        files[#files + 1] = {
          file = vim.fn.fnamemodify(abs, ":."),
          abs = abs,
          requests = requests,
        }
      end
    end
  end

  return files
end

---Jump to the request's file and put the cursor on its request line.
local function jump(entry)
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(entry.abs))
  if not ok then
    notify(tostring(err), vim.log.levels.WARN)
    return
  end
  local line = math.min(entry.line, vim.api.nvim_buf_line_count(0))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zz")
end

---Picker backends ------------------------------------------------------------

local function has_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return false
  end
  return (pcall(function()
    return snacks.picker.pick
  end))
end

local function has_telescope()
  return (pcall(require, "telescope.pickers"))
end

local function has_fzf()
  return (pcall(require, "fzf-lua"))
end

local AVAILABILITY = {
  snacks = has_snacks,
  telescope = has_telescope,
  fzf = has_fzf,
}

local function pick_snacks(entries, on_select)
  local items = {}
  for i, entry in ipairs(entries) do
    items[i] = { text = entry.display, entry = entry }
  end
  require("snacks").picker.pick({
    title = "REST requests",
    items = items,
    format = function(item)
      return item.entry.chunks
    end,
    preview = "none",
    confirm = function(picker, item)
      picker:close()
      if item and item.entry then
        on_select(item.entry)
      end
    end,
  })
end

local function pick_telescope(entries, on_select)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "REST requests",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = function()
              local method_col, hl = entry.chunks[1][1], entry.chunks[1][2]
              return entry.display, { { { 0, #method_col }, hl } }
            end,
            ordinal = entry.display,
            filename = entry.abs,
            lnum = entry.line,
          }
        end,
      }),
      sorter = require("telescope.config").values.generic_sorter({}),
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local picked = action_state.get_selected_entry()
          actions.close(bufnr)
          if picked and picked.value then
            on_select(picked.value)
          end
        end)
        return true
      end,
    })
    :find()
end

---ANSI SGR prefix for a highlight group (foreground color plus common
---attributes), or nil when the group defines nothing renderable. fzf-lua runs
---fzf with `--ansi`, so these render as colors in the fzf list.
local function hl_ansi(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or type(hl) ~= "table" then
    return nil
  end
  local codes = {}
  if type(hl.fg) == "number" then
    local fg = hl.fg
    codes[#codes + 1] = ("38;2;%d;%d;%d"):format(
      math.floor(fg / 65536),
      math.floor(fg / 256) % 256,
      fg % 256
    )
  end
  if hl.bold then
    codes[#codes + 1] = "1"
  end
  if hl.italic then
    codes[#codes + 1] = "3"
  end
  if hl.underline or hl.underdouble then
    codes[#codes + 1] = "4"
  end
  if #codes == 0 then
    return nil
  end
  return "\27[" .. table.concat(codes, ";") .. "m"
end

---Render chunks as one line with ANSI colors; fzf strips them again from its
---output, so selections match against `entry.display`.
local function ansi_line(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    local color = chunk[2] and hl_ansi(chunk[2])
    parts[#parts + 1] = color and (color .. chunk[1] .. "\27[0m") or chunk[1]
  end
  return table.concat(parts)
end

local function strip_ansi(text)
  return (text:gsub("\27%[[%d;]*m", ""))
end

local function pick_fzf(entries, on_select)
  local lines, by_line = {}, {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = ansi_line(entry.chunks)
    by_line[entry.display] = by_line[entry.display] or entry
  end
  require("fzf-lua").fzf_exec(lines, {
    prompt = "REST> ",
    actions = {
      ["default"] = function(selected)
        local text = selected and selected[1]
        local entry = text and (by_line[text] or by_line[strip_ansi(text)])
        if entry then
          on_select(entry)
        end
      end,
    },
  })
end

local function pick_ui_select(entries, on_select)
  vim.ui.select(entries, {
    prompt = "REST requests",
    format_item = function(entry)
      return entry.display
    end,
  }, function(entry)
    if entry then
      on_select(entry)
    end
  end)
end

local OPENERS = {
  snacks = pick_snacks,
  telescope = pick_telescope,
  fzf = pick_fzf,
  select = pick_ui_select,
}

local function resolve_picker(want)
  if want == nil or want == "auto" then
    for _, name in ipairs({ "snacks", "telescope", "fzf" }) do
      if AVAILABILITY[name]() then
        return name
      end
    end
    return "select"
  end
  return want
end

---Open a picker over every request in the `.http` files under `opts.dirs`.
---`opts.picker` is `"auto"` (default), `"snacks"`, `"telescope"`, `"fzf"` or
---`"select"` (`vim.ui.select`).
function M.open(opts)
  opts = opts or {}
  require("rest.ui") -- defines the Rest* highlight groups used by the pickers
  local dirs = (opts.dirs and #opts.dirs > 0) and opts.dirs or { "." }

  local picker = resolve_picker(opts.picker)
  local available = OPENERS[picker] ~= nil and (picker == "select" or AVAILABILITY[picker]())
  if not available then
    notify(
      ("picker '%s' is not available (expected one of: auto, snacks, telescope, fzf, select)"):format(
        tostring(opts.picker)
      )
    )
    return
  end

  local files = collect(dirs)
  if #files == 0 then
    notify(("no .http files found under %s"):format(table.concat(dirs, ", ")), vim.log.levels.WARN)
    return
  end

  local entries = M.entries(files, function(text)
    return vim.fn.strdisplaywidth(text)
  end)
  if #entries == 0 then
    notify(("no requests found under %s"):format(table.concat(dirs, ", ")), vim.log.levels.WARN)
    return
  end

  OPENERS[picker](entries, jump)
end

return M

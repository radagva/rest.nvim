local M = {}

M.defaults = {
  base_url = nil,
  timeout_s = 30,
  follow_redirects = false,
  verify_tls = true,
  cookies = { enabled = false, path = nil },
  jq_path = nil,
  ui = { split = "vertical" },
  list = { picker = "auto", dirs = { "." } },
}

M.options = vim.deepcopy(M.defaults)

local responses = {}
local active_env ---string (chosen via :RestEnv) | false (explicitly none) | nil (follow default)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

local function notify(msg, level)
  vim.notify("rest.nvim: " .. msg, level or vim.log.levels.ERROR)
end

---Load `rest-env.json`, searched upward from the working directory.
---Returns `state, err`: `nil, nil` when no file exists; `nil, err` when the
---file exists but cannot be decoded or normalized.
local function load_env_file()
  local found = vim.fs.find("rest-env.json", { upward = true, path = vim.fn.getcwd() })[1]
  if not found then
    return nil, nil
  end
  local text = table.concat(vim.fn.readfile(found), "\n")
  local ok, value = pcall(vim.json.decode, text)
  if not ok then
    return nil, ("rest-env.json: invalid JSON: %s"):format(tostring(value))
  end
  return require("rest.env").normalize(value)
end

---Variables of the active environment in `state` (nil when none applies).
local function environment_vars(state)
  if active_env == false then
    return nil
  end
  local name = active_env or state.default
  local vars = name and require("rest.env").vars(state, name)
  if not vars and active_env then
    -- chosen environment disappeared from the file: fall back to default
    active_env = nil
    name = state.default
    vars = name and require("rest.env").vars(state, name)
  end
  return vars
end

---Environment layer for variable resolution, or nil (no file / disabled).
---Broken files are reported once per call.
local function environment_layer()
  local state, err = load_env_file()
  if err then
    notify(err, vim.log.levels.WARN)
    return nil
  end
  if not state then
    return nil
  end
  return environment_vars(state)
end

---Resolution layer for a parsed document: file-level `@definitions` win over
---the active environment's variables.
local function resolution_definitions(doc)
  local env = environment_layer()
  if not env then
    return doc.definitions
  end
  return vim.tbl_extend("force", env, doc.definitions)
end

---Pick a request from the `.http` files under `list.dirs` and jump to it.
function M.list()
  require("rest.list").open(M.options.list, environment_layer())
end

---Delete the cookie jar used by cookie-enabled requests.
function M.cookies_clear()
  local removed = require("rest.transport").clear_cookies(M.options.cookies)
  if removed > 0 then
    notify(("cleared %d cookie jar(s)"):format(removed), vim.log.levels.INFO)
  else
    notify("no cookie jar to clear", vim.log.levels.WARN)
  end
end

local function count_vars(vars)
  local n = 0
  for _ in pairs(vars) do
    n = n + 1
  end
  return n
end

local function announce_env(name, vars)
  notify(("environment: %s (%d variable(s))"):format(name, count_vars(vars)), vim.log.levels.INFO)
end

---Show or switch the active environment (`rest-env.json`).
---With `name` selects it directly; without, offers a picker (including an
---entry to deactivate environments entirely).
function M.env(name)
  local state, err = load_env_file()
  if err then
    notify(err)
    return
  end
  if not state then
    notify(
      ("rest-env.json not found (searched upward from %s)"):format(vim.fn.getcwd()),
      vim.log.levels.WARN
    )
    return
  end
  local names = require("rest.env").names(state)
  if #names == 0 then
    notify("rest-env.json defines no environments", vim.log.levels.WARN)
    return
  end

  if name then
    local vars = require("rest.env").vars(state, name)
    if not vars then
      notify(("environment %q is not defined in rest-env.json"):format(name))
      return
    end
    active_env = name
    announce_env(name, vars)
    return
  end

  local items = { "(none)" }
  vim.list_extend(items, names)
  vim.ui.select(items, {
    prompt = "Environment",
    format_item = function(item)
      if item == state.default then
        return ("%s (default)"):format(item)
      end
      return item
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice == "(none)" then
      active_env = false
      notify("environment: none", vim.log.levels.INFO)
      return
    end
    active_env = choice
    announce_env(choice, require("rest.env").vars(state, choice))
  end)
end

local function parse_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return require("rest.parser").parse(table.concat(lines, "\n"))
end

local function http_block_lines(req)
  local lines = { "### imported from curl", ("%s %s"):format(req.method, req.url) }
  for _, header in ipairs(req.headers or {}) do
    lines[#lines + 1] = ("%s: %s"):format(header.name, header.value)
  end
  if req.body and req.body ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = req.body
  end
  return lines
end

---Insert `lines` into a `.http` buffer: fill an empty one, append to a
---`.http` buffer, otherwise open a new one.
local function insert_http_lines(lines)
  local current = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local empty = #current == 1 and current[1] == ""
  local name = vim.api.nvim_buf_get_name(0)
  local is_http = vim.bo.filetype == "http" or (name ~= "" and name:match("%.http$") ~= nil)
  if empty then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.filetype = "http"
    return
  end
  if is_http then
    local count = vim.api.nvim_buf_line_count(0)
    local last = vim.api.nvim_buf_get_lines(0, count - 1, count, false)[1] or ""
    local block = lines
    if last:match("%S") then
      block = vim.list_extend({ "" }, lines)
    end
    vim.api.nvim_buf_set_lines(0, -1, -1, false, block)
    return
  end
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.filetype = "http"
end

---Run the request under the cursor.
function M.run()
  local doc, perr = parse_buffer()
  if not doc then
    notify("parse error: " .. perr)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local request = require("rest.parser").request_at(doc.requests, cursor)
  if not request then
    notify(("no request found at or below line %d"):format(cursor), vim.log.levels.WARN)
    return
  end

  local resolved, verr =
    require("rest.variables").resolve_request(request, resolution_definitions(doc), {
      responses = responses,
      decode = vim.json.decode,
      encode = vim.json.encode,
    })
  if not resolved then
    notify(verr)
    return
  end

  notify(("running %s %s"):format(resolved.method, resolved.url), vim.log.levels.INFO)

  require("rest.transport").send(resolved, M.options, function(result)
    if not result.ok then
      notify(result.error)
      return
    end
    if request.tag then
      responses[request.tag] = result
    end
    require("rest.ui").open(result, vim.tbl_extend("force", M.options, M.options.ui))
  end)
end

---Copy the request under the cursor as a curl command to the system
---clipboard (`+`, so it can be pasted into a terminal) and the unnamed
---register.
function M.copy_curl()
  local doc, perr = parse_buffer()
  if not doc then
    notify("parse error: " .. perr)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local request = require("rest.parser").request_at(doc.requests, cursor)
  if not request then
    notify(("no request found at or below line %d"):format(cursor), vim.log.levels.WARN)
    return
  end

  local resolved, verr =
    require("rest.variables").resolve_request(request, resolution_definitions(doc), {
      responses = responses,
      decode = vim.json.decode,
      encode = vim.json.encode,
    })
  if not resolved then
    notify(verr)
    return
  end

  local url, uerr = require("rest.transport").resolve_url(resolved.url, M.options.base_url)
  if not url then
    notify(uerr)
    return
  end

  local cmd = require("rest.curl").build({
    method = resolved.method,
    url = url,
    headers = resolved.headers,
    body = resolved.body,
  })
  vim.fn.setreg("+", cmd)
  vim.fn.setreg('"', cmd)
  notify("copied curl command to the clipboard", vim.log.levels.INFO)
end

---Insert a curl command as a `.http` request. Reads the clipboard first and
---falls back to a prompt when it does not hold a parseable curl command.
function M.import_curl()
  local ok, clipboard = pcall(vim.fn.getreg, "+")
  local text = ok and clipboard or ""

  local req = require("rest.curl").parse(text)
  if not req then
    local input = vim.fn.input("curl command: ")
    if input == "" then
      notify("import cancelled", vim.log.levels.INFO)
      return
    end
    local perr
    req, perr = require("rest.curl").parse(input)
    if not req then
      notify("import failed: " .. perr)
      return
    end
  end

  insert_http_lines(http_block_lines(req))
  notify(("imported %s %s"):format(req.method, req.url), vim.log.levels.INFO)
end

return M

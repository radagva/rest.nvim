local M = {}

M.defaults = {
  base_url = nil,
  timeout_s = 30,
  follow_redirects = false,
  verify_tls = true,
  jq_path = nil,
  ui = { split = "vertical" },
}

M.options = vim.deepcopy(M.defaults)

local responses = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

local function notify(msg, level)
  vim.notify("rest.nvim: " .. msg, level or vim.log.levels.ERROR)
end

local function parse_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return require("rest.parser").parse(table.concat(lines, "\n"))
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

  local resolved, verr = require("rest.variables").resolve_request(request, doc.definitions, {
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

return M

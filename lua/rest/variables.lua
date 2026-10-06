local M = {}

local PATTERN = "{{%s*([%w_%-%.]+)%s*}}"

---Substitute `{{name}}` placeholders in `text` using `defs`.
---Returns the resolved string, or `nil, err` when a variable is undefined.
function M.resolve(text, defs)
  if type(text) ~= "string" then
    return nil, "expected a string to resolve"
  end
  defs = defs or {}
  local missing
  local out = text:gsub(PATTERN, function(name)
    if missing == nil and defs[name] == nil then
      missing = name
    end
    return defs[name] or ""
  end)
  if missing then
    return nil, ("undefined variable '%s'"):format(missing)
  end
  return out
end

---Resolve url, headers and body of a request against `defs`.
---Returns a new request table, or `nil, err`.
function M.resolve_request(request, defs)
  local url, uerr = M.resolve(request.url, defs)
  if not url then
    return nil, ("url: %s"):format(uerr)
  end

  local headers = {}
  for _, header in ipairs(request.headers or {}) do
    local value, herr = M.resolve(header.value, defs)
    if not value then
      return nil, ("header '%s': %s"):format(header.name, herr)
    end
    headers[#headers + 1] = { name = header.name, value = value }
  end

  local body = request.body
  if body ~= nil then
    local resolved, berr = M.resolve(body, defs)
    if not resolved then
      return nil, ("body: %s"):format(berr)
    end
    body = resolved
  end

  local out = {}
  for key, value in pairs(request) do
    out[key] = value
  end
  out.url = url
  out.headers = headers
  out.body = body
  return out
end

return M

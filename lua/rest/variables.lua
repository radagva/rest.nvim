local M = {}

local PATTERN = "%$(%$?[%a_][%w_%-%.%[%]]*)"

---Normalize `[0]` indexing to dotted segments (`body[0].x` -> `body.0.x`).
local function split_path(path)
  local normalized = (path:gsub("%[(%d+)%]", ".%1"))
  local segments = {}
  for segment in normalized:gmatch("[^%.]+") do
    segments[#segments + 1] = segment
  end
  return segments, normalized
end

---Case-insensitive lookup for JSON object keys.
local function field_get(tbl, key)
  if tbl[key] ~= nil then
    return tbl[key]
  end
  local lower = key:lower()
  for k, v in pairs(tbl) do
    if type(k) == "string" and k:lower() == lower then
      return v
    end
  end
  return nil
end

---Case-insensitive lookup of a response header value.
local function header_value(headers, name)
  local lower = name:lower()
  for _, header in ipairs(headers or {}) do
    if header.name:lower() == lower then
      return header.value
    end
  end
  return nil
end

---Segment access on a decoded JSON value: numeric segments index arrays
---(0-based, JSON convention) and fall back to string object keys.
local function seg_get(tbl, seg)
  local num = seg:match("^%d+$")
  if num then
    local value = tbl[tonumber(num) + 1]
    if value ~= nil then
      return value
    end
  end
  return field_get(tbl, seg)
end

---Stringify a resolved value; tables are encoded as compact JSON when an
---encoder is available (`opts.encode`).
local function stringify(value, opts)
  local t = type(value)
  if t == "string" then
    return value
  elseif t == "number" or t == "boolean" then
    return tostring(value)
  elseif value ~= nil and opts and opts.encode then
    local ok, encoded = pcall(opts.encode, value)
    if ok and type(encoded) == "string" then
      return encoded
    end
  end
  return nil
end

---Resolve a `<tag>.response.<field>...` path against stored responses.
---`opts` fields: responses (tag -> result), decode/encode (JSON codec).
---Returns a string, or nil, err.
local function resolve_ref(path, opts)
  opts = opts or {}
  local segments, normalized = split_path(path)
  if #segments < 3 or normalized ~= table.concat(segments, ".") then
    return nil, ("invalid response path '%s' (expected <tag>.response.<field>)"):format(path)
  end

  local tag = segments[1]
  if segments[2] ~= "response" then
    return nil, ("invalid response path '%s' (expected 'response' after '%s')"):format(path, tag)
  end

  local result = (opts.responses or {})[tag]
  if not result then
    return nil, ("undefined response '%s' (run its request first)"):format(tag)
  end

  local field = segments[3]

  if field == "body" then
    local value = result.body or ""
    if #segments > 3 then
      if not opts.decode then
        return nil, ("no JSON decoder for response '%s' body"):format(tag)
      end
      local ok, decoded = pcall(opts.decode, value)
      if not ok or type(decoded) ~= "table" then
        return nil, ("body of response '%s' is not JSON"):format(tag)
      end
      value = decoded
      for i = 4, #segments do
        if type(value) ~= "table" then
          return nil, ("field '%s' not found in response '%s' body"):format(segments[i], tag)
        end
        value = seg_get(value, segments[i])
        if value == nil then
          if segments[i]:match("^%d+$") then
            return nil, ("index %s out of range in response '%s' body"):format(segments[i], tag)
          end
          return nil, ("field '%s' not found in response '%s' body"):format(segments[i], tag)
        end
      end
    end
    local scalar = stringify(value, opts)
    if scalar == nil then
      if type(value) == "table" then
        return nil,
          ("response '%s' path '%s' resolves to a JSON object (no JSON encoder configured)"):format(
            tag,
            path
          )
      end
      return nil, ("response '%s' path '%s' cannot be substituted"):format(tag, path)
    end
    return scalar
  end

  if field == "headers" then
    local name = segments[4]
    if not name or #segments ~= 4 then
      return nil,
        ("invalid response path '%s' (expected <tag>.response.headers.<name>)"):format(path)
    end
    local value = header_value(result.headers, name)
    if value == nil then
      return nil, ("header '%s' not found in response '%s'"):format(name, tag)
    end
    return value
  end

  if field == "status" or field == "version" or field == "reason" or field == "url" then
    if #segments ~= 3 then
      return nil, ("invalid response path '%s' (expected <tag>.response.%s)"):format(path, field)
    end
    local value = stringify(result[field])
    if value == nil then
      return nil, ("response '%s' has no '%s'"):format(tag, field)
    end
    return value
  end

  return nil,
    ("unknown response field '%s' (expected body, headers, status, version, reason or url)"):format(
      field
    )
end

---Substitute `$name` references in `text` using `defs`.
---Names shaped like `<tag>.response.<path>` resolve against `opts.responses`
---(body fields are decoded with `opts.decode`; objects/arrays are inlined as
---compact JSON via `opts.encode`). A `$` not followed by a letter or
---underscore (e.g. `$99.99`) is left as-is; `$$word` escapes to a literal
---`$word`. Trailing dots are preserved (`$host.` -> `value.`).
---Returns the resolved string, or `nil, err`.
function M.resolve(text, defs, opts)
  if type(text) ~= "string" then
    return nil, "expected a string to resolve"
  end
  defs = defs or {}

  local err
  local out = text:gsub(PATTERN, function(name)
    if name:sub(1, 1) == "$" then
      return name
    end
    local core, dots = name:match("^(.-)(%.*)$")
    if defs[core] ~= nil then
      return defs[core] .. dots
    end
    if core:find(".", 1, true) then
      local value, rerr = resolve_ref(core, opts)
      if not value then
        err = err or rerr
        return ""
      end
      return value .. dots
    end
    if err == nil then
      err = ("undefined variable '%s'"):format(core)
    end
    return ""
  end)
  if err then
    return nil, err
  end
  return out
end

---Resolve url, headers and body of a request against `defs`.
---`opts` is forwarded to `resolve` (responses registry + JSON decoder).
---Returns a new request table, or `nil, err`.
function M.resolve_request(request, defs, opts)
  local url, uerr = M.resolve(request.url, defs, opts)
  if not url then
    return nil, ("url: %s"):format(uerr)
  end

  local headers = {}
  for _, header in ipairs(request.headers or {}) do
    local value, herr = M.resolve(header.value, defs, opts)
    if not value then
      return nil, ("header '%s': %s"):format(header.name, herr)
    end
    headers[#headers + 1] = { name = header.name, value = value }
  end

  local body = request.body
  if body ~= nil then
    local resolved, berr = M.resolve(body, defs, opts)
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

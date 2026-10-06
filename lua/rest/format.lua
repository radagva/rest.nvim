local M = {}

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---Locate a `jq` executable on `path` (default: $PATH).
---POSIX-only by design; returns nil when jq is unavailable.
function M.find_jq(path)
  path = path or os.getenv("PATH") or ""
  for dir in path:gmatch("[^:]+") do
    if dir ~= "" then
      local candidate = dir .. "/jq"
      local file = io.open(candidate, "r")
      if file then
        file:close()
        return candidate
      end
    end
  end
  return nil
end

---Heuristic: does `body` look like a JSON object or array?
function M.is_json(body)
  if type(body) ~= "string" then
    return false
  end
  local first = body:match("^%s*(.)")
  return first == "{" or first == "["
end

local function escape_string(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
  s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  s = s:gsub("%c", function(c)
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

local function is_array(t)
  local n = 0
  for key in pairs(t) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    if key > n then
      n = key
    end
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return n > 0
end

local function indent(depth)
  return string.rep("  ", depth)
end

---Render a decoded JSON value as indented JSON text (2-space indent).
---Object keys are sorted for deterministic output. Empty tables render as `{}`.
function M.render(value, depth)
  depth = depth or 0
  local t = type(value)
  if t == "string" then
    return escape_string(value)
  elseif t == "number" or t == "boolean" then
    return tostring(value)
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    if is_array(value) then
      local items = {}
      for i = 1, #value do
        items[#items + 1] = indent(depth + 1) .. M.render(value[i], depth + 1)
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent(depth) .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local items = {}
    for _, key in ipairs(keys) do
      items[#items + 1] = indent(depth + 1)
        .. escape_string(tostring(key))
        .. ": "
        .. M.render(value[key], depth + 1)
    end
    if #items == 0 then
      return "{}"
    end
    return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent(depth) .. "}"
  end
  return tostring(value)
end

local function run_jq(jq, body)
  local tmp = os.tmpname()
  local file = io.open(tmp, "w")
  if not file then
    return nil
  end
  file:write(body)
  file:close()

  local pipe = io.popen(jq .. " '.' " .. shell_quote(tmp) .. " 2>/dev/null", "r")
  local out = pipe:read("*a")
  pipe:close()
  os.remove(tmp)

  if out and out:match("%S") then
    return out
  end
  return nil
end

---Pretty-print a JSON body.
---
---Order: jq (when found and body looks like JSON) -> injected decoder +
---built-in renderer. Returns `formatted, tool` or `nil, reason`.
---
---`opts` fields:
---  jq_path: string|nil  explicit jq binary (skips find_jq)
---  path:    string|nil  PATH to search for jq (testing)
---  decode:  fun(s):any  JSON decoder, e.g. vim.json.decode
function M.pretty(body, opts)
  opts = opts or {}
  if type(body) ~= "string" or not M.is_json(body) then
    return nil, "not JSON"
  end

  local jq = opts.jq_path or M.find_jq(opts.path)
  if jq then
    local out = run_jq(jq, body)
    if out then
      return (out:gsub("%\n$", "")), "jq"
    end
  end

  if opts.decode then
    local ok, value = pcall(opts.decode, body)
    if ok and type(value) == "table" then
      return M.render(value, 0), "lua"
    end
  end

  return nil, "JSON decode failed"
end

---Map a response Content-Type to a Neovim filetype for syntax highlighting.
---When the content type is missing or `text/plain`, falls back to sniffing
---the body. Unknown content types are trusted over the body.
---Returns a filetype string or nil.
function M.detect_ft(content_type, body)
  local ct = (content_type or ""):lower()
  ct = ct:match("^%s*([^;]*)") or ""
  ct = ct:match("^%s*(.-)%s*$") or ""

  local plain = ct == "" or ct == "text/plain"
  if not plain then
    if ct:find("+json", 1, true) or ct == "application/json" then
      return "json"
    elseif ct == "text/html" or ct == "application/xhtml+xml" then
      return "html"
    elseif ct:find("+xml", 1, true) or ct == "application/xml" or ct == "text/xml" then
      return "xml"
    elseif ct:find("javascript", 1, true) then
      return "javascript"
    elseif ct == "text/css" then
      return "css"
    elseif ct:find("yaml", 1, true) then
      return "yaml"
    end
    return nil
  end

  if M.is_json(body) then
    return "json"
  end
  if type(body) == "string" then
    if body:match("^%s*<%?xml") then
      return "xml"
    elseif body:match("^%s*<") then
      return "html"
    end
  end
  return nil
end

return M

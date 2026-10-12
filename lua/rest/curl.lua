local M = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(n / 262144) % 64 + 1
    local c2 = math.floor(n / 4096) % 64 + 1
    local c3 = math.floor(n / 64) % 64 + 1
    local c4 = n % 64 + 1
    out[#out + 1] = B64:sub(c1, c1)
      .. B64:sub(c2, c2)
      .. (b and B64:sub(c3, c3) or "=")
      .. (c and B64:sub(c4, c4) or "=")
  end
  return table.concat(out)
end

---Shell-quote `s` for a POSIX shell (single-quote style).
function M.quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

---Split a curl command line into words, honoring single quotes, double
---quotes (with backslash escapes) and backslash-escaped characters.
---Returns `tokens` or `nil, err`.
local function tokenize(text)
  local tokens = {}
  local cur
  local i = 1
  local n = #text

  local function push()
    if cur ~= nil then
      tokens[#tokens + 1] = cur
      cur = nil
    end
  end

  while i <= n do
    local c = text:sub(i, i)
    if c:match("[%s]") then
      push()
      i = i + 1
    elseif c == "'" then
      local close = text:find("'", i + 1, true)
      if not close then
        return nil, "unterminated single quote"
      end
      cur = (cur or "") .. text:sub(i + 1, close - 1)
      i = close + 1
    elseif c == '"' then
      cur = cur or ""
      i = i + 1
      local closed = false
      while i <= n do
        local d = text:sub(i, i)
        if d == '"' then
          closed = true
          i = i + 1
          break
        elseif d == "\\" then
          local nxt = text:sub(i + 1, i + 1)
          if nxt == '"' or nxt == "\\" or nxt == "$" or nxt == "`" then
            cur = cur .. nxt
            i = i + 2
          elseif nxt == "\n" then
            i = i + 2
          else
            cur = cur .. d
            i = i + 1
          end
        else
          cur = cur .. d
          i = i + 1
        end
      end
      if not closed then
        return nil, "unterminated double quote"
      end
    elseif c == "\\" then
      local nxt = text:sub(i + 1, i + 1)
      if nxt == "" then
        return nil, "trailing backslash"
      end
      cur = (cur or "") .. nxt
      i = i + 2
    else
      cur = (cur or "") .. c
      i = i + 1
    end
  end
  push()
  return tokens
end

---Flags that consume a separate value we do not interpret (skipping them
---keeps the following word from being mistaken for the URL).
local VALUE_FLAGS = {
  ["-m"] = true,
  ["-x"] = true,
  ["-o"] = true,
  ["-D"] = true,
  ["-T"] = true,
  ["-w"] = true,
  ["--max-time"] = true,
  ["--connect-timeout"] = true,
  ["--connect-to"] = true,
  ["--retry"] = true,
  ["--retry-delay"] = true,
  ["--retry-max-time"] = true,
  ["--limit-rate"] = true,
  ["--max-filesize"] = true,
  ["--proxy"] = true,
  ["--unix-socket"] = true,
  ["--resolve"] = true,
  ["--cacert"] = true,
  ["--capath"] = true,
  ["--cert"] = true,
  ["--key"] = true,
  ["--pass"] = true,
  ["--output"] = true,
  ["--dump-header"] = true,
  ["--write-out"] = true,
}

local DATA_FLAGS = {
  ["-d"] = true,
  ["--data"] = true,
  ["--data-raw"] = true,
  ["--data-binary"] = true,
  ["--data-ascii"] = true,
  ["--data-urlencode"] = true,
}

local HEADER_NAME = "^%s*([%w!#$%&'*+%.^_`|~-]+)%s*:%s*(.-)%s*$"

---Parse a curl command into a request table.
---
---Returns `{ method, url, headers = { {name, value} }, body? }` or
---`nil, err`. Handles the flags browser DevTools emit (`-X`, `-H`, `-d*`,
---`--json`, `--url`, `-A`, `-b`, `-e`, `-u`, `-I`, `-G`, `-L`, `-k`, ...)
---and common transport flags (their values are skipped, not parsed).
function M.parse(text)
  if type(text) ~= "string" or not text:match("%S") then
    return nil, "empty command"
  end
  local joined = (text:gsub("\\\r?\n", " "))
  local tokens, terr = tokenize(joined)
  if not tokens then
    return nil, terr
  end
  if #tokens == 0 then
    return nil, "empty command"
  end

  local prog = tokens[1]:lower():match("([^/\\]+)$") or ""
  if prog ~= "curl" and prog ~= "curl.exe" then
    return nil, ("not a curl command (starts with %q)"):format(tokens[1])
  end

  local method, url, body
  local headers = {}
  local data = {}
  local head, get = false, false
  local json = false
  local i = 2

  local function add_header(name, value)
    if name:lower() ~= "content-length" then
      headers[#headers + 1] = { name = name, value = value }
    end
  end

  local function has_header(name)
    name = name:lower()
    for _, h in ipairs(headers) do
      if h.name:lower() == name then
        return true
      end
    end
    return false
  end

  while i <= #tokens do
    local t = tokens[i]
    local flag, inline, attached
    if t:match("^%-%-") then
      local eq = t:find("=", 1, true)
      if eq then
        flag, inline = t:sub(1, eq - 1), t:sub(eq + 1)
      else
        flag = t
      end
    elseif t:match("^%-%a") then
      flag = t:sub(1, 2)
      attached = t:sub(3)
      if attached == "" then
        attached = nil
      end
    end

    local function value()
      if inline ~= nil then
        return inline
      end
      if attached ~= nil then
        return attached
      end
      i = i + 1
      return tokens[i]
    end

    if flag == "-X" or flag == "--request" then
      local v = value()
      if not v or v == "" then
        return nil, flag .. " needs a value"
      end
      method = v:upper()
    elseif flag == "-H" or flag == "--header" then
      local v = value()
      if not v then
        return nil, flag .. " needs a value"
      end
      local hname, hvalue = v:match(HEADER_NAME)
      if not hname then
        return nil, ("bad header %q (expected 'Name: value')"):format(v)
      end
      add_header(hname, hvalue)
    elseif DATA_FLAGS[flag] then
      local v = value()
      if not v then
        return nil, flag .. " needs a value"
      end
      data[#data + 1] = v
    elseif flag == "--json" then
      local v = value()
      if not v then
        return nil, "--json needs a value"
      end
      data[#data + 1] = v
      json = true
    elseif flag == "--url" then
      local v = value()
      if not v or v == "" then
        return nil, "--url needs a value"
      end
      url = url or v
    elseif flag == "-A" or flag == "--user-agent" then
      local v = value()
      if v then
        add_header("User-Agent", v)
      end
    elseif flag == "-b" or flag == "--cookie" then
      local v = value()
      if v then
        add_header("Cookie", v)
      end
    elseif flag == "-e" or flag == "--referer" then
      local v = value()
      if v then
        add_header("Referer", v)
      end
    elseif flag == "-u" or flag == "--user" then
      local v = value()
      if v then
        if not v:find(":", 1, true) then
          v = v .. ":"
        end
        add_header("Authorization", "Basic " .. b64encode(v))
      end
    elseif flag == "-I" or flag == "--head" then
      head = true
    elseif flag == "-G" or flag == "--get" then
      get = true
    elseif VALUE_FLAGS[flag] then
      if inline == nil and attached == nil then
        i = i + 1
      end
    elseif flag == "--" then
      i = i + 1
      if tokens[i] then
        url = url or tokens[i]
      end
    elseif flag == nil and not url then
      url = t
    end
    i = i + 1
  end

  if not url or url == "" then
    return nil, "no URL found in the curl command"
  end

  if get and #data > 0 then
    local query = table.concat(data, "&")
    url = url .. (url:find("?", 1, true) and "&" or "?") .. query
    data = {}
  end

  if json then
    if not has_header("Content-Type") then
      add_header("Content-Type", "application/json")
    end
    if not has_header("Accept") then
      add_header("Accept", "application/json")
    end
  end

  if not method then
    if head then
      method = "HEAD"
    elseif #data > 0 then
      method = "POST"
    else
      method = "GET"
    end
  end
  if #data > 0 then
    body = table.concat(data, "&")
  end

  return { method = method, url = url, headers = headers, body = body }
end

---Render a request as a single-line, shell-quoted curl command.
---
---Transport plumbing (temp files, `-w`) is deliberately absent: the output
---is meant to be copied and re-run by hand, and to round-trip through
---`M.parse`.
function M.build(req)
  local parts = { "curl", "-X", req.method, M.quote(req.url) }
  for _, header in ipairs(req.headers or {}) do
    if header.name:lower() ~= "content-length" then
      parts[#parts + 1] = "-H"
      parts[#parts + 1] = M.quote(header.name .. ": " .. header.value)
    end
  end
  if req.body and req.body ~= "" then
    parts[#parts + 1] = "--data-binary"
    parts[#parts + 1] = M.quote(req.body)
  end
  return table.concat(parts, " ")
end

return M

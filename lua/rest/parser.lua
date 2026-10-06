local M = {}

local function split_lines(text)
  local lines = {}
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      local rest = text:sub(start)
      if rest ~= "" then
        lines[#lines + 1] = (rest:gsub("\r$", ""))
      end
      break
    end
    lines[#lines + 1] = (text:sub(start, nl - 1):gsub("\r$", ""))
    start = nl + 1
  end
  return lines
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function is_comment(line)
  return line:match("^%s*#") ~= nil or line:match("^%s*//") ~= nil
end

local function trim_trailing_blanks(lines, from, to)
  while to >= from and is_blank(lines[to]) do
    to = to - 1
  end
  return to
end

local function split_chunks(lines)
  local chunks = {}
  local first, name = 1, nil
  for i = 1, #lines do
    local sep_name = lines[i]:match("^%s*###%s*(.*)$")
    if sep_name then
      chunks[#chunks + 1] = { first = first, last = i - 1, name = name }
      first = i + 1
      name = sep_name ~= "" and sep_name or nil
    end
  end
  chunks[#chunks + 1] = { first = first, last = #lines, name = name }
  return chunks
end

local function parse_request_line(line, lineno)
  local method, target, rest = line:match("^(%u[%w%-]*)%s+(%S+)%s*(.*)$")
  if not method then
    return nil, ("line %d: expected request line, got %q"):format(lineno, line)
  end
  local version = "1.1"
  if rest ~= "" then
    local v = rest:match("^HTTP/([%d%.]+)$")
    if not v then
      return nil, ("line %d: malformed HTTP version in request line"):format(lineno)
    end
    version = v
  end
  return { method = method, url = target, version = version }
end

local function parse_chunk(lines, chunk, definitions, requests)
  local i = chunk.first
  local last = chunk.last

  while i <= last do
    local line = lines[i]
    if is_blank(line) or is_comment(line) then
      i = i + 1
    else
      local name, value = line:match("^%s*@([%w_%-%.]+)%s*=%s*(.-)%s*$")
      if name then
        definitions[name] = value
        i = i + 1
      else
        break
      end
    end
  end

  if i > last then
    return true
  end

  local request, err = parse_request_line(lines[i], i)
  if not request then
    return nil, err
  end
  local start_line = i
  i = i + 1

  local headers = {}
  while i <= last and not is_blank(lines[i]) do
    local line = lines[i]
    if is_comment(line) then
      i = i + 1
    else
      local hname, hvalue = line:match("^%s*([%w!#$%&'*+%.^_`|~-]+)%s*:%s*(.-)%s*$")
      if not hname then
        return nil, ("line %d: expected header or blank line, got %q"):format(i, line)
      end
      headers[#headers + 1] = { name = hname, value = hvalue }
      i = i + 1
    end
  end

  local end_line = math.max(start_line, i - 1)
  local body = nil

  if i <= last and is_blank(lines[i]) then
    local body_first, body_last = i + 1, trim_trailing_blanks(lines, i + 1, last)
    if body_last >= body_first then
      body = table.concat(lines, "\n", body_first, body_last)
      end_line = body_last
    end
  end

  requests[#requests + 1] = {
    name = chunk.name,
    method = request.method,
    url = request.url,
    version = request.version,
    headers = headers,
    body = body,
    start_line = start_line,
    end_line = end_line,
  }
  return true
end

---Parse `.http` text into a document.
---Returns `{ definitions = {name = value}, requests = {...} }` or `nil, err`.
function M.parse(text)
  if type(text) ~= "string" then
    return nil, "expected .http file content as a string"
  end

  local lines = split_lines(text)
  local definitions = {}
  local requests = {}

  for _, chunk in ipairs(split_chunks(lines)) do
    if chunk.first <= chunk.last then
      local ok, err = parse_chunk(lines, chunk, definitions, requests)
      if not ok then
        return nil, err
      end
    end
  end

  return { definitions = definitions, requests = requests }
end

---Find the request at `line`: exact range match, else the next request below it.
function M.request_at(requests, line)
  for _, request in ipairs(requests) do
    if line >= request.start_line and line <= request.end_line then
      return request
    end
  end
  for _, request in ipairs(requests) do
    if request.start_line >= line then
      return request
    end
  end
  return nil
end

return M

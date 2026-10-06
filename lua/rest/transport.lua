local M = {}

local ABSOLUTE_URL = "^%a[%w+.-]*://"

---Resolve a possibly relative URL against `base_url`.
---Returns `url` or `nil, err`.
function M.resolve_url(url, base_url)
  if url:match(ABSOLUTE_URL) then
    return url
  end
  if not base_url or base_url == "" then
    return nil, ("relative URL %q and no base_url configured"):format(url)
  end
  return (base_url:gsub("/+$", "")) .. "/" .. (url:gsub("^/+", ""))
end

---Build the curl argv for a request.
---
---`opts` fields: url, body_in, header_out, body_out (file paths),
---follow_redirects, verify_tls, timeout_s.
function M.build_curl_args(req, opts)
  local args = { "curl", "-sS", "-X", req.method }
  if opts.follow_redirects then
    args[#args + 1] = "-L"
  end
  if opts.verify_tls == false then
    args[#args + 1] = "-k"
  end
  if opts.timeout_s then
    args[#args + 1] = "-m"
    args[#args + 1] = tostring(opts.timeout_s)
  end
  args[#args + 1] = "-D"
  args[#args + 1] = opts.header_out
  args[#args + 1] = "-o"
  args[#args + 1] = opts.body_out
  args[#args + 1] = "-w"
  args[#args + 1] = "%{http_code} %{time_total}"

  for _, header in ipairs(req.headers or {}) do
    if header.name:lower() ~= "content-length" then
      args[#args + 1] = "-H"
      args[#args + 1] = header.name .. ": " .. header.value
    end
  end

  if req.body and req.body ~= "" then
    args[#args + 1] = "--data-binary"
    args[#args + 1] = "@" .. opts.body_in
  end

  args[#args + 1] = "--"
  args[#args + 1] = opts.url
  return args
end

---Parse the header dump written by curl (`-D`).
---Handles multiple blocks (redirects): the last status line wins.
---Returns `version, status, reason, headers` (headers: ordered array).
local function parse_header_dump(text)
  if not text or text == "" then
    return nil
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  local start
  for i, line in ipairs(lines) do
    if line:match("^HTTP/[%d%.]+%s") then
      start = i
    end
  end
  if not start then
    return nil
  end
  local version, status, reason = lines[start]:match("^HTTP/([%d%.]+)%s+(%d+)%s*(.*)$")
  local headers = {}
  for i = start + 1, #lines do
    local name, value = lines[i]:match("^([^:]+):%s*(.-)%s*$")
    if name then
      headers[#headers + 1] = { name = name, value = value }
    end
  end
  return version, tonumber(status), reason, headers
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

---Send a request asynchronously.
---
---Builds an absolute URL, spawns curl via vim.system and parses the response.
---Calls `callback(result)` on the main loop. `result` fields:
---  ok, status, version, reason, headers, body, time_s, error
function M.send(request, opts, callback)
  local url, url_err = M.resolve_url(request.url, opts.base_url)
  if not url then
    callback({ ok = false, error = url_err })
    return
  end

  local tmp = vim.fn.tempname()
  local paths = {
    header_out = tmp .. "_headers",
    body_out = tmp .. "_body",
    body_in = tmp .. "_request",
  }

  if request.body and request.body ~= "" then
    local file = io.open(paths.body_in, "w")
    if not file then
      callback({ ok = false, error = "cannot write request body to temp file" })
      return
    end
    file:write(request.body)
    file:close()
  end

  local argv = M.build_curl_args(request, {
    url = url,
    body_in = paths.body_in,
    header_out = paths.header_out,
    body_out = paths.body_out,
    follow_redirects = opts.follow_redirects,
    verify_tls = opts.verify_tls,
    timeout_s = opts.timeout_s,
  })

  vim.system(argv, { text = true }, function(out)
    vim.schedule(function()
      local header_text = read_file(paths.header_out) or ""
      local body = read_file(paths.body_out) or ""
      local version, status, reason, headers = parse_header_dump(header_text)
      headers = headers or {}
      local status_line, time_s = (out.stdout or ""):match("^(%d+)%s+([%d%.]+)")

      os.remove(paths.header_out)
      os.remove(paths.body_out)
      os.remove(paths.body_in)

      status = tonumber(status_line) or status
      if not status or status == 0 then
        local err = (out.stderr or ""):match("%S") and out.stderr
          or ("curl exited with code " .. tostring(out.code))
        callback({ ok = false, error = ("request failed: %s"):format((err:gsub("%s+$", ""))) })
        return
      end

      callback({
        ok = true,
        status = status,
        version = version or "1.1",
        reason = reason or "",
        headers = headers,
        body = body,
        time_s = tonumber(time_s),
        url = url,
      })
    end)
  end)
end

return M

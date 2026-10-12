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
---follow_redirects, verify_tls, timeout_s, cookie_jar (jar file passed as
---both `-b` and `-c`).
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
  if opts.cookie_jar then
    args[#args + 1] = "-b"
    args[#args + 1] = opts.cookie_jar
    args[#args + 1] = "-c"
    args[#args + 1] = opts.cookie_jar
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
---CR from CRLF line endings is stripped. Line endings are `\r\n` per RFC 9112.
---Returns `version, status, reason, headers` (headers: ordered array).
function M.parse_header_dump(text)
  if not text or text == "" then
    return nil
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
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

---Path of the session cookie jar (created lazily, once per session).
local session_jar

---Resolve the cookie jar for a send: nil when disabled, the expanded
---`cookies.path` for a persistent jar, else a session-only temp file.
local function cookie_jar(cookies)
  if not cookies or not cookies.enabled then
    return nil
  end
  if cookies.path and cookies.path ~= "" then
    return vim.fn.expand(cookies.path)
  end
  if not session_jar then
    session_jar = vim.fn.tempname() .. "_cookies"
  end
  return session_jar
end

---Delete the session and/or configured cookie jar.
---Returns how many jar files were removed.
function M.clear_cookies(cookies)
  local removed = 0
  if session_jar then
    if vim.fn.filereadable(session_jar) == 1 then
      os.remove(session_jar)
      removed = removed + 1
    end
    session_jar = nil
  end
  if cookies and cookies.path and cookies.path ~= "" then
    local path = vim.fn.expand(cookies.path)
    if vim.fn.filereadable(path) == 1 then
      os.remove(path)
      removed = removed + 1
    end
  end
  return removed
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
    cookie_jar = cookie_jar(opts.cookies),
  })

  vim.system(argv, { text = true }, function(out)
    vim.schedule(function()
      local header_text = read_file(paths.header_out) or ""
      local body = read_file(paths.body_out) or ""
      local version, status, reason, headers = M.parse_header_dump(header_text)
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

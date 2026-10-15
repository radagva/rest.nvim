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

---Plugin globals reachable through the reserved `$_` prefix.
local GLOBALS = { _now = true }

---Public field name -> key in an `os.date("*t")` table.
local FIELD_KEY = {
  year = "year",
  month = "month",
  day = "day",
  hour = "hour",
  minute = "min",
  second = "sec",
}

---Public field name -> zero-padding format.
local FIELD_FMT = {
  year = "%04d",
  month = "%02d",
  day = "%02d",
  hour = "%02d",
  minute = "%02d",
  second = "%02d",
}

---Shift methods on `$_now`: method name -> { field, op }.
local METHODS = {
  addHours = { "hour", "add" },
  subHours = { "hour", "sub" },
  addMinutes = { "minute", "add" },
  subMinutes = { "minute", "sub" },
  addSeconds = { "second", "add" },
  subSeconds = { "second", "sub" },
  addDays = { "day", "add" },
  subDays = { "day", "sub" },
  addMonths = { "month", "add" },
  subMonths = { "month", "sub" },
  addYears = { "year", "add" },
  subYears = { "year", "sub" },
}

local METHOD_NAMES = "addHours, subHours, addMinutes, subMinutes, addSeconds, subSeconds, "
  .. "addDays, subDays, addMonths, subMonths, addYears, subYears"

local NOW_USAGE = "expected $_now, $_now.<field>, $_now.<field>.add(<n>), "
  .. "$_now.<field>.sub(<n>) or a shift method such as $_now.addHours(<n>)"

local MDAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_leap(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local function days_in_month(year, month)
  if month == 2 and is_leap(year) then
    return 29
  end
  return MDAYS[month]
end

---Format a broken-down local time as ISO 8601 (`2026-10-15T14:30:05`).
local function iso(t)
  return ("%04d-%02d-%02dT%02d:%02d:%02d"):format(t.year, t.month, t.day, t.hour, t.min, t.sec)
end

---Calendar-only day adjustment (no clock, no timezone): borrows months and
---years while `t.day` sits outside its month.
local function normalize_date(t)
  while t.day > days_in_month(t.year, t.month) do
    t.day = t.day - days_in_month(t.year, t.month)
    t.month = t.month + 1
    if t.month > 12 then
      t.month = 1
      t.year = t.year + 1
    end
  end
  while t.day < 1 do
    t.month = t.month - 1
    if t.month < 1 then
      t.month = 12
      t.year = t.year - 1
    end
    t.day = t.day + days_in_month(t.year, t.month)
  end
end

---Carry seconds into minutes, hours and days, then fix the date.
local function normalize_clock(t)
  local carry = math.floor(t.sec / 60)
  t.sec = t.sec % 60
  t.min = t.min + carry
  carry = math.floor(t.min / 60)
  t.min = t.min % 60
  t.hour = t.hour + carry
  carry = math.floor(t.hour / 24)
  t.hour = t.hour % 24
  t.day = t.day + carry
  normalize_date(t)
end

local function copy_time(t)
  local out = {}
  for key, value in pairs(t) do
    out[key] = value
  end
  return out
end

---Shift by whole months, clamping the day into the target month.
local function shift_months(t, n)
  local month = t.month - 1 + n
  t.year = t.year + math.floor(month / 12)
  t.month = month % 12 + 1
  local last = days_in_month(t.year, t.month)
  if t.day > last then
    t.day = last
  end
end

---Apply `.add(n)` / `.sub(n)` on `field` of `t` in place (t is already a
---private copy); the clock and calendar are re-normalized after the shift.
local function apply_shift(t, field, op, amount)
  local delta = op == "add" and amount or -amount
  if field == "second" then
    t.sec = t.sec + delta
    normalize_clock(t)
  elseif field == "minute" then
    t.min = t.min + delta
    normalize_clock(t)
  elseif field == "hour" then
    t.hour = t.hour + delta
    normalize_clock(t)
  elseif field == "day" then
    t.day = t.day + delta
    normalize_date(t)
  elseif field == "month" then
    shift_months(t, delta)
  else
    t.year = t.year + delta
    local last = days_in_month(t.year, t.month)
    if t.day > last then
      t.day = last
    end
  end
end

local function now_reference_error(expr)
  return ("invalid '$_now' reference '%s' (%s)"):format(expr, NOW_USAGE)
end

local function unknown_field_error(field)
  return ("unknown '$_now' field '%s' (expected year, month, day, hour, minute or second)"):format(
    field
  )
end

local function unknown_method_error(method)
  return ("unknown '$_now' method '%s' (expected one of %s)"):format(method, METHOD_NAMES)
end

---Parse `(<n>)` call arguments; nil when malformed.
local function parse_amount(call)
  local digits = call and call:match("^%(%s*(-?%d+)%s*%)$")
  return digits and tonumber(digits)
end

---Index of the balanced `(...)` group starting at `pos`, or nil.
local function match_parens(text, pos)
  if text:sub(pos, pos) ~= "(" then
    return nil
  end
  local depth = 0
  for i = pos, #text do
    local char = text:sub(i, i)
    if char == "(" then
      depth = depth + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
  end
  return nil
end

---Consume a `(<n>)` argument group at `pos` and apply the shift to `t`.
---Returns the position after the group, or nil, err (`expr` names the
---reference in error messages).
local function consume_shift(text, pos, expr, t, field, op)
  local pe = match_parens(text, pos)
  if not pe then
    return nil, now_reference_error(expr)
  end
  local call = text:sub(pos, pe)
  local amount = parse_amount(call)
  if not amount then
    return nil, now_reference_error(expr .. call)
  end
  apply_shift(t, field, op, amount)
  return pe + 1
end

---Resolve a `$_now` reference: `core` is the matched name (`_now`,
---`_now.hour`, `_now.addHours`, ...) and `e` its last index in `text`.
---Shift methods and `<field>.add(<n>)` / `.sub(<n>)` shifts are chainable:
---`.method(<n>)` groups that follow in `text` are consumed in written
---order, and a chain may end with one field access (`...addDays(1).day`).
---Text after the reference that is not part of it stays literal
---(`$_now.addHours(1).json`). Returns the value, an error, and the index
---of the last consumed character.
local function resolve_global(core, e, text, now_t)
  local expr = "$" .. core
  local rest = core:match("^_now%.(.*)$")
  local pos = e + 1

  if not rest then
    local pe = match_parens(text, pos)
    if pe then
      return nil, now_reference_error(expr .. text:sub(pos, pe)), nil
    end
    return iso(now_t), nil, e
  end

  local t = copy_time(now_t)
  local method = METHODS[rest]
  if method then
    local newpos, merr = consume_shift(text, pos, expr, t, method[1], method[2])
    if not newpos then
      return nil, merr, nil
    end
    expr = expr .. text:sub(pos, newpos - 1)
    pos = newpos
  else
    local field, op = rest:match("^(%a+)%.(%a+)$")
    if field and (op == "add" or op == "sub") then
      if not FIELD_KEY[field] then
        return nil, unknown_field_error(field), nil
      end
      local newpos, merr = consume_shift(text, pos, expr, t, field, op)
      if not newpos then
        return nil, merr, nil
      end
      expr = expr .. text:sub(pos, newpos - 1)
      pos = newpos
    elseif rest:match("^add") or rest:match("^sub") then
      return nil, unknown_method_error(rest), nil
    else
      local fld = rest:match("^(%a+)$")
      if not fld then
        return nil, now_reference_error(expr), nil
      end
      if not FIELD_KEY[fld] then
        return nil, unknown_field_error(fld), nil
      end
      local pe = match_parens(text, pos)
      if pe then
        return nil, now_reference_error(expr .. text:sub(pos, pe)), nil
      end
      return string.format(FIELD_FMT[fld], now_t[FIELD_KEY[fld]]), nil, e
    end
  end

  -- chained shift methods, then an optional field access
  while text:sub(pos, pos) == "." do
    local seg = text:match("^[%w_]+", pos + 1)
    if not seg then
      break
    end
    local m = METHODS[seg]
    if m then
      local call = pos + 1 + #seg
      local head = expr .. "." .. seg
      local newpos, merr = consume_shift(text, call, head, t, m[1], m[2])
      if not newpos then
        return nil, merr, nil
      end
      expr = head .. text:sub(call, newpos - 1)
      pos = newpos
    elseif FIELD_KEY[seg] then
      local after = pos + 1 + #seg
      if text:sub(after, after) == "." and text:sub(after + 1, after + 1):match("[%a_]") then
        return nil, now_reference_error(expr .. "." .. seg), nil
      end
      return string.format(FIELD_FMT[seg], t[FIELD_KEY[seg]]), nil, after - 1
    elseif seg:match("^add") or seg:match("^sub") then
      return nil, unknown_method_error(seg), nil
    else
      break
    end
  end
  return iso(t), nil, pos - 1
end

---Reject definitions using the reserved `$_` prefix (plugin globals).
---Returns nil when clean, or an error message.
function M.check_defs(defs)
  for name in pairs(defs or {}) do
    if type(name) == "string" and name:sub(1, 1) == "_" then
      return ("the '$_' prefix is reserved for plugin globals; remove the '%s' definition"):format(
        name
      )
    end
  end
  return nil
end

---The `a -> b -> a` path reported for a circular definition, or nil when
---`name` is not already being resolved.
local function cycle_path(chain, name)
  local parts = {}
  local seen = false
  for _, entry in ipairs(chain) do
    parts[#parts + 1] = entry
    if entry == name then
      seen = true
    end
  end
  if not seen then
    return nil
  end
  parts[#parts + 1] = name
  return table.concat(parts, " -> ")
end

---Resolve `$name` references in `text` against `defs`. `now_t` is the
---shared `$_now` snapshot; `chain` holds the definition names currently
---being resolved (pushed and popped around each derived value) for cycle
---detection. The third return value marks a circular-definition error so
---callers propagate it unwrapped.
local function resolve_text(text, defs, opts, now_t, chain)
  local parts = {}
  local err, err_cycle
  local function fail(msg, cycle)
    if err == nil then
      err = msg
      err_cycle = cycle == true
    end
  end

  local init = 1
  while true do
    local s, e, name = text:find(PATTERN, init)
    if not s then
      break
    end
    parts[#parts + 1] = text:sub(init, s - 1)

    local stop = e
    local replacement
    if name:sub(1, 1) == "$" then
      replacement = name
    else
      local core, dots = name:match("^(.-)(%.*)$")
      if GLOBALS[core:match("^[^%.]+")] then
        local value, gerr, stop2 = resolve_global(core, e, text, now_t)
        if not value then
          fail(gerr)
          replacement = ""
        else
          replacement = value .. dots
          stop = stop2
        end
      elseif defs[core] ~= nil then
        local raw = defs[core]
        if type(raw) ~= "string" then
          replacement = tostring(raw) .. dots
        else
          local path = cycle_path(chain, core)
          if path then
            fail(("circular definition: %s"):format(path), true)
            replacement = ""
          else
            chain[#chain + 1] = core
            local value, derr, dcyc = resolve_text(raw, defs, opts, now_t, chain)
            chain[#chain] = nil
            if not value then
              if dcyc then
                fail(derr, true)
              else
                fail(("definition '%s': %s"):format(core, derr))
              end
              replacement = ""
            else
              replacement = value .. dots
            end
          end
        end
      elseif core:find(".", 1, true) then
        local value, rerr = resolve_ref(core, opts)
        if not value then
          fail(rerr)
          replacement = ""
        else
          replacement = value .. dots
        end
      else
        if core:sub(1, 1) == "_" then
          fail(("undefined variable '%s' ($_ prefix is reserved)"):format(core))
        else
          fail(("undefined variable '%s'"):format(core))
        end
        replacement = ""
      end
    end

    parts[#parts + 1] = replacement
    init = stop + 1
  end
  parts[#parts + 1] = text:sub(init)

  if err then
    return nil, err, err_cycle
  end
  return table.concat(parts)
end

---Substitute `$name` references in `text` using `defs`.
---Names shaped like `<tag>.response.<path>` resolve against `opts.responses`
---(body fields are decoded with `opts.decode`; objects/arrays are inlined as
---compact JSON via `opts.encode`). A `$` not followed by a letter or
---underscore (e.g. `$99.99`) is left as-is; `$$word` escapes to a literal
---`$word`. Trailing dots are preserved (`$host.` -> `value.`).
---
---The reserved `$_` prefix addresses plugin globals: `$_now` is the
---`opts.now` snapshot (an `os.date("*t")` table, defaulting to the current
---time) as a local ISO 8601 timestamp, `$_now.<field>` a zero-padded field,
---and `$_now.<field>.add(<n>)` / `.sub(<n>)` the full timestamp after
---calendar normalization. The same shifts exist as chainable methods on
---`$_now` itself (`$_now.addHours(<n>)`, `subHours`, `add/subMinutes`,
---`add/subSeconds`, `add/subDays`, `add/subMonths`, `add/subYears`): links
---apply in written order and a chain may end with a field access
---(`$_now.addDays(1).day`). Definitions must not use the `$_` prefix; see
---`check_defs`.
---
---Definitions are derived: a definition's value goes through this same
---resolution before it is substituted, so other definitions, environment
---values, previous responses and `$_` globals all work inside
---`@name = value`. Values share `now_t`, so everything in one request sees
---one clock snapshot. Failures inside a value are reported as
---`definition '<name>': <error>`; a definition that (directly or through
---others) references itself reports `circular definition: <path>`.
---
---Returns the resolved string, or `nil, err`.
function M.resolve(text, defs, opts)
  if type(text) ~= "string" then
    return nil, "expected a string to resolve"
  end
  defs = defs or {}

  local cerr = M.check_defs(defs)
  if cerr then
    return nil, cerr
  end

  local now_t = (opts and opts.now) or os.date("*t")
  local out, err = resolve_text(text, defs, opts, now_t, {})
  return out, err
end

---Take one `os.date("*t")` snapshot so every `$_now` reference in the
---request sees the same instant.
local function with_now(opts)
  if opts and opts.now then
    return opts
  end
  local out = {}
  for key, value in pairs(opts or {}) do
    out[key] = value
  end
  out.now = os.date("*t")
  return out
end

---Resolve url, headers and body of a request against `defs`.
---`opts` is forwarded to `resolve` (responses registry + JSON decoder);
---a single clock snapshot is taken for the whole request.
---Returns a new request table, or `nil, err`.
function M.resolve_request(request, defs, opts)
  local cerr = M.check_defs(defs)
  if cerr then
    return nil, cerr
  end
  opts = with_now(opts)

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

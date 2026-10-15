local variables = require("rest.variables")

describe("variables", function()
  it("substitutes references", function()
    assert.equals(
      "https://api.example.com/users",
      variables.resolve("$host/users", { host = "https://api.example.com" })
    )
  end)

  it("substitutes every occurrence", function()
    assert.equals("x and x and x", variables.resolve("$a and $a and $a", { a = "x" }))
  end)

  it("concatenates inside quoted strings", function()
    assert.equals(
      '"some value tok-123"',
      variables.resolve('"some value $token"', { token = "tok-123" })
    )
    assert.equals("Bearer x", variables.resolve("Bearer $t", { t = "x" }))
  end)

  it("fails on an undefined variable", function()
    local out, err = variables.resolve("$missing", {})
    assert.is_nil(out)
    assert.matches("undefined variable 'missing'", err)
  end)

  it("passes text without references unchanged", function()
    assert.equals("plain text", variables.resolve("plain text", {}))
    assert.equals("", variables.resolve("", {}))
  end)

  it("accepts empty definitions", function()
    assert.equals("x=", variables.resolve("x=$e", { e = "" }))
  end)

  it("preserves a trailing dot after a reference", function()
    assert.equals("x.", variables.resolve("$host.", { host = "x" }))
  end)

  it("leaves $ alone when not followed by a name", function()
    assert.equals("$ ", variables.resolve("$ ", {}))
    assert.equals("$99.99", variables.resolve("$99.99", {}))
    assert.equals("$5 + $5", variables.resolve("$5 + $5", {}))
    assert.equals('{"a": 1}', variables.resolve('{"a": 1}', {}))
  end)

  it("escapes a reference with $$", function()
    assert.equals("$HOME", variables.resolve("$$HOME", { HOME = "nope" }))
    assert.equals("$token", variables.resolve("$$token", {}))
  end)

  it("resolves a full request", function()
    local request = {
      method = "POST",
      url = "$host/login",
      headers = { { name = "Authorization", value = "Bearer $token" } },
      body = '{"user": "$user"}',
      start_line = 1,
      end_line = 5,
    }
    local resolved = assert(variables.resolve_request(request, {
      host = "https://api.example.com",
      token = "s3cret",
      user = "root",
    }))
    assert.equals("https://api.example.com/login", resolved.url)
    assert.equals("Bearer s3cret", resolved.headers[1].value)
    assert.equals('{"user": "root"}', resolved.body)
    assert.equals("POST", resolved.method)
  end)

  it("reports which field failed to resolve", function()
    local request = {
      method = "GET",
      url = "$host/x",
      headers = { { name = "X-Tok", value = "$nope" } },
    }
    local out, err = variables.resolve_request(request, { host = "https://x" })
    assert.is_nil(out)
    assert.matches("header 'X%-Tok'", err)
  end)

  describe("response refs", function()
    local body = '{"accessToken": "tok-123", "user": {"id": 7}, "scopes": ["read", "write"]}'

    local function decode(text)
      if text == body then
        return { accessToken = "tok-123", user = { id = 7 }, scopes = { "read", "write" } }
      end
      error("not json")
    end

    local function encode(value)
      if type(value[1]) == "string" then
        local parts = {}
        for _, item in ipairs(value) do
          parts[#parts + 1] = ('"%s"'):format(item)
        end
        return "[" .. table.concat(parts, ",") .. "]"
      end
      if value.id then
        return '{"id":7}'
      end
      error("cannot encode")
    end

    local opts = {
      responses = {
        signin = {
          ok = true,
          status = 200,
          version = "1.1",
          reason = "OK",
          url = "https://api.example.com/login",
          headers = {
            { name = "Content-Type", value = "application/json" },
            { name = "X-Req-Id", value = "abc" },
          },
          body = body,
          time_s = 0.1,
        },
      },
      decode = decode,
      encode = encode,
    }

    it("resolves body fields", function()
      assert.equals(
        "Bearer tok-123",
        variables.resolve("Bearer $signin.response.body.accessToken", {}, opts)
      )
    end)

    it("concatenates response refs inside quoted strings", function()
      assert.equals(
        '"Bearer tok-123"',
        variables.resolve('"Bearer $signin.response.body.accessToken"', {}, opts)
      )
      assert.equals(
        '{"content": "some value tok-123"}',
        variables.resolve('{"content": "some value $signin.response.body.accessToken"}', {}, opts)
      )
    end)

    it("matches body fields case-insensitively", function()
      assert.equals("tok-123", variables.resolve("$signin.response.body.accesstoken", {}, opts))
    end)

    it("resolves nested body fields", function()
      assert.equals("7", variables.resolve("$signin.response.body.user.id", {}, opts))
    end)

    it("returns the raw body without a field", function()
      assert.equals(body, variables.resolve("$signin.response.body", {}, opts))
    end)

    it("resolves headers case-insensitively", function()
      assert.equals(
        "application/json",
        variables.resolve("$signin.response.headers.content-type", {}, opts)
      )
      assert.equals("abc", variables.resolve("$signin.response.headers.X-Req-Id", {}, opts))
    end)

    it("resolves scalar fields", function()
      assert.equals("200", variables.resolve("$signin.response.status", {}, opts))
      assert.equals("1.1", variables.resolve("$signin.response.version", {}, opts))
      assert.equals("OK", variables.resolve("$signin.response.reason", {}, opts))
      assert.equals(
        "https://api.example.com/login",
        variables.resolve("$signin.response.url", {}, opts)
      )
    end)

    it("prefers file definitions over response refs", function()
      local defs = { ["signin.response.status"] = "local" }
      assert.equals("local", variables.resolve("$signin.response.status", defs, opts))
    end)

    it("errors when the response has not been run", function()
      local out, err = variables.resolve("Authorization: $nope.response.body.x", {}, opts)
      assert.is_nil(out)
      assert.matches("undefined response 'nope'", err)
      assert.matches("run its request first", err)
    end)

    it("errors without a responses registry", function()
      local out, err = variables.resolve("$signin.response.status", {})
      assert.is_nil(out)
      assert.matches("undefined response 'signin'", err)
    end)

    it("rejects paths without .response", function()
      local out, err = variables.resolve("$signin.body.x", {}, opts)
      assert.is_nil(out)
      assert.matches("expected 'response'", err)
    end)

    it("rejects unknown response fields", function()
      local out, err = variables.resolve("$signin.response.token", {}, opts)
      assert.is_nil(out)
      assert.matches("unknown response field", err)
    end)

    it("errors on a missing header", function()
      local out, err = variables.resolve("$signin.response.headers.Nope", {}, opts)
      assert.is_nil(out)
      assert.matches("header 'Nope' not found", err)
    end)

    it("errors on a missing body field", function()
      local out, err = variables.resolve("$signin.response.body.nope", {}, opts)
      assert.is_nil(out)
      assert.matches("field 'nope' not found", err)
    end)

    it("indexes arrays 0-based, with dot or bracket syntax", function()
      local o = {
        responses = {
          t = {
            ok = true,
            status = 200,
            headers = {},
            body = '[{"content": "first"}, {"content": "second"}]',
          },
        },
        decode = function()
          return { { content = "first" }, { content = "second" } }
        end,
        encode = encode,
      }
      assert.equals("first", variables.resolve("$t.response.body[0].content", {}, o))
      assert.equals("second", variables.resolve("$t.response.body.1.content", {}, o))
      assert.equals("second", variables.resolve("$t.response.body[1].content", {}, o))
    end)

    it("indexes nested arrays with chained brackets", function()
      local o = {
        responses = { t = { ok = true, status = 200, headers = {}, body = "[[10, 20]]" } },
        decode = function()
          return { { 10, 20 } }
        end,
        encode = encode,
      }
      assert.equals("20", variables.resolve("$t.response.body[0][1]", {}, o))
    end)

    it("falls back to numeric-string keys for objects", function()
      local o = {
        responses = { t = { ok = true, status = 200, headers = {}, body = '{"0": "zero"}' } },
        decode = function()
          return { ["0"] = "zero" }
        end,
        encode = encode,
      }
      assert.equals("zero", variables.resolve("$t.response.body.0", {}, o))
    end)

    it("errors when an array index is out of range", function()
      local o = {
        responses = { t = { ok = true, status = 200, headers = {}, body = "[]" } },
        decode = function()
          return {}
        end,
        encode = encode,
      }
      local out, err = variables.resolve("$t.response.body.5", {}, o)
      assert.is_nil(out)
      assert.matches("index 5 out of range", err)
    end)

    it("encodes JSON objects and arrays as compact JSON", function()
      assert.equals('{"id":7}', variables.resolve("$signin.response.body.user", {}, opts))
      assert.equals('["read","write"]', variables.resolve("$signin.response.body.scopes", {}, opts))
      assert.equals(
        '{"data": {"id":7}}',
        variables.resolve('{"data": $signin.response.body.user}', {}, opts)
      )
    end)

    it("errors on a JSON object when no encoder is configured", function()
      local out, err = variables.resolve("$signin.response.body.user", {}, {
        responses = opts.responses,
        decode = decode,
      })
      assert.is_nil(out)
      assert.matches("resolves to a JSON object", err)
      assert.matches("no JSON encoder", err)
    end)

    it("errors when the body is not JSON", function()
      local o = {
        responses = { signin = { ok = true, status = 200, body = "plain text" } },
        decode = decode,
      }
      local out, err = variables.resolve("$signin.response.body.x", {}, o)
      assert.is_nil(out)
      assert.matches("is not JSON", err)
    end)

    it("resolves refs through resolve_request", function()
      local request = {
        method = "GET",
        url = "https://api.example.com/me",
        headers = {
          {
            name = "Authorization",
            value = "Bearer $signin.response.body.accessToken",
          },
        },
      }
      local resolved = assert(variables.resolve_request(request, {}, opts))
      assert.equals("Bearer tok-123", resolved.headers[1].value)
    end)
  end)

  describe("$_now", function()
    local now = { year = 2026, month = 10, day = 15, hour = 14, min = 30, sec = 5 }
    local opts = { now = now }

    it("resolves to a local ISO 8601 timestamp", function()
      assert.equals("2026-10-15T14:30:05", variables.resolve("$_now", {}, opts))
      assert.equals("sent at 2026-10-15T14:30:05!", variables.resolve("sent at $_now!", {}, opts))
    end)

    it("resolves the real clock to an ISO 8601 timestamp", function()
      local out = assert(variables.resolve("$_now", {}))
      assert.matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d$", out)
    end)

    it("resolves zero-padded fields", function()
      assert.equals("2026", variables.resolve("$_now.year", {}, opts))
      assert.equals("10", variables.resolve("$_now.month", {}, opts))
      assert.equals("15", variables.resolve("$_now.day", {}, opts))
      assert.equals("14", variables.resolve("$_now.hour", {}, opts))
      assert.equals("30", variables.resolve("$_now.minute", {}, opts))
      assert.equals("05", variables.resolve("$_now.second", {}, opts))
    end)

    it("zero-pads single-digit components", function()
      local o = { now = { year = 2026, month = 3, day = 5, hour = 7, min = 6, sec = 5 } }
      assert.equals("2026-03-05T07:06:05", variables.resolve("$_now", {}, o))
      assert.equals("03", variables.resolve("$_now.month", {}, o))
      assert.equals("05", variables.resolve("$_now.day", {}, o))
      assert.equals("07", variables.resolve("$_now.hour", {}, o))
      assert.equals("06", variables.resolve("$_now.minute", {}, o))
      assert.equals("05", variables.resolve("$_now.second", {}, o))
    end)

    it("add and sub resolve to the full timestamp", function()
      assert.equals("2026-10-15T18:30:05", variables.resolve("$_now.hour.add(4)", {}, opts))
      assert.equals("2026-10-15T07:30:05", variables.resolve("$_now.hour.sub(7)", {}, opts))
      assert.equals("2026-10-15T14:32:05", variables.resolve("$_now.minute.add(2)", {}, opts))
      assert.equals("2026-10-15T14:31:05", variables.resolve("$_now.second.add(60)", {}, opts))
      assert.equals("2026-10-16T14:30:05", variables.resolve("$_now.day.add(1)", {}, opts))
      assert.equals("2026-10-16T00:30:05", variables.resolve("$_now.hour.add(10)", {}, opts))
      assert.equals("2026-11-15T14:30:05", variables.resolve("$_now.month.add(1)", {}, opts))
      assert.equals("2025-10-15T14:30:05", variables.resolve("$_now.year.sub(1)", {}, opts))
      assert.equals("2026-10-15T14:30:05", variables.resolve("$_now.hour.add(0)", {}, opts))
      assert.equals("2026-10-15T14:30:05", variables.resolve("$_now.second.sub(0)", {}, opts))
    end)

    it("rolls over across day, month and year boundaries", function()
      local o = { now = { year = 2026, month = 12, day = 31, hour = 23, min = 59, sec = 59 } }
      assert.equals("2027-01-01T00:59:59", variables.resolve("$_now.hour.add(1)", {}, o))
      assert.equals("2027-01-01T00:00:59", variables.resolve("$_now.minute.add(1)", {}, o))
      assert.equals("2027-01-01T00:00:00", variables.resolve("$_now.second.add(1)", {}, o))
      assert.equals("2027-01-01T23:59:59", variables.resolve("$_now.day.add(1)", {}, o))
      assert.equals("2027-01-31T23:59:59", variables.resolve("$_now.month.add(1)", {}, o))
    end)

    it("rolls backwards across boundaries", function()
      local o = { now = { year = 2026, month = 10, day = 5, hour = 3, min = 0, sec = 0 } }
      assert.equals("2026-10-04T20:00:00", variables.resolve("$_now.hour.sub(7)", {}, o))
      assert.equals("2026-09-25T14:30:05", variables.resolve("$_now.day.sub(20)", {}, opts))
      assert.equals("2025-11-15T14:30:05", variables.resolve("$_now.month.sub(11)", {}, opts))
    end)

    it("clamps the day when a shift overflows the target month", function()
      local jan = { now = { year = 2026, month = 1, day = 31, hour = 12, min = 0, sec = 0 } }
      assert.equals("2026-02-28T12:00:00", variables.resolve("$_now.month.add(1)", {}, jan))

      local leap_jan = { now = { year = 2028, month = 1, day = 31, hour = 12, min = 0, sec = 0 } }
      assert.equals("2028-02-29T12:00:00", variables.resolve("$_now.month.add(1)", {}, leap_jan))

      local leap_day = { now = { year = 2028, month = 2, day = 29, hour = 12, min = 0, sec = 0 } }
      assert.equals("2029-02-28T12:00:00", variables.resolve("$_now.year.add(1)", {}, leap_day))
    end)

    it("does not touch parens outside plugin globals", function()
      assert.equals("v(1)", variables.resolve("$host(1)", { host = "v" }))
      assert.equals("v(a(b))", variables.resolve("$host(a(b))", { host = "v" }))
      assert.equals("(v)", variables.resolve("($host)", { host = "v" }))
    end)

    it("keeps the $$ escape working", function()
      assert.equals("$_now", variables.resolve("$$_now", {}))
      assert.equals("x$_now", variables.resolve("x$$_now", {}))
    end)

    it("errors on unknown fields", function()
      local out, err = variables.resolve("$_now.foo", {}, opts)
      assert.is_nil(out)
      assert.matches("unknown '$_now' field 'foo'", err)

      out, err = variables.resolve("$_now.foo.add(1)", {}, opts)
      assert.is_nil(out)
      assert.matches("unknown '$_now' field 'foo'", err)
    end)

    it("errors on malformed references", function()
      local cases = {
        "$_now(4)",
        "$_now.hour(4)",
        "$_now.hour.add",
        "$_now.hour.add()",
        "$_now.hour.add(x)",
        "$_now.hour.add(1.5)",
        "$_now.hour.add (4)",
        "$_now.hour.foo",
        "$_now.year.month",
      }
      for _, case in ipairs(cases) do
        local out, err = variables.resolve(case, {}, opts)
        assert(out == nil, ("%s: expected an error, got %q"):format(case, tostring(out)))
        assert(
          type(err) == "string" and err:find("invalid '$_now' reference", 1, true),
          ("%s: unexpected error %q"):format(case, tostring(err))
        )
      end
    end)

    it("errors on unknown plugin globals", function()
      local out, err = variables.resolve("$_nope", {}, opts)
      assert.is_nil(out)
      assert.matches("undefined variable '_nope'", err)
      assert.matches("prefix is reserved", err)
    end)

    it("still resolves $_-rooted response refs (tags may start with _)", function()
      local o = {
        responses = {
          _api = { ok = true, status = 200, headers = {}, body = '{"ok":true}' },
        },
        decode = function()
          return { ok = true }
        end,
        encode = function()
          return '{"ok":true}'
        end,
      }
      assert.equals("true", variables.resolve("$_api.response.body.ok", {}, o))
    end)

    it("shares one snapshot across url, headers and body", function()
      local request = {
        method = "POST",
        url = "https://example.com/?ts=$_now",
        headers = { { name = "X-Sent", value = "$_now" } },
        body = '{"sentAt": "$_now"}',
      }
      local resolved = assert(variables.resolve_request(request, {}, opts))
      assert.equals("https://example.com/?ts=2026-10-15T14:30:05", resolved.url)
      assert.equals("2026-10-15T14:30:05", resolved.headers[1].value)
      assert.equals('{"sentAt": "2026-10-15T14:30:05"}', resolved.body)
    end)

    it("snapshots the real clock once per request", function()
      local request = {
        method = "POST",
        url = "$_now",
        headers = { { name = "X-Sent", value = "$_now" } },
        body = "$_now",
      }
      local resolved = assert(variables.resolve_request(request, {}))
      assert.equals(resolved.url, resolved.headers[1].value)
      assert.equals(resolved.url, resolved.body)
    end)
  end)

  describe("reserved $_ definitions", function()
    it("rejects definitions prefixed with _", function()
      local out, err = variables.resolve("$x", { _now = "nope", x = "1" })
      assert.is_nil(out)
      assert.matches("'$_' prefix is reserved", err)
      assert.matches("remove the '_now' definition", err)
    end)

    it("cannot shadow a plugin global", function()
      local out, err = variables.resolve("$_now", { _now = "nope" })
      assert.is_nil(out)
      assert.matches("'$_' prefix is reserved", err)
    end)

    it("rejects them through resolve_request", function()
      local request = { method = "GET", url = "https://example.com", headers = {} }
      local out, err = variables.resolve_request(request, { _token = "x" })
      assert.is_nil(out)
      assert.matches("'$_' prefix is reserved", err)
    end)

    it("exposes check_defs for callers", function()
      assert.is_nil(variables.check_defs({ host = "h", ["a.b"] = "c" }))
      assert.is_nil(variables.check_defs({}))
      local err = variables.check_defs({ _private = "x" })
      assert.matches("'$_' prefix is reserved", err)
    end)
  end)
end)

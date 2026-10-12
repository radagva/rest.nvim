local curl = require("rest.curl")

describe("curl.parse", function()
  it("parses a bare GET", function()
    local req = assert(curl.parse("curl https://example.com/health"))
    assert.equals("GET", req.method)
    assert.equals("https://example.com/health", req.url)
    assert.same({}, req.headers)
    assert.is_nil(req.body)
  end)

  it("parses a DevTools-style multiline command with quotes", function()
    local req = assert(curl.parse(table.concat({
      "curl 'https://api.example.com/users?active=1' \\",
      "  -H 'Accept: application/json' \\",
      '  -H "X-Trace: 42" \\',
      '  --data-raw \'{"name": "Ada"}\' \\',
      "  --compressed",
    }, "\n")))
    assert.equals("POST", req.method)
    assert.equals("https://api.example.com/users?active=1", req.url)
    assert.equals(2, #req.headers)
    assert.equals("Accept", req.headers[1].name)
    assert.equals("application/json", req.headers[1].value)
    assert.equals("X-Trace", req.headers[2].name)
    assert.equals("42", req.headers[2].value)
    assert.equals('{"name": "Ada"}', req.body)
  end)

  it("honors an explicit method and infers POST from data", function()
    local req = assert(curl.parse("curl -X PUT https://example.com/a -d x=1"))
    assert.equals("PUT", req.method)
    assert.equals("x=1", req.body)

    req = assert(curl.parse("curl https://example.com/a -d x=1"))
    assert.equals("POST", req.method)
  end)

  it("joins repeated -d with & as curl does", function()
    local req = assert(curl.parse("curl -d a=1 -d b=2 https://example.com/q"))
    assert.equals("a=1&b=2", req.body)
  end)

  it("reads the URL from --url or after --", function()
    assert.equals(
      "https://example.com/a",
      assert(curl.parse("curl --url https://example.com/a")).url
    )
    assert.equals(
      "https://example.com/b",
      assert(curl.parse("curl -sS -- https://example.com/b")).url
    )
  end)

  it("maps -A, -b, -e and -u to headers", function()
    local req = assert(
      curl.parse("curl -A bot -b 'sid=1' -e https://ref.example -u user:pass https://x.example")
    )
    local got = {}
    for _, h in ipairs(req.headers) do
      got[h.name] = h.value
    end
    assert.equals("bot", got["User-Agent"])
    assert.equals("sid=1", got.Cookie)
    assert.equals("https://ref.example", got.Referer)
    assert.equals("Basic dXNlcjpwYXNz", got.Authorization)
  end)

  it("adds implied headers for --json", function()
    local req = assert(curl.parse("curl --json '{\"a\":1}' https://x.example"))
    assert.equals("POST", req.method)
    assert.equals('{"a":1}', req.body)
    local got = {}
    for _, h in ipairs(req.headers) do
      got[h.name] = h.value
    end
    assert.equals("application/json", got["Content-Type"])
    assert.equals("application/json", got.Accept)
  end)

  it("maps -I to HEAD, -G data to the query, and skips transport flags", function()
    local req = assert(curl.parse("curl -I https://x.example"))
    assert.equals("HEAD", req.method)

    req = assert(curl.parse("curl -G -d q=rest https://x.example/search -m 30 -L -k -sS"))
    assert.equals("GET", req.method)
    assert.equals("https://x.example/search?q=rest", req.url)
    assert.is_nil(req.body)
  end)

  it("drops content-length headers", function()
    local req = assert(curl.parse("curl -H 'Content-Length: 3' https://x.example"))
    assert.same({}, req.headers)
  end)

  it("rejects non-curl input, headerless flags and missing URLs", function()
    local req, err = curl.parse("wget https://x.example")
    assert.is_nil(req)
    assert.matches("not a curl command", err)

    req, err = curl.parse("curl https://x.example -H oops")
    assert.is_nil(req)
    assert.matches("bad header", err)

    req, err = curl.parse("curl -sS -L")
    assert.is_nil(req)
    assert.matches("no URL found", err)

    req, err = curl.parse("   ")
    assert.is_nil(req)
    assert.matches("empty command", err)
  end)
end)

describe("curl.build", function()
  it("emits a single-line, shell-quoted command", function()
    local cmd = curl.build({
      method = "POST",
      url = "https://api.example.com/users",
      headers = { { name = "Content-Type", value = "application/json" } },
      body = '{"name": "Ada"}',
    })
    assert.equals(
      "curl -X POST 'https://api.example.com/users' "
        .. "-H 'Content-Type: application/json' "
        .. '--data-binary \'{"name": "Ada"}\'',
      cmd
    )
  end)

  it("escapes single quotes in values", function()
    local cmd = curl.build({ method = "GET", url = "https://x.example/a'b" })
    assert.equals("curl -X GET 'https://x.example/a'\\''b'", cmd)
  end)

  it("skips content-length headers", function()
    local cmd = curl.build({
      method = "POST",
      url = "https://x.example",
      headers = { { name = "Content-Length", value = "3" } },
      body = "abc",
    })
    assert.equals("curl -X POST 'https://x.example' --data-binary 'abc'", cmd)
  end)

  it("round-trips through curl.parse", function()
    local original = {
      method = "PUT",
      url = "https://api.example.com/items?id=7",
      headers = {
        { name = "Accept", value = "application/json" },
        { name = "X-Note", value = "it's quoted" },
      },
      body = '{"a": "b\\c"}',
    }
    local req = assert(curl.parse(curl.build(original)))
    assert.equals(original.method, req.method)
    assert.equals(original.url, req.url)
    assert.same(original.headers, req.headers)
    assert.equals(original.body, req.body)
  end)
end)

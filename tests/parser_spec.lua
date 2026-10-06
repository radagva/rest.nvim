local parser = require("rest.parser")

describe("parser", function()
  it("parses a single GET request with headers and body", function()
    local text = table.concat({
      "GET https://example.com/api/users HTTP/1.1",
      "Accept: application/json",
      "X-Token: abc",
      "",
      '{"page": 1}',
    }, "\n")

    local doc = assert(parser.parse(text))
    assert.same({}, doc.definitions)
    assert.equals(1, #doc.requests)

    local req = doc.requests[1]
    assert.equals("GET", req.method)
    assert.equals("https://example.com/api/users", req.url)
    assert.equals("1.1", req.version)
    assert.equals(2, #req.headers)
    assert.equals("Accept", req.headers[1].name)
    assert.equals("application/json", req.headers[1].value)
    assert.equals("X-Token", req.headers[2].name)
    assert.equals("abc", req.headers[2].value)
    assert.equals('{"page": 1}', req.body)
    assert.equals(1, req.start_line)
    assert.equals(5, req.end_line)
  end)

  it("defaults the version when the request line omits it", function()
    local doc = assert(parser.parse("POST https://example.com/x"))
    assert.equals("1.1", doc.requests[1].version)
    assert.is_nil(doc.requests[1].body)
    assert.equals(1, doc.requests[1].end_line)
  end)

  it("splits requests on ### separators and captures names", function()
    local text = table.concat({
      "### Get users",
      "GET https://example.com/users",
      "",
      "### Create user",
      "POST https://example.com/users",
      "Content-Type: application/json",
      "",
      '{"name": "ann"}',
    }, "\n")

    local doc = assert(parser.parse(text))
    assert.equals(2, #doc.requests)
    assert.equals("Get users", doc.requests[1].name)
    assert.equals("Create user", doc.requests[2].name)
    assert.equals("GET", doc.requests[1].method)
    assert.equals("POST", doc.requests[2].method)
    assert.equals("ann", doc.requests[2].body:match('"name":%s*"(%a+)"'))
    assert.equals(2, doc.requests[1].start_line)
    assert.equals(2, doc.requests[1].end_line)
    assert.equals(5, doc.requests[2].start_line)
  end)

  it("collects @var definitions from preambles, not from requests", function()
    local text = table.concat({
      "@host = https://api.example.com",
      "@token = secret",
      "# a comment",
      "### login",
      "POST {{host}}/login",
      "Authorization: Bearer {{token}}",
      "",
      '{"user": "root"}',
    }, "\n")

    local doc = assert(parser.parse(text))
    assert.same({ host = "https://api.example.com", token = "secret" }, doc.definitions)
    assert.equals(1, #doc.requests)
    assert.equals("POST", doc.requests[1].method)
    assert.equals("login", doc.requests[1].name)
    assert.equals("Bearer {{token}}", doc.requests[1].headers[1].value)
  end)

  it("keeps @var-looking lines inside bodies as body content", function()
    local text = table.concat({
      "POST https://example.com/x",
      "",
      "@notadef = stays in body",
    }, "\n")

    local doc = assert(parser.parse(text))
    assert.same({}, doc.definitions)
    assert.equals("@notadef = stays in body", doc.requests[1].body)
  end)

  it("returns an error with a line number for a malformed request line", function()
    local doc, err = parser.parse("### split\nnot a request line")
    assert.is_nil(doc)
    assert.matches("line 2", err)
    assert.matches("expected request line", err)
  end)

  it("returns an error for garbage in the header section", function()
    local doc, err = parser.parse("GET https://example.com\nbad header line")
    assert.is_nil(doc)
    assert.matches("line 2", err)
  end)

  it("skips comment lines between headers", function()
    local text = table.concat({
      "GET https://example.com",
      "# note about auth",
      "Authorization: Bearer x",
      "",
    }, "\n")
    local doc = assert(parser.parse(text))
    assert.equals(1, #doc.requests)
    assert.equals(1, #doc.requests[1].headers)
    assert.is_nil(doc.requests[1].body)
  end)

  it("handles CRLF line endings", function()
    local text = "GET https://example.com\r\nAccept: */*\r\n\r\nbody"
    local doc = assert(parser.parse(text))
    assert.equals("Accept", doc.requests[1].headers[1].name)
    assert.equals("body", doc.requests[1].body)
    assert.equals(4, doc.requests[1].end_line)
  end)

  it("parses an empty document", function()
    local doc = assert(parser.parse(""))
    assert.same({}, doc.definitions)
    assert.same({}, doc.requests)
  end)

  it("resolves the request at the cursor, falling back to the next one", function()
    local text = table.concat({
      "@host = https://x",
      "### one",
      "GET {{host}}/one",
      "",
      "### two",
      "GET {{host}}/two",
    }, "\n")
    local doc = assert(parser.parse(text))
    local requests = doc.requests

    assert.equals("one", parser.request_at(requests, 3).name)
    assert.equals("two", parser.request_at(requests, 4).name) -- blank line after one
    assert.equals("two", parser.request_at(requests, 5).name) -- on the separator
    assert.equals("one", parser.request_at(requests, 1).name) -- above both
    assert.is_nil(parser.request_at(requests, 99))
  end)
end)

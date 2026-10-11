local parser = require("rest.parser")
local list = require("rest.list")

local TEXT = table.concat({
  "GET https://example.com/health",
  "",
  "### list users",
  "GET https://example.com/users",
  "",
  "###",
  "@name login",
  "POST https://example.com/login",
}, "\n")

local function entries_for(text, files, width)
  local doc = assert(parser.parse(text))
  return list.entries(files or {
    { file = "api.http", abs = "/tmp/api.http", requests = doc.requests },
  }, width)
end

describe("list", function()
  it("labels requests from ### name, falling back to @name tag and then the url", function()
    local entries = entries_for(TEXT)
    assert.equals(3, #entries)
    assert.equals("https://example.com/health", entries[1].label)
    assert.equals("list users", entries[2].label)
    assert.equals("login", entries[3].label)
  end)

  it("keeps method, file, absolute path and request line per entry", function()
    local entries = entries_for(TEXT)
    assert.equals("GET", entries[1].method)
    assert.equals("GET", entries[2].method)
    assert.equals("POST", entries[3].method)
    for _, entry in ipairs(entries) do
      assert.equals("api.http", entry.file)
      assert.equals("/tmp/api.http", entry.abs)
    end
    assert.equals(1, entries[1].line)
    assert.equals(4, entries[2].line)
    assert.equals(8, entries[3].line)
  end)

  it("builds aligned display rows with padded method and label columns", function()
    local entries = entries_for(TEXT)
    assert.equals("GET   https://example.com/health  api.http", entries[1].display)
    assert.equals("GET   list users" .. string.rep(" ", 16) .. "  api.http", entries[2].display)
    assert.equals("POST  login" .. string.rep(" ", 21) .. "  api.http", entries[3].display)
  end)

  it("keeps the order of files and requests", function()
    local doc1 = assert(parser.parse("GET https://example.com/a\n\n###\nGET https://example.com/b"))
    local doc2 = assert(parser.parse("POST https://example.com/c"))
    local entries = list.entries({
      { file = "one.http", abs = "/tmp/one.http", requests = doc1.requests },
      { file = "two.http", abs = "/tmp/two.http", requests = doc2.requests },
    })
    assert.equals(3, #entries)
    assert.equals("one.http", entries[1].file)
    assert.equals("one.http", entries[2].file)
    assert.equals("two.http", entries[3].file)
    assert.equals("/tmp/two.http", entries[3].abs)
    assert.equals("POST", entries[3].method)
  end)

  it("pads with a custom display width function", function()
    local wide = "日本語" -- 9 bytes, 6 display columns
    local doc = assert(parser.parse(table.concat({
      "### " .. wide,
      "GET https://example.com/a",
      "",
      "### ascii",
      "GET https://example.com/b",
    }, "\n")))
    local entries = list.entries(
      { { file = "api.http", abs = "/tmp/api.http", requests = doc.requests } },
      function(text)
        return text == wide and 6 or #text
      end
    )
    assert.equals("GET  " .. wide .. "  api.http", entries[1].display)
    assert.equals("GET  ascii   api.http", entries[2].display)
  end)

  it("returns no entries for files without requests", function()
    assert.same({}, list.entries({ { file = "a.http", abs = "/tmp/a.http", requests = {} } }))
  end)
end)

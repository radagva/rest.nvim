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

  it("keeps the request's last line, including headers and body", function()
    local entries = entries_for(table.concat({
      "GET https://example.com/a",
      "Accept: application/json",
      "",
      '{"page": 1}',
      "",
      "### with body",
      "POST https://example.com/b",
      "Content-Type: application/json",
      "",
      "{}",
    }, "\n"))
    assert.equals(1, entries[1].line)
    assert.equals(4, entries[1].end_line)
    assert.equals(7, entries[2].line)
    assert.equals(10, entries[2].end_line)
    -- requests without headers or body end on their request line
    local bare = entries_for(TEXT)
    assert.equals(1, bare[1].end_line)
    assert.equals(4, bare[2].end_line)
    assert.equals(8, bare[3].end_line)
  end)

  it("returns the request's source lines for picker previews", function()
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write(table.concat({
      "GET https://example.com/a",
      "Accept: application/json",
      "",
      '{"page": 1}',
    }, "\n"))
    f:close()

    local saved = _G.vim
    _G.vim = {
      fn = {
        getbufinfo = function()
          return {}
        end,
        readfile = function(name)
          local file = io.open(name, "r")
          if not file then
            error("E484: Cannot open file")
          end
          local lines = {}
          for line in file:lines() do
            lines[#lines + 1] = line
          end
          file:close()
          return lines
        end,
      },
      fs = {
        normalize = function(p)
          return p
        end,
      },
    }

    local got = {}
    got.block = list.request_lines({ abs = path, line = 1, end_line = 4 })
    got.clamped = list.request_lines({ abs = path, line = 4, end_line = 99 })
    got.gone = list.request_lines({ abs = path, line = 99, end_line = 100 })
    got.missing = list.request_lines({ abs = path .. ".missing", line = 1, end_line = 1 })

    -- a loaded buffer wins over the file on disk
    _G.vim.fn.getbufinfo = function()
      return { { bufnr = 7 } }
    end
    _G.vim.api = {
      nvim_buf_get_name = function()
        return path
      end,
      nvim_buf_get_lines = function()
        return { "EDITED" }
      end,
    }
    got.buffer = list.request_lines({ abs = path, line = 1, end_line = 4 })
    _G.vim = saved
    os.remove(path)

    assert.same(
      { "GET https://example.com/a", "Accept: application/json", "", '{"page": 1}' },
      got.block
    )
    assert.same({ '{"page": 1}' }, got.clamped)
    assert.same({}, got.gone)
    assert.same({}, got.missing)
    assert.same({ "EDITED" }, got.buffer)
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

  it("maps methods to RestMethod highlight groups", function()
    assert.equals("RestMethodGet", list.method_hl("GET"))
    assert.equals("RestMethodPost", list.method_hl("POST"))
    assert.equals("RestMethodDelete", list.method_hl("DELETE"))
    assert.equals("RestMethodGet", list.method_hl("get"))
    assert.equals("RestMethod", list.method_hl("PURGE"))
    assert.equals("RestMethod", list.method_hl(nil))
  end)

  it("splits rows into a highlighted method chunk and the rest", function()
    local entries = entries_for(TEXT)
    for _, entry in ipairs(entries) do
      assert.equals(2, #entry.chunks)
      assert.equals(entry.display, entry.chunks[1][1] .. entry.chunks[2][1])
      assert.equals(entry.method_hl, entry.chunks[1][2])
      assert.is_nil(entry.chunks[2][2])
    end
    assert.equals("GET ", entries[1].chunks[1][1])
    assert.equals("RestMethodGet", entries[1].chunks[1][2])
    assert.equals("POST", entries[3].chunks[1][1])
    assert.equals("RestMethodPost", entries[3].chunks[1][2])
  end)

  it("returns no entries for files without requests", function()
    assert.same({}, list.entries({ { file = "a.http", abs = "/tmp/a.http", requests = {} } }))
  end)
end)

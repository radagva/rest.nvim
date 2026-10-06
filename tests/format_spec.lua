local format = require("rest.format")

describe("format", function()
  describe("find_jq", function()
    it("returns nil when jq is not on the given path", function()
      assert.is_nil(format.find_jq("/nonexistent-dir"))
    end)

    it("finds a jq binary on the given path", function()
      local found = format.find_jq("tests/fixtures/bin")
      assert.is_string(found)
      assert.matches("bin/jq$", found)
    end)

    it("returns nil for an empty path", function()
      assert.is_nil(format.find_jq(""))
    end)
  end)

  describe("is_json", function()
    it("detects objects and arrays", function()
      assert.is_true(format.is_json('{"a": 1}'))
      assert.is_true(format.is_json("  [1, 2]"))
      assert.is_false(format.is_json("plain text"))
      assert.is_false(format.is_json(""))
      assert.is_false(format.is_json(nil))
    end)
  end)

  describe("render", function()
    it("renders nested values with 2-space indent and sorted keys", function()
      local value = { z = 1, a = { "x", "y" }, flag = true }
      assert.equals(
        '{\n  "a": [\n    "x",\n    "y"\n  ],\n  "flag": true,\n  "z": 1\n}',
        format.render(value)
      )
    end)

    it("escapes strings", function()
      assert.equals('"a\\"b\\nc"', format.render('a"b\nc'))
    end)

    it("renders an empty table as {}", function()
      assert.equals("{}", format.render({}))
    end)

    it("renders nil as null", function()
      assert.equals("null", format.render(nil))
    end)
  end)

  describe("pretty", function()
    it("uses jq when available", function()
      local body = '{"b": 2, "a": 1}'
      local out, tool = format.pretty(body, { jq_path = "tests/fixtures/bin/jq" })
      assert.equals("jq", tool)
      assert.matches('"a": 1', out)
      assert.matches('"b": 2', out)
    end)

    it("falls back to the injected decoder", function()
      local decode = function()
        return { hello = "world" }
      end
      local out, tool =
        format.pretty('{"hello": "world"}', { path = "/nonexistent-dir", decode = decode })
      assert.equals("lua", tool)
      assert.equals('{\n  "hello": "world"\n}', out)
    end)

    it("does not use jq when the body is not JSON", function()
      local out, reason = format.pretty("plain text", { jq_path = "tests/fixtures/bin/jq" })
      assert.is_nil(out)
      assert.equals("not JSON", reason)
    end)

    it("fails when there is no jq and no decoder", function()
      local out, reason = format.pretty('{"a": 1}', { path = "/nonexistent-dir" })
      assert.is_nil(out)
      assert.equals("JSON decode failed", reason)
    end)
  end)

  describe("detect_ft", function()
    it("maps content types to filetypes", function()
      assert.equals("json", format.detect_ft("application/json", ""))
      assert.equals("json", format.detect_ft("application/json; charset=utf-8", ""))
      assert.equals("json", format.detect_ft("application/vnd.api+json", ""))
      assert.equals("html", format.detect_ft("text/html; charset=UTF-8", ""))
      assert.equals("html", format.detect_ft("application/xhtml+xml", ""))
      assert.equals("xml", format.detect_ft("application/xml", ""))
      assert.equals("xml", format.detect_ft("text/xml", ""))
      assert.equals("javascript", format.detect_ft("text/javascript", ""))
      assert.equals("javascript", format.detect_ft("application/javascript", ""))
      assert.equals("css", format.detect_ft("text/css", ""))
      assert.equals("yaml", format.detect_ft("application/yaml", ""))
      assert.equals("yaml", format.detect_ft("text/yaml", ""))
    end)

    it("is case-insensitive and trims whitespace", function()
      assert.equals("json", format.detect_ft("  Application/JSON ; Charset=UTF-8", ""))
    end)

    it("sniffs the body when content type is missing or text/plain", function()
      assert.equals("json", format.detect_ft(nil, '{"a": 1}'))
      assert.equals("json", format.detect_ft("text/plain", "[1, 2]"))
      assert.equals("html", format.detect_ft("", "<html><body/></html>"))
      assert.equals("xml", format.detect_ft("", '<?xml version="1.0"?><a/>'))
      assert.is_nil(format.detect_ft("", "plain text"))
    end)

    it("trusts unknown content types over the body", function()
      assert.is_nil(format.detect_ft("application/octet-stream", '{"a": 1}'))
    end)
  end)
end)

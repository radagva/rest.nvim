local transport = require("rest.transport")

describe("transport", function()
  describe("parse_header_dump", function()
    it("parses a CRLF header dump without keeping the carriage return", function()
      local dump = table.concat({
        "HTTP/1.1 400 Bad Request",
        "Content-Type: application/json",
        "X-Api: v1",
        "",
      }, "\r\n") .. "\r\n"

      local version, status, reason, headers = transport.parse_header_dump(dump)
      assert.equals("1.1", version)
      assert.equals(400, status)
      assert.equals("Bad Request", reason)
      assert.is_nil(reason:find("\r"))
      assert.equals(2, #headers)
      assert.equals("Content-Type", headers[1].name)
      assert.equals("application/json", headers[1].value)
      assert.is_nil(headers[1].value:find("\r"))
    end)

    it("uses the last status block when redirects dumped several", function()
      local dump = table.concat({
        "HTTP/1.1 301 Moved Permanently",
        "Location: /new",
        "",
        "HTTP/2 200",
        "content-type: text/html",
        "",
      }, "\r\n")

      local version, status, reason, headers = transport.parse_header_dump(dump)
      assert.equals("2", version)
      assert.equals(200, status)
      assert.equals("", reason)
      assert.equals(1, #headers)
      assert.equals("text/html", headers[1].value)
    end)

    it("returns nil for an empty or headerless dump", function()
      assert.is_nil(transport.parse_header_dump(""))
      assert.is_nil(transport.parse_header_dump(nil))
      assert.is_nil(transport.parse_header_dump("garbage without status line"))
    end)
  end)

  describe("build_curl_args", function()
    local req = {
      method = "POST",
      url = "https://example.com/auth",
      headers = {
        { name = "Content-Type", value = "application/json" },
        { name = "Content-Length", value = "17" },
      },
      body = '{"a": 1}',
    }

    it("builds argv with method, headers, files and url after --", function()
      local args = transport.build_curl_args(req, {
        url = req.url,
        body_in = "/tmp/b",
        header_out = "/tmp/h",
        body_out = "/tmp/o",
        timeout_s = 5,
        follow_redirects = true,
      })
      local joined = table.concat(args, " ")
      assert.matches("curl %-sS %-X POST", joined)
      assert.matches(" %-L ", joined)
      assert.matches("-m 5", joined, 1, true)
      assert.matches("Content%-Type: application/json", joined)
      assert.is_nil(joined:find("Content%-Length"))
      assert.matches("@/tmp/b", joined, 1, true)
      assert.matches("%-D /tmp/h", joined)
      assert.matches("%-o /tmp/o", joined)
      assert.equals("https://example.com/auth", args[#args])
      assert.equals("--", args[#args - 1])
    end)

    it("omits the body flag for GET requests", function()
      local args = transport.build_curl_args({ method = "GET", url = "https://x" }, {
        url = "https://x",
        body_in = "/tmp/b",
        header_out = "/tmp/h",
        body_out = "/tmp/o",
      })
      local joined = table.concat(args, " ")
      assert.is_nil(joined:find("@/tmp/b", 1, true))
    end)
  end)

  describe("resolve_url", function()
    it("keeps absolute urls", function()
      assert.equals("https://a/b", transport.resolve_url("https://a/b", "https://c"))
    end)

    it("joins relative urls against base_url", function()
      assert.equals("https://a/api/x", transport.resolve_url("/api/x", "https://a/"))
      assert.equals("https://a/api/x", transport.resolve_url("api/x", "https://a"))
    end)

    it("fails on relative urls without a base", function()
      local url, err = transport.resolve_url("/api", nil)
      assert.is_nil(url)
      assert.matches("base_url", err)
    end)
  end)
end)

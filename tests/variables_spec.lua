local variables = require("rest.variables")

describe("variables", function()
  it("substitutes placeholders", function()
    assert.equals(
      "https://api.example.com/users",
      variables.resolve("{{host}}/users", { host = "https://api.example.com" })
    )
  end)

  it("substitutes every occurrence and tolerates inner spaces", function()
    local out = variables.resolve("{{a}} and {{ a }} and {{a}}", { a = "x" })
    assert.equals("x and x and x", out)
  end)

  it("fails on an undefined variable", function()
    local out, err = variables.resolve("{{missing}}", {})
    assert.is_nil(out)
    assert.matches("undefined variable 'missing'", err)
  end)

  it("passes text without placeholders unchanged", function()
    assert.equals("plain text", variables.resolve("plain text", {}))
    assert.equals("", variables.resolve("", {}))
  end)

  it("accepts empty definitions", function()
    assert.equals("x=", variables.resolve("x={{e}}", { e = "" }))
  end)

  it("resolves a full request", function()
    local request = {
      method = "POST",
      url = "{{host}}/login",
      headers = { { name = "Authorization", value = "Bearer {{token}}" } },
      body = '{"user": "{{user}}"}',
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
      url = "{{host}}/x",
      headers = { { name = "X-Tok", value = "{{nope}}" } },
    }
    local out, err = variables.resolve_request(request, { host = "https://x" })
    assert.is_nil(out)
    assert.matches("header 'X%-Tok'", err)
  end)
end)

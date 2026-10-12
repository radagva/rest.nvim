local env = require("rest.env")

describe("env.normalize", function()
  it("normalizes a valid document", function()
    local state = assert(env.normalize({
      default = "dev",
      environments = {
        dev = { host = "http://localhost:8000", token = "abc", retries = 3, verbose = true },
        prod = { host = "https://api.example.com" },
      },
      ignored = "extra keys are fine",
    }))
    assert.equals("dev", state.default)
    assert.same(
      { host = "http://localhost:8000", token = "abc", retries = 3, verbose = true },
      state.environments.dev
    )
    assert.same({ host = "https://api.example.com" }, state.environments.prod)
  end)

  it("accepts a document without a default", function()
    local state = assert(env.normalize({ environments = { dev = { a = "1" } } }))
    assert.is_nil(state.default)
  end)

  it("rejects non-objects and missing environments", function()
    local state, err = env.normalize("nope")
    assert.is_nil(state)
    assert.matches("expected an object", err)

    state, err = env.normalize({})
    assert.is_nil(state)
    assert.matches('missing the "environments" object', err)
  end)

  it("rejects a bad default", function()
    local state, err = env.normalize({ default = 7, environments = { dev = {} } })
    assert.is_nil(state)
    assert.matches('"default" must be a string', err)

    state, err = env.normalize({ default = "staging", environments = { dev = {} } })
    assert.is_nil(state)
    assert.matches('default environment "staging" is not defined', err)
  end)

  it("rejects non-object environments and non-scalar variables", function()
    local state, err = env.normalize({ environments = { dev = "oops" } })
    assert.is_nil(state)
    assert.matches('environment "dev" must be an object', err)

    state, err = env.normalize({ environments = { dev = { host = { "nested" } } } })
    assert.is_nil(state)
    assert.matches("dev%.host: expected a string, number or boolean", err)
  end)

  it("rejects empty variable names", function()
    local state, err = env.normalize({ environments = { dev = { [""] = "x" } } })
    assert.is_nil(state)
    assert.matches("variable names must be non%-empty", err)
  end)
end)

describe("env.names and env.vars", function()
  local state = assert(env.normalize({
    default = "prod",
    environments = { prod = { a = "1" }, dev = { b = "2" } },
  }))

  it("lists names sorted", function()
    assert.same({ "dev", "prod" }, env.names(state))
  end)

  it("returns vars for a known name and nil otherwise", function()
    assert.same({ a = "1" }, env.vars(state, "prod"))
    assert.is_nil(env.vars(state, "staging"))
    assert.is_nil(env.vars(state, nil))
  end)
end)

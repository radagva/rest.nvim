local M = {}

local INVALID = "rest-env.json: %s"

---Normalize a decoded `rest-env.json` document.
---
---Expected shape: `{ "default": <name>, "environments": { <name>: { <var>:
---<string|number|boolean> } } }`. Extra top-level keys are ignored.
---Returns `{ default = <name|nil>, environments = {...} }` or `nil, err`.
function M.normalize(doc)
  if type(doc) ~= "table" then
    return nil, INVALID:format(("expected an object, got %s"):format(type(doc)))
  end
  if type(doc.environments) ~= "table" then
    return nil, INVALID:format('missing the "environments" object')
  end
  if doc.default ~= nil and type(doc.default) ~= "string" then
    return nil, INVALID:format('"default" must be a string')
  end

  local environments = {}
  for name, vars in pairs(doc.environments) do
    if type(name) ~= "string" or name == "" then
      return nil, INVALID:format("environment names must be non-empty strings")
    end
    if type(vars) ~= "table" then
      return nil, INVALID:format(("environment %q must be an object"):format(name))
    end
    local copy = {}
    for key, value in pairs(vars) do
      if type(key) ~= "string" or key == "" then
        return nil, INVALID:format(("%s: variable names must be non-empty strings"):format(name))
      end
      local t = type(value)
      if t ~= "string" and t ~= "number" and t ~= "boolean" then
        return nil,
          INVALID:format(
            ("%s.%s: expected a string, number or boolean, got %s"):format(name, key, t)
          )
      end
      copy[key] = value
    end
    environments[name] = copy
  end

  if doc.default and not environments[doc.default] then
    return nil, INVALID:format(("default environment %q is not defined"):format(doc.default))
  end

  return { default = doc.default, environments = environments }
end

---Sorted environment names of a normalized document.
function M.names(state)
  local names = {}
  for name in pairs(state.environments) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---Variables of `name` in a normalized document, or nil.
function M.vars(state, name)
  if not name then
    return nil
  end
  return state.environments[name]
end

return M

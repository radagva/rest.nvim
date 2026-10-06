# rest.nvim

A REST client for Neovim. Reads `.http` files, executes the request under the
cursor, and shows the response — written in pure Lua with zero Lua/library
dependencies.

## Requirements

- Neovim **0.12+**
- `curl` (transport)
- `jq` (optional — pretty-prints JSON responses; falls back to a built-in
  renderer when absent)

## Usage

Open a `.http` file and run the request under the cursor:

```http
@host = https://api.example.com

### list users
GET {{host}}/users
Accept: application/json
```

```vim
:RestRun
```

`:RestRun` parses the buffer, resolves `{{variables}}` defined as
`@name = value`, sends the request with `curl`, and opens the response in a
split (`rest://response`). The body is syntax-highlighted by content type
(treesitter when a parser is installed; status and headers stay dimmed).

Supported `.http` features: `###` request separators (with optional names),
`#`/`//` comments, `@name = value` file variables, `{{name}}` substitution in
URL/headers/body, request headers and raw bodies (RFC 9112 message shape).

## Setup (optional)

Defaults work out of the box; override as needed:

```lua
require("rest").setup({
  base_url = nil,           -- prefix for relative URLs
  timeout_s = 30,           -- curl --max-time
  follow_redirects = false, -- curl -L
  verify_tls = true,        -- set false to pass curl -k
  jq_path = nil,            -- explicit jq binary (default: auto-detect)
  ui = { split = "vertical" }, -- or "horizontal"
})
```

## Installation

Not yet published. For local development, add this directory to
`'runtimepath'`, or use `vim.pack.add` once the repository is pushed.

## Development

```sh
brew install stylua luacheck busted   # tooling

make check    # stylua . && luacheck . && busted
make smoke    # headless end-to-end run against example.com
```

Tests live in `tests/` (busted); `.http` fixtures in `tests/fixtures/`.

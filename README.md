# rest.nvim

A REST client for Neovim. Reads `.http` files, executes the request under the
cursor, and shows the response (written in pure Lua with zero Lua/library
dependencies).

## Requirements

- Neovim **0.12+**
- `curl` (transport)
- `jq` (optional; pretty-prints JSON responses; falls back to a built-in
  renderer when absent)

## Usage

Open a `.http` file and run the request under the cursor:

```http
@host = https://api.example.com

### list users
GET $host/users
Accept: application/json
```

```vim
:RestRun
```

`:RestRun` parses the buffer, resolves `$name` references defined as
`@name = value`, sends the request with `curl`, and opens the response in a
split (`rest://response`). The body is syntax-highlighted by content type
(treesitter when a parser is installed; status and headers stay dimmed).

Supported `.http` features: `###` request separators (with optional names),
`#`/`//` comments, `@name = value` file variables, `@name <tag>` request tags,
`$name` substitution in URL/headers/body (concatenates inside quoted strings),
request headers and raw bodies (RFC 9112 message shape).

A `$` not followed by a letter or underscore is left as-is (`$99.99`, `$5`),
so JSON bodies with prices stay intact. Write `$$word` for a literal `$word`.

## Chaining requests

Tag a request with `@name <tag>` (before its request line). Once that request
has run, its response is available to any later request through
`$<tag>.response.<path>`:

```http
@name signin
POST $host/login
Content-Type: application/json

{"user": "root", "pass": "secret"}

### run the request above first
GET $host/me
Authorization: Bearer $signin.response.body.accessToken
```

| Path | Value |
| --- | --- |
| `$tag.response.body` | raw response body |
| `$tag.response.body.field` | JSON field (`.` for nesting; keys are matched case-insensitively; objects/arrays are inlined as compact JSON) |
| `$tag.response.body[0].field` | array element (**0-based**; `.0` also works; `[0][1]` chains) |
| `$tag.response.headers.Name` | header value (name is case-insensitive) |
| `$tag.response.status` | status code |
| `$tag.response.version` | HTTP version |
| `$tag.response.reason` | reason phrase |
| `$tag.response.url` | final URL |

Responses are kept in memory for the current session: the tagged request must
have been run before (otherwise resolution fails with
`undefined response '<tag>'`). File definitions win over response refs of the
same name.

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

## Highlighting

The response UI exposes these highlight groups. All are defined with
`default = true`, so your colorscheme can override them (e.g. from its
`on_highlights`):

| Group | Applies to | Default |
| --- | --- | --- |
| `RestStatusCodeInformation` | `1xx` status code | white |
| `RestStatusCodeSuccess` | `2xx` status code | green |
| `RestStatusCodeRedirect` | `3xx` status code | amber |
| `RestStatusCodeError` | `4xx` status code | red |
| `RestStatusCodeServerError` | `5xx` status code | black on red |
| `RestHeadingsAttributes` | header names | links to `@function.method` |
| `RestHeadingsValues` | header values | links to `Comment` |

```lua
on_highlights = function(hl, colors)
  hl.RestStatusCodeSuccess = { fg = colors.green }
  hl.RestStatusCodeServerError = { fg = colors.bg, bg = colors.red }
  hl.RestHeadingsValues = { fg = colors.fg_dim }
end
```

The rest of the status line (`HTTP/1.1`, reason phrase) stays plain `Normal`;
the response body is handled by treesitter for its content type.

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

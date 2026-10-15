# Changelog

All notable changes to this project will be documented in this file.

Versions follow [Semantic Versioning](https://semver.org/); dates are
`YYYY-MM-DD` and the structure is inspired by
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.0] - 2026-10-15

All changes since `v1.0.0`.

### Added

- **curl interop**: `:RestCopyCurl` copies the request under the cursor
  (variables resolved) as a shell-quoted curl command to the system
  clipboard and the unnamed register; `:RestImportCurl` inserts a curl
  command from the clipboard as an `.http` request, understanding the
  flags browser DevTools emit (`-X`, `-H`, `-d`/`--data*`, `--json`,
  `-A`, `-b`, `-e`, `-u`, `-I`, `-G`, `--url`).
- **Cookie jar**: with `cookies.enabled`, every request passes a shared
  Netscape cookie jar to curl, so `Set-Cookie` values from a login
  response flow into later requests; `cookies.path` persists the jar
  across sessions and `:RestCookiesClear` deletes it.
- **Environments**: a `rest-env.json` file (searched upward from the
  working directory) provides environment variables per named
  environment; `:RestEnv` shows or switches the active one, and
  file-level `@definitions` win over environment values of the same
  name.
- **`$_now` plugin global**: the reserved `$_` prefix resolves `$_now`
  to a local ISO 8601 timestamp that every reference in one request
  shares, with zero-padded fields (`$_now.year`, `$_now.minute`, ...);
  fields shift with `$_now.<field>.add(<n>)` / `.sub(<n>)` and the
  calendar normalizes (23:30 + 4 hours rolls to 03:30, Jan 31 + 1 month
  clamps to Feb 28). Defining a `_`-prefixed variable warns and stops
  the request.
- **Shift methods**: chainable helpers directly on `$_now`:
  `add/subHours(n)`, `add/subMinutes(n)`, `add/subSeconds(n)`,
  `add/subDays(n)`, `add/subMonths(n)` and `add/subYears(n)`; each link
  applies to the previous result and a chain may end with a field
  access (`$_now.addDays(7).day`).
- **Derived variables**: definition values may contain references (other
  definitions, environment values, previous responses, `$_` globals)
  and resolve when the request runs, in any declaration order; a broken
  value reports `definition '<name>': <error>` and a loop reports
  `circular definition: a -> b -> a`.
- Vimdoc help file: `:help rest.nvim`.

### Fixed

- `:RestCopyCurl` also copies the command to the system clipboard (`+`),
  not only to the unnamed register.

## [1.0.0] - 2026-10-11

First tagged release: `.http` parsing (RFC 9112 message shape), `:RestRun`
over a curl transport, the response split with jq pretty-printing, the
`:RestList` picker, file-level `@name = value` definitions and request
chaining through `$tag.response.<path>`.

[Unreleased]: https://github.com/radagva/rest.nvim/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/radagva/rest.nvim/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/radagva/rest.nvim/releases/tag/v1.0.0

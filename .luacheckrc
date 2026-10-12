std = "luajit"
globals = { "vim" }

files["tests/**.lua"].std = "luajit+busted"

-- Pure-Lua core: enforce the no-vim.* rule at lint time.
files["lua/rest/parser.lua"].std = "lua51"
files["lua/rest/variables.lua"].std = "lua51"
files["lua/rest/format.lua"].std = "lua51"
files["lua/rest/curl.lua"].std = "lua51"
files["lua/rest/env.lua"].std = "lua51"

exclude_files = { ".luarocks", ".luarocks/**" }

-- Headless end-to-end smoke: parse buffer -> resolve vars -> curl -> response window.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/rest.lua")

local http = table.concat({
  "@host = https://example.com",
  "### fetch home",
  "GET {{host}}/",
  "Accept: text/html",
}, "\n")

vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(http, "\n", { plain = true }))
vim.api.nvim_win_set_cursor(0, { 3, 0 })

require("rest").run()

local ui = require("rest.ui")
local ok = vim.wait(15000, function()
  return ui._buf ~= nil and vim.api.nvim_buf_is_valid(ui._buf)
end, 100)

if not ok then
  error("smoke: no response buffer after 15s")
end

local lines = vim.api.nvim_buf_get_lines(ui._buf, 0, -1, false)
print("SMOKE status line: " .. lines[1])
if not lines[1]:match("^HTTP/[%d%.]+ 200") then
  error("smoke: expected HTTP 200, got: " .. lines[1])
end
print("SMOKE OK")

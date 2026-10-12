if vim.g.loaded_rest then
  return
end
vim.g.loaded_rest = true

vim.api.nvim_create_user_command("RestRun", function()
  require("rest").run()
end, { desc = "Run the .http request under the cursor" })

vim.api.nvim_create_user_command("RestList", function()
  require("rest").list()
end, { desc = "Pick a request from all .http files and jump to it" })

vim.api.nvim_create_user_command("RestCopyCurl", function()
  require("rest").copy_curl()
end, { desc = "Copy the request under the cursor as a curl command" })

vim.api.nvim_create_user_command("RestImportCurl", function()
  require("rest").import_curl()
end, { desc = "Insert a curl command from the clipboard as a .http request" })

vim.api.nvim_create_user_command("RestCookiesClear", function()
  require("rest").cookies_clear()
end, { desc = "Delete the rest.nvim cookie jar" })

vim.api.nvim_create_user_command("RestEnv", function(cmd)
  require("rest").env(cmd.args ~= "" and cmd.args or nil)
end, { desc = "Show or switch the active environment (rest-env.json)", nargs = "?" })

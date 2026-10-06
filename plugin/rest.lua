if vim.g.loaded_rest then
  return
end
vim.g.loaded_rest = true

vim.api.nvim_create_user_command("RestRun", function()
  require("rest").run()
end, { desc = "Run the .http request under the cursor" })

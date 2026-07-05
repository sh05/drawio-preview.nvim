if vim.g.loaded_drawio_preview then
  return
end
vim.g.loaded_drawio_preview = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("[drawio] drawio-preview.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("DrawioPreview", function()
  require("drawio").preview()
end, { desc = "Start the drawio live preview for the current buffer" })

vim.api.nvim_create_user_command("DrawioExport", function()
  require("drawio").export()
end, { desc = "Export the current buffer as <name>.drawio.png" })

vim.api.nvim_create_user_command("DrawioStop", function()
  require("drawio").stop()
end, { desc = "Stop the drawio preview server" })

vim.api.nvim_create_user_command("DrawioLayout", function(cmd)
  require("drawio").layout(cmd.args)
end, {
  nargs = 1,
  complete = function()
    return { "tree", "flow", "organic", "circle" }
  end,
  desc = "Apply a draw.io auto-layout to the buffer (rewrites the buffer, one undo step)",
})

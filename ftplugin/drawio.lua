if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1

-- .drawio files are plain mxGraph XML; reuse the XML syntax machinery.
vim.bo.syntax = "xml"
vim.bo.commentstring = "<!-- %s -->"

pcall(vim.treesitter.start, 0, "xml")

vim.b.undo_ftplugin = "setlocal syntax< commentstring<"

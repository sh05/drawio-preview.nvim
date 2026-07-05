-- Filetype registration lives in ftdetect/ (not plugin/) so that
-- lazy-loading plugin managers, which source ftdetect files eagerly but
-- defer plugin/ until the plugin is triggered, can detect .drawio files
-- before the plugin itself loads.
vim.filetype.add({
  extension = {
    drawio = "drawio",
  },
})

-- Opening an exported .drawio.png loads the embedded diagram XML into the
-- buffer instead of the binary PNG bytes; :w renders a fresh PNG through
-- the normal export path. These autocmds live here for the same reason as
-- the filetype above: they must exist before the first .drawio.png buffer
-- is read, which is before lazy-loading managers source plugin/.
local group = vim.api.nvim_create_augroup("DrawioPngEdit", { clear = true })
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "*.drawio.png",
  callback = function(ev)
    require("drawio").read_png(ev.buf, vim.fn.fnamemodify(ev.match, ":p"))
  end,
})
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "*.drawio.png",
  callback = function(ev)
    require("drawio").write_png(ev.buf, vim.fn.fnamemodify(ev.match, ":p"))
  end,
})

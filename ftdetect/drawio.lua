-- Filetype registration lives in ftdetect/ (not plugin/) so that
-- lazy-loading plugin managers, which source ftdetect files eagerly but
-- defer plugin/ until the plugin is triggered, can detect .drawio files
-- before the plugin itself loads.
vim.filetype.add({
  extension = {
    drawio = "drawio",
  },
})

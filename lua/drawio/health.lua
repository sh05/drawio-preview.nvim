local M = {}

function M.check()
  local health = vim.health
  health.start("drawio-preview.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim >= 0.10 is required (vim.base64, vim.system)")
  end

  local config = require("drawio.config")
  if config.options.drawio_url:lower():match("^https?://") then
    health.ok("drawio_url: " .. config.options.drawio_url)
  else
    health.error("drawio_url must start with http:// or https://: " .. config.options.drawio_url)
  end

  local browser = config.options.browser
  if browser == nil then
    health.ok("browser: system default (vim.ui.open)")
  elseif type(browser) == "table" and #browser > 0 then
    if vim.fn.executable(browser[1]) == 1 then
      health.ok("browser: " .. table.concat(browser, " "))
    else
      health.error("browser executable not found: " .. tostring(browser[1]))
    end
  else
    health.error("config.browser must be nil or a list of command arguments")
  end

  local server = require("drawio.server")
  if server.is_running() then
    health.ok(("preview server running on 127.0.0.1:%d (%d client(s))"):format(server.port, server.client_count()))
  else
    health.info("preview server not running (start with :DrawioPreview)")
  end
end

return M

--- Default configuration for drawio-preview.nvim
local M = {}

M.defaults = {
  -- Port for the local preview server. 0 = pick a free port automatically.
  port = 0,

  -- draw.io editor origin used inside the bridge page.
  -- For offline / self-hosted use, point this at your own instance,
  -- e.g. "http://localhost:8080" (official drawio Docker image).
  drawio_url = "https://embed.diagrams.net",

  -- Delay (ms) between the last buffer change and pushing XML to the preview.
  debounce_ms = 500,

  -- Write <name>.drawio.png next to the file on :w
  export_on_write = true,

  -- Scale factor for the exported PNG (2 = retina-ish).
  export_scale = 2,

  -- How long (ms) to wait for the browser to send back a rendered PNG
  -- before giving up on an export request.
  export_timeout_ms = 30000,

  -- How to open the preview URL.
  --   nil            -> vim.ui.open() (system default browser)
  --   list of args   -> spawned with the URL appended,
  --                     e.g. { "google-chrome", "--app" } becomes
  --                     google-chrome --app=http://127.0.0.1:PORT
  --                     (a trailing "--app" is merged as --app=URL)
  browser = nil,
}

M.options = vim.deepcopy(M.defaults)

local option_types = {
  port = "number",
  drawio_url = "string",
  debounce_ms = "number",
  export_on_write = "boolean",
  export_scale = "number",
  export_timeout_ms = "number",
  browser = "table",
}

function M.setup(opts)
  opts = opts or {}
  for key, value in pairs(opts) do
    local want = option_types[key]
    if want == nil then
      error(("[drawio] unknown option %q"):format(tostring(key)))
    end
    if type(value) ~= want then
      error(("[drawio] option %q must be a %s (got %s)"):format(tostring(key), want, type(value)))
    end
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- A trailing slash would produce "//?embed=1" in the iframe src.
  M.options.drawio_url = M.options.drawio_url:gsub("/+$", "")
end

return M

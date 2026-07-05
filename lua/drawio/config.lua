--- Default configuration for drawio-preview.nvim
local M = {}

M.defaults = {
  -- Port for the local preview server: an integer in 0..65535.
  -- 0 = pick a free port automatically.
  port = 0,

  -- draw.io editor origin used inside the bridge page. Must start with
  -- http:// or https://. For offline / self-hosted use, point this at your
  -- own instance, e.g. "http://localhost:8080" (official drawio Docker image).
  drawio_url = "https://embed.diagrams.net",

  -- Delay (ms, >= 0) between the last buffer change and pushing XML to the preview.
  debounce_ms = 500,

  -- Write <name>.drawio.png next to the file on :w
  export_on_write = true,

  -- Scale factor (> 0) for the exported PNG (2 = retina-ish).
  export_scale = 2,

  -- How long (ms, > 0) to wait for the browser to send back a rendered PNG
  -- before giving up on an export request.
  export_timeout_ms = 30000,

  -- How to open the preview URL.
  --   nil            -> vim.ui.open() (system default browser)
  --   list of args   -> spawned with the URL appended (must be a non-empty
  --                     list of strings), e.g. { "google-chrome", "--app" }
  --                     becomes google-chrome --app=http://127.0.0.1:PORT
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

local function fail(msg, ...)
  error("[drawio] " .. msg:format(...), 0)
end

--- Value checks beyond types. Types alone let broken configs pass setup()
--- and fail much later in obscure ways (a schemeless drawio_url renders a
--- blank iframe, browser = {} tries to execute the URL, debounce_ms = -1
--- reaches timer:start, port = 99999 only fails at bind()).
local function validate(options, opts)
  if not options.drawio_url:match("^https?://") then
    fail("drawio_url must start with http:// or https:// (got %q)", options.drawio_url)
  end
  -- The value is templated into the bridge page's src="..." attribute
  -- unescaped; reject anything that cannot appear in an origin.
  if options.drawio_url:match("[%s\"'<>\\]") then
    fail("drawio_url must not contain spaces or quote characters (got %q)", options.drawio_url)
  end
  if options.port % 1 ~= 0 or options.port < 0 or options.port > 65535 then
    fail("port must be an integer in 0..65535 (got %s)", tostring(options.port))
  end
  if options.debounce_ms < 0 then
    fail("debounce_ms must be >= 0 (got %s)", tostring(options.debounce_ms))
  end
  if options.export_scale <= 0 then
    fail("export_scale must be > 0 (got %s)", tostring(options.export_scale))
  end
  if options.export_timeout_ms <= 0 then
    fail("export_timeout_ms must be > 0 (got %s)", tostring(options.export_timeout_ms))
  end
  if opts.browser ~= nil then
    if not vim.islist(options.browser) or #options.browser == 0 then
      fail("browser must be a non-empty list of command arguments")
    end
    for i, arg in ipairs(options.browser) do
      if type(arg) ~= "string" then
        fail("browser[%d] must be a string (got %s)", i, type(arg))
      end
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  for key, value in pairs(opts) do
    local want = option_types[key]
    if want == nil then
      fail("unknown option %q", tostring(key))
    end
    if type(value) ~= want then
      fail("option %q must be a %s (got %s)", tostring(key), want, type(value))
    end
  end
  local options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- A trailing slash would produce "//?embed=1" in the iframe src.
  options.drawio_url = options.drawio_url:gsub("/+$", "")
  validate(options, opts)
  M.options = options
end

return M

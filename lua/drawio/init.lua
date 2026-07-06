--- drawio-preview.nvim
--- Edit draw.io XML in Neovim, live-preview it in a browser, and write both
--- the .drawio source and a re-editable .drawio.png on save.
---
--- Data flow (one-way; the buffer is the single source of truth):
---   buffer change --debounce--> SSE {type=load}  --> embedded draw.io editor
---   :w            -----------> SSE {type=export} --> editor renders xmlpng
---   bridge page  --POST /export-result--> Neovim writes <name>.drawio.png
local config = require("drawio.config")
local png = require("drawio.png")
local server = require("drawio.server")

local uv = vim.uv or vim.loop

local M = {}

local state = {
  attached = {}, -- bufnr -> true
  followed = nil, -- the one buffer whose edits drive the preview
  augroup = nil,
  timer = nil,
  last_xml = nil,
  waiting_export = {}, -- token -> { path = source file, buf = bufnr, at = hrtime }
  export_seq = 0,
}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  -- .../lua/drawio/init.lua -> plugin root
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function load_html()
  local path = plugin_root() .. "/assets/index.html"
  if vim.fn.filereadable(path) ~= 1 then
    error("[drawio] bridge page not found: " .. path, 0)
  end
  local html = table.concat(vim.fn.readfile(path), "\n")
  return (html:gsub("{{DRAWIO_URL}}", function()
    return config.options.drawio_url
  end))
end

local function buffer_xml(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Cheap sanity check so we don't spam the editor with obviously
--- half-typed content. Not a validator; draw.io shows its own error
--- for anything that slips through, which is harmless.
local function looks_like_xml(text)
  local first = text:match("^%s*(%S)")
  return first == "<"
end

--- Returns true when the buffer content was actually pushed; callers that
--- are about to render (export) must not proceed on false, or the editor
--- would render whatever XML it had before.
local function push_now(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local xml = buffer_xml(buf)
  if not looks_like_xml(xml) and xml:match("%S") then
    return false -- non-empty but clearly not XML yet; wait for more typing
  end
  state.last_xml = xml
  server.broadcast({ type = "load", xml = xml })
  return true
end

local function schedule_push(buf)
  if not state.timer then
    state.timer = uv.new_timer()
  end
  state.timer:stop()
  state.timer:start(
    config.options.debounce_ms,
    0,
    vim.schedule_wrap(function()
      -- Re-check at fire time: the pin may have moved to another buffer
      -- while this timer was pending, and a stale push would hijack it.
      if buf == state.followed then
        push_now(buf)
      end
    end)
  )
end

--- Exporting a non-followed buffer had to load its XML into the editor;
--- once that export finishes — successfully or not — give the preview
--- back to the followed buffer.
local function give_back_preview(export_buf)
  if state.followed and state.followed ~= export_buf and vim.api.nvim_buf_is_valid(state.followed) then
    push_now(state.followed)
  end
end

local function png_path_for(src)
  -- foo.drawio -> foo.drawio.png / foo.xml -> foo.xml.drawio.png
  -- (never strip the extension: foo.xml and foo.drawio in the same
  -- directory must not fight over one PNG). A buffer that *is* a
  -- .drawio.png (opened via BufReadCmd) renders back onto itself.
  if src:sub(-11) == ".drawio.png" then
    return src
  end
  if src:sub(-7) == ".drawio" then
    return src .. ".png"
  end
  return src .. ".drawio.png"
end

local function request_export(buf, srcfile, opts)
  if server.client_count() == 0 then
    vim.notify("[drawio] no preview connected; skipped PNG export (run :DrawioPreview)", vim.log.levels.WARN)
    return
  end
  -- Make sure the editor has the latest buffer before rendering. If the
  -- buffer cannot be pushed, exporting would silently write a PNG of the
  -- *previous* revision next to the just-saved source — refuse instead:
  -- the PNG on disk either matches the source or is not written at all.
  if not push_now(buf) then
    vim.notify("[drawio] buffer is not valid XML; skipped PNG export", vim.log.levels.WARN)
    return
  end

  -- Sequence for uniqueness within the session (tostring of a large
  -- hrtime double rounds to 14 digits, so hrtime alone can collide on
  -- long-running machines); hrtime so tokens from a stale browser page
  -- of a previous session can never match.
  state.export_seq = state.export_seq + 1
  local token = state.export_seq .. "-" .. tostring(uv.hrtime())
  state.waiting_export[token] = {
    path = srcfile,
    buf = buf,
    at = uv.hrtime(),
    -- Set for .drawio.png buffers: their :w is only complete once the
    -- rendered PNG is on disk.
    clear_modified = opts and opts.clear_modified or nil,
  }
  server.broadcast({
    type = "export",
    scale = config.options.export_scale,
    token = token,
  })

  -- Garbage-collect stale requests that never got a response.
  vim.defer_fn(function()
    local w = state.waiting_export[token]
    if w then
      state.waiting_export[token] = nil
      vim.notify("[drawio] PNG export timed out", vim.log.levels.WARN)
      give_back_preview(w.buf)
    end
  end, config.options.export_timeout_ms)
end

--- Decode the posted PNG and write it next to the source. Returns true on
--- success; every failure path notifies on its own.
local function write_export_png(waiting, data)
  local b64 = data.png:gsub("^data:image/png;base64,", "")
  local ok, png = pcall(vim.base64.decode, b64)
  if not ok then
    vim.notify("[drawio] failed to decode PNG payload", vim.log.levels.ERROR)
    return false
  end

  -- Write to a temp file and rename so a crash mid-write can never leave
  -- a truncated PNG behind.
  local out = png_path_for(waiting.path)
  local tmp = out .. ".tmp"
  local fd, err = io.open(tmp, "wb")
  if not fd then
    vim.notify("[drawio] cannot write " .. tmp .. ": " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  local wok, werr = fd:write(png)
  fd:close()
  if not wok then
    os.remove(tmp)
    vim.notify("[drawio] cannot write " .. tmp .. ": " .. tostring(werr), vim.log.levels.ERROR)
    return false
  end
  local rok, rerr = os.rename(tmp, out)
  if not rok then
    os.remove(tmp)
    vim.notify("[drawio] cannot replace " .. out .. ": " .. tostring(rerr), vim.log.levels.ERROR)
    return false
  end
  vim.notify("[drawio] wrote " .. vim.fn.fnamemodify(out, ":."))
  return true
end

--- Called by the server when the bridge page POSTs the rendered PNG.
local function on_export_result(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" or type(data.png) ~= "string" then
    vim.notify("[drawio] malformed export result", vim.log.levels.ERROR)
    return
  end
  local waiting = data.token and state.waiting_export[data.token]
  if not waiting then
    return -- stale or unknown token
  end
  state.waiting_export[data.token] = nil

  local wrote = write_export_png(waiting, data)
  -- For .drawio.png buffers the rendered PNG *is* the file: only now is
  -- their :w actually complete.
  if wrote and waiting.clear_modified and vim.api.nvim_buf_is_valid(waiting.buf) then
    vim.bo[waiting.buf].modified = false
  end
  -- Whether the write succeeded or not, the render is over: give the
  -- preview back to the followed buffer.
  give_back_preview(waiting.buf)
end

local function on_post(path, body)
  if path == "/export-result" then
    on_export_result(body)
  end
end

--- When the bridge page (re)connects, immediately feed it the current XML.
local function on_sse_connect(client)
  if state.last_xml ~= nil then
    server.send(client, { type = "load", xml = state.last_xml })
  end
end

local function open_browser(url)
  local browser = config.options.browser
  if browser == nil then
    local ok, err = pcall(vim.ui.open, url)
    if not ok then
      vim.notify(
        "[drawio] could not open a browser (" .. tostring(err) .. "). Open " .. url .. " manually.",
        vim.log.levels.WARN
      )
    end
    return
  end
  local cmd = vim.deepcopy(browser)
  if cmd[#cmd] == "--app" then
    cmd[#cmd] = "--app=" .. url -- chrome/edge style app window
  else
    cmd[#cmd + 1] = url
  end
  local ok, err = pcall(vim.system, cmd, { detach = true })
  if not ok then
    vim.notify(
      "[drawio] failed to launch browser '"
        .. tostring(cmd[1])
        .. "' ("
        .. tostring(err)
        .. "). Open "
        .. url
        .. " manually.",
      vim.log.levels.WARN
    )
  end
end

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------

function M.setup(opts)
  config.setup(opts)
end

function M.attach(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if state.attached[buf] then
    return
  end
  state.attached[buf] = true
  state.augroup = state.augroup or vim.api.nvim_create_augroup("DrawioPreview", { clear = false })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup,
    buffer = buf,
    callback = function()
      -- Only the followed buffer drives the preview; edits elsewhere must
      -- neither hijack the page nor cancel the followed buffer's debounce.
      if buf == state.followed then
        schedule_push(buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = state.augroup,
    buffer = buf,
    callback = function(ev)
      if config.options.export_on_write then
        -- ev.file can be relative; resolve it now so a later :cd cannot
        -- change where the PNG lands once the export result arrives.
        request_export(buf, vim.fn.fnamemodify(ev.file, ":p"))
      end
    end,
  })

  -- BufWipeout, not BufDelete: buffer-local autocmds survive :bdelete
  -- (the buffer merely becomes unlisted), so clearing the flag any
  -- earlier would let a re-attach register duplicate autocmds.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.augroup,
    buffer = buf,
    callback = function()
      state.attached[buf] = nil
      if state.followed == buf then
        state.followed = nil
      end
    end,
  })
end

function M.preview()
  local buf = vim.api.nvim_get_current_buf()
  local was_running = server.is_running()
  local ok, port = pcall(function()
    return server.start({
      port = config.options.port,
      html = load_html(),
      on_post = on_post,
      on_sse_connect = on_sse_connect,
    })
  end)
  if not ok then
    -- A used port or a broken plugin install must not dump a stack trace
    -- out of the user command.
    vim.notify(tostring(port), vim.log.levels.ERROR)
    return
  end
  -- A running server keeps its socket; a changed `port` in setup() would
  -- otherwise be ignored without a word.
  if was_running and config.options.port ~= 0 and config.options.port ~= port then
    vim.notify(
      ("[drawio] server already running on port %d; port = %d applies after :DrawioStop"):format(
        port,
        config.options.port
      ),
      vim.log.levels.WARN
    )
  end
  M.attach(buf)
  -- The preview is pinned to one buffer at a time; running :DrawioPreview
  -- in another buffer moves the pin there.
  if state.followed and state.followed ~= buf and vim.api.nvim_buf_is_valid(state.followed) then
    vim.notify("[drawio] preview now follows " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":."))
  end
  state.followed = buf
  push_now(buf) -- prime last_xml so a connecting page renders immediately
  -- The token in the URL is the only key to this server; the bridge page
  -- reads it from location.search and presents it on every request.
  local url = "http://127.0.0.1:" .. port .. "/?t=" .. server.token
  open_browser(url)
  vim.notify("[drawio] preview at " .. url)
end

function M.export()
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    vim.notify("[drawio] buffer has no file name; save it first", vim.log.levels.WARN)
    return
  end
  if not server.is_running() then
    vim.notify("[drawio] preview not running; run :DrawioPreview first", vim.log.levels.WARN)
    return
  end
  M.attach(buf)
  request_export(buf, file)
end

--- BufReadCmd for *.drawio.png: load the embedded diagram XML instead of
--- the binary PNG bytes. From here on the buffer is the source of truth,
--- exactly as for a plain .drawio buffer.
function M.read_png(buf, path)
  local lines = {}
  local f = io.open(path, "rb")
  if f then
    local data = f:read("*a")
    f:close()
    local xml, err = png.extract_xml(data)
    if not xml then
      -- Lock the buffer: a :w from here would render an *empty* diagram
      -- over a PNG we could not read, destroying its contents.
      vim.bo[buf].modified = false
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
      vim.notify("[drawio] " .. vim.fn.fnamemodify(path, ":.") .. ": " .. err, vim.log.levels.ERROR)
      return
    end
    lines = vim.split(xml, "\n", { plain = true })
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "drawio"
end

--- BufWriteCmd for *.drawio.png: the only way to produce a valid PNG is
--- to render the XML, so :w goes through the normal export round trip.
--- 'modified' stays set until the rendered PNG is actually on disk —
--- clearing it optimistically could lose the XML to a failed export.
function M.write_png(buf, path)
  if not server.is_running() or server.client_count() == 0 then
    vim.notify(
      "[drawio] writing a .drawio.png needs a connected preview to render it — run :DrawioPreview, then :w again",
      vim.log.levels.ERROR
    )
    return
  end
  M.attach(buf)
  request_export(buf, path, { clear_modified = true })
end

function M.stop()
  if not server.is_running() then
    vim.notify("[drawio] preview not running")
    return
  end
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  -- Detach everything, or export_on_write would warn on every :w after
  -- the preview is gone.
  if state.augroup then
    vim.api.nvim_clear_autocmds({ group = state.augroup })
  end
  state.attached = {}
  state.followed = nil
  state.waiting_export = {}
  server.broadcast({ type = "bye" }) -- lets open pages show "stopped" instead of retrying forever
  server.stop()
  vim.notify("[drawio] preview stopped")
end

return M

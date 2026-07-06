--- Headless end-to-end test for drawio-preview.nvim.
---
--- Run: nvim --clean -l tests/e2e.lua   (exits non-zero on any failure)
---
--- Spawns a real child Neovim (driven over RPC) with the plugin loaded and
--- plays the bridge page against it with curl: SSE live updates, the
--- :w -> export -> POST /export-result -> PNG-on-disk round trip, and
--- :DrawioStop. No browser and no draw.io involved; the test impersonates
--- the bridge page.
---
--- All waiting goes through vim.wait so the parent keeps pumping its own
--- main loop (vim.system():wait() only pumps fast events and would deadlock
--- the scheduled request handler if reused for HTTP helpers).

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")

local checks, failures = 0, 0
local function check(ok, name, detail)
  checks = checks + 1
  if ok then
    print(("ok %d - %s"):format(checks, name))
  else
    failures = failures + 1
    print(("FAIL %d - %s%s"):format(checks, name, detail and (" (" .. tostring(detail) .. ")") or ""))
  end
end

local function wait_for(cond, timeout_ms)
  return vim.wait(timeout_ms or 10000, cond, 10)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

-- ---------------------------------------------------------------------------
-- setup: workspace, child Neovim, RPC channel
-- ---------------------------------------------------------------------------

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local drawio_file = tmp .. "/test.drawio"
local png_file = drawio_file .. ".png"
local sock = tmp .. "/nvim.sock"

local initial_xml_lines = {
  "<mxGraphModel>",
  '  <root><mxCell id="0"/><mxCell id="1" parent="0"/></root>',
  "</mxGraphModel>",
}
local f = assert(io.open(drawio_file, "wb"))
f:write(table.concat(initial_xml_lines, "\n") .. "\n")
f:close()

-- vim.v.progpath: the same binary that runs this suite, not whatever
-- "nvim" happens to be first in $PATH. The watchdog makes the child
-- reap itself if this process dies mid-run (a thrown error would
-- otherwise orphan a listening headless Neovim forever).
local watchdog = ("lua do local p = %d; local t = vim.uv.new_timer(); "):format(vim.uv.os_getpid())
  .. "t:start(2000, 2000, function() if not vim.uv.kill(p, 0) then os.exit(1) end end) end"
local child = vim.system({
  vim.v.progpath,
  "--clean",
  "--headless",
  "--listen",
  sock,
  "--cmd",
  "lua vim.opt.rtp:prepend([[" .. root .. "]])",
  "--cmd",
  watchdog,
  drawio_file,
})

local chan
check(
  wait_for(function()
    local ok, c = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
    if ok and c > 0 then
      chan = c
      return true
    end
    return false
  end),
  "child Neovim starts and accepts RPC"
)

if not chan then
  print("FATAL - could not connect to the child Neovim over RPC")
  child:kill(9)
  os.exit(1)
end

local function child_lua(code, ...)
  return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
end
local function child_cmd(cmd)
  return vim.rpcrequest(chan, "nvim_command", cmd)
end

-- browser = { "true" } keeps the child from opening a real browser;
-- a short debounce keeps the test fast.
child_lua([[require("drawio").setup({ port = 0, browser = { "true" }, debounce_ms = 100 })]])
child_cmd("DrawioPreview")

local port = child_lua([[return require("drawio.server").port]])
check(type(port) == "number" and port > 0, ":DrawioPreview starts the server")

local base = "http://127.0.0.1:" .. port
local token = child_lua([[return require("drawio.server").token]])
check(type(token) == "string" and #token == 32, "the preview session has an auth token")
local auth = "?t=" .. token

-- ---------------------------------------------------------------------------
-- SSE stream: the test plays the bridge page from here on
-- ---------------------------------------------------------------------------

-- A client without the token must be locked out of the SSE stream.
local status_done, status_res = false, nil
vim.system(
  { "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", base .. "/events" },
  { text = true },
  function(res)
    status_res = res
    status_done = true
  end
)
wait_for(function()
  return status_done
end)
check(status_res and tonumber(status_res.stdout) == 403, "SSE without the token is rejected")

local sse_file = tmp .. "/sse.log"
local sse_proc = vim.system({ "curl", "-sN", "-o", sse_file, "--max-time", "120", base .. "/events" .. auth })

local function sse_messages()
  local text = read_file(sse_file)
  if not text then
    return {}
  end
  local msgs = {}
  for line in text:gmatch("data: ([^\n]+)") do
    local ok, msg = pcall(vim.json.decode, line)
    if ok then
      msgs[#msgs + 1] = msg
    end
  end
  return msgs
end

local function count_msgs(pred)
  local n = 0
  for _, m in ipairs(sse_messages()) do
    if pred(m) then
      n = n + 1
    end
  end
  return n
end

local initial_xml = table.concat(initial_xml_lines, "\n")
check(
  wait_for(function()
    return count_msgs(function(m)
      return m.type == "load" and m.xml == initial_xml
    end) == 1
  end),
  "connecting SSE client is primed with the buffer content"
)

-- ---------------------------------------------------------------------------
-- debounced live updates
-- ---------------------------------------------------------------------------

-- Two rapid edits: the first must be coalesced away by the debounce timer.
child_lua([[
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { '  <root><mxCell id="0"/></root><!-- A -->' })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { '  <root><mxCell id="0"/></root><!-- B -->' })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
]])

check(
  wait_for(function()
    return count_msgs(function(m)
      return m.type == "load" and m.xml:find("<!-- B -->", 1, true) ~= nil
    end) == 1
  end),
  "debounced edit is pushed to the preview"
)

-- Both edits happen inside one synchronous exec_lua, so any push already
-- reads B; the real coalescing signal is the *total* number of pushes:
-- prime (1) + one debounced push (2). An uncancelled timer would give 3.
vim.wait(300) -- give a second (wrong) push time to arrive
check(count_msgs(function(m)
  return m.type == "load"
end) == 2, "rapid successive edits are coalesced into one push (debounce)")

-- ---------------------------------------------------------------------------
-- :w -> export request -> POST /export-result -> PNG on disk
-- ---------------------------------------------------------------------------

local function export_tokens()
  local tokens = {}
  for _, m in ipairs(sse_messages()) do
    if m.type == "export" then
      tokens[#tokens + 1] = m.token
    end
  end
  return tokens
end

child_cmd("write")
check(
  wait_for(function()
    return #export_tokens() == 1
  end),
  ":w broadcasts an export request"
)

vim.wait(300) -- a duplicate export request would arrive right behind the first
local tokens = export_tokens()
check(#tokens == 1, "exactly one export request per save")

local msgs = sse_messages()
local export_msg
for _, m in ipairs(msgs) do
  if m.type == "export" then
    export_msg = m
  end
end
check(
  export_msg and export_msg.scale == 2 and type(export_msg.token) == "string",
  "export request carries scale and token"
)

--- POST a fake rendered PNG back, the way the bridge page does.
local function post_export_result(png_bytes, export_token)
  local body = vim.json.encode({ png = "data:image/png;base64," .. vim.base64.encode(png_bytes), token = export_token })
  local body_file = tmp .. "/post-body.json"
  local bf = assert(io.open(body_file, "wb"))
  bf:write(body)
  bf:close()
  local done, res = false, nil
  vim.system({
    "curl",
    "-s",
    "-o",
    "/dev/null",
    "-w",
    "%{http_code}",
    "--max-time",
    "10",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Origin: " .. base,
    "--data-binary",
    "@" .. body_file,
    base .. "/export-result" .. auth,
  }, { text = true }, function(r)
    res = r
    done = true
  end)
  wait_for(function()
    return done
  end)
  return res and tonumber(res.stdout) or 0
end

local png1 = "\137PNG\r\n\26\n" .. string.rep("fake-png-payload-1\0\1\2", 64)
check(post_export_result(png1, tokens[1]) == 200, "bridge page can POST the export result")
check(
  wait_for(function()
    return read_file(png_file) == png1
  end),
  "PNG is written to disk with the exact posted bytes"
)
check(vim.fn.filereadable(png_file .. ".tmp") == 0, "no temp file is left behind (atomic write)")

-- A stale/unknown token must be ignored, not written.
local png_bogus = "BOGUS" .. string.rep("z", 128)
check(post_export_result(png_bogus, "not-a-real-token") == 200, "unknown-token POST is answered (and ignored)")
vim.wait(300)
check(read_file(png_file) == png1, "unknown-token PNG is not written to disk")

-- A second save must use a fresh token (uniqueness caught a real bug once).
child_cmd("write")
check(
  wait_for(function()
    return #export_tokens() == 2
  end),
  "second :w broadcasts a second export request"
)
tokens = export_tokens()
check(tokens[2] ~= tokens[1], "export tokens are unique across saves")

local png2 = "\137PNG\r\n\26\n" .. string.rep("fake-png-payload-2\3\4\5", 64)
post_export_result(png2, tokens[2])
check(
  wait_for(function()
    return read_file(png_file) == png2
  end),
  "second export overwrites the PNG"
)

-- ---------------------------------------------------------------------------
-- multi-buffer: the preview follows one buffer, exports work from any
-- ---------------------------------------------------------------------------

local buf1 = child_lua([[return vim.api.nvim_get_current_buf()]])

local drawio_file2 = tmp .. "/other.drawio"
local f2 = assert(io.open(drawio_file2, "wb"))
f2:write('<mxGraphModel><root><mxCell id="0"/></root><!-- OTHER --></mxGraphModel>\n')
f2:close()
child_cmd("edit " .. drawio_file2)
local buf2 = child_lua([[return vim.api.nvim_get_current_buf()]])

-- A buffer the preview does not follow must not hijack the page on edit.
child_lua(([[
  vim.api.nvim_buf_set_lines(%d, 0, -1, false,
    { '<mxGraphModel><root><mxCell id="0"/></root><!-- OTHER-EDIT --></mxGraphModel>' })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = %d })
]]):format(buf2, buf2))
vim.wait(400)
check(count_msgs(function(m)
  return m.type == "load" and m.xml:find("OTHER-EDIT", 1, true) ~= nil
end) == 0, "editing a non-followed buffer does not hijack the preview")

-- :DrawioExport from the second buffer: it loads its XML, renders, and the
-- preview is then given back to the followed buffer.
child_cmd("DrawioExport")
check(
  wait_for(function()
    return #export_tokens() == 3
  end),
  ":DrawioExport works from a non-followed buffer"
)
local function followed_loads()
  return count_msgs(function(m)
    return m.type == "load" and m.xml:find("<!-- B -->", 1, true) ~= nil
  end)
end
local followed_loads_before = followed_loads()

local png3 = "\137PNG\r\n\26\n" .. string.rep("fake-png-payload-3\6\7\8", 64)
post_export_result(png3, export_tokens()[3])
check(
  wait_for(function()
    return read_file(drawio_file2 .. ".png") == png3
  end),
  "the non-followed buffer gets its own PNG"
)
check(
  wait_for(function()
    return followed_loads() == followed_loads_before + 1
  end),
  "after the export the preview returns to the followed buffer"
)

-- :DrawioPreview in the second buffer moves the pin there...
child_cmd("DrawioPreview")
child_lua(([[
  vim.api.nvim_buf_set_lines(%d, 0, -1, false,
    { '<mxGraphModel><root><mxCell id="0"/></root><!-- OTHER-2 --></mxGraphModel>' })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = %d })
]]):format(buf2, buf2))
check(
  wait_for(function()
    return count_msgs(function(m)
      return m.type == "load" and m.xml:find("OTHER-2", 1, true) ~= nil
    end) == 1
  end),
  ":DrawioPreview re-pins the preview to the current buffer"
)

-- ...and the previously followed buffer stops pushing.
child_lua(([[
  vim.api.nvim_buf_set_lines(%d, 0, -1, false,
    { '<mxGraphModel><root><mxCell id="0"/></root><!-- A2 --></mxGraphModel>' })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = %d })
]]):format(buf1, buf1))
vim.wait(400)
check(count_msgs(function(m)
  return m.type == "load" and m.xml:find("A2", 1, true) ~= nil
end) == 0, "the previously followed buffer no longer pushes")

-- Back to the first buffer for the remaining checks.
child_cmd("buffer " .. buf1)
child_cmd("DrawioPreview")

-- ---------------------------------------------------------------------------
-- non-XML buffer: the export must be skipped, never rendered stale
-- ---------------------------------------------------------------------------

child_lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "not xml at all" })]])
child_cmd("write")
vim.wait(500)
check(#export_tokens() == 3, "saving a non-XML buffer does not broadcast an export request")
check(read_file(png_file) == png2, "PNG on disk is left untouched when the export is skipped")
local warn_messages = child_lua([[return vim.fn.execute("messages")]])
check(warn_messages:find("not valid XML", 1, true) ~= nil, "skipped export warns the user")

-- ---------------------------------------------------------------------------
-- :DrawioStop
-- ---------------------------------------------------------------------------

child_cmd("DrawioStop")
check(
  wait_for(function()
    return count_msgs(function(m)
      return m.type == "bye"
    end) == 1
  end),
  ":DrawioStop sends a farewell to open pages"
)
check(child_lua([[return require("drawio.server").is_running()]]) == false, ":DrawioStop shuts the server down")

-- After stop, saving must be quiet: no export attempts, no stray warnings.
child_cmd("write")
vim.wait(300)
local messages = child_lua([[return vim.fn.execute("messages")]])
check(
  not messages:find("no preview connected", 1, true) and not messages:find("timed out", 1, true),
  "no stray [drawio] warnings after :DrawioStop",
  messages
)

-- A second :DrawioStop is a no-op and must say so.
child_cmd("DrawioStop")
messages = child_lua([[return vim.fn.execute("messages")]])
check(messages:find("preview not running", 1, true) ~= nil, ":DrawioStop with nothing running says so")

-- ---------------------------------------------------------------------------
-- cleanup
-- ---------------------------------------------------------------------------

pcall(vim.fn.chanclose, chan)
sse_proc:kill(9)
child:kill(9)

print(("---\n%d checks, %d failures"):format(checks, failures))
os.exit(failures > 0 and 1 or 0)

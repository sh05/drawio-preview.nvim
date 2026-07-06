--- Headless smoke test for drawio-preview.nvim.
---
--- Run: nvim --clean -l tests/smoke.lua   (exits non-zero on any failure)
---
--- Exercises the HTTP/SSE server and config validation without a browser.
--- The server handles requests via vim.schedule, so every wait below must
--- pump the main loop with vim.wait; blocking on vim.system():wait() alone
--- would deadlock (it only pumps fast events).

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")
vim.opt.rtp:prepend(root)

local server = require("drawio.server")
local config = require("drawio.config")
local uv = vim.uv or vim.loop

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
  return vim.wait(timeout_ms or 5000, cond, 10)
end

--- Run curl to completion while pumping the main loop.
--- Returns { code = <http status>, body = <response body>, exit = <curl exit code> }.
local function curl(args)
  local done, res = false, nil
  local body_file = vim.fn.tempname()
  local cmd = { "curl", "-s", "-o", body_file, "-w", "%{http_code}", "--max-time", "10" }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(r)
    res = r
    done = true
  end)
  if not wait_for(function()
    return done
  end, 15000) then
    return nil, "curl timed out"
  end
  local body = ""
  local f = io.open(body_file, "rb")
  if f then
    body = f:read("*a")
    f:close()
  end
  os.remove(body_file)
  return { code = tonumber(res.stdout) or 0, body = body, exit = res.code }
end

-- ---------------------------------------------------------------------------
-- server: routes, Host/Origin validation, body reassembly, SSE
-- ---------------------------------------------------------------------------

local posts = {} -- accumulated on_post calls
local sse_connects = 0
local HTML = "<html>drawio-smoke-bridge</html>"

local port = server.start({
  port = 0,
  html = HTML,
  on_post = function(path, body)
    posts[#posts + 1] = { path = path, body = body }
  end,
  on_sse_connect = function()
    sse_connects = sse_connects + 1
  end,
})
check(type(port) == "number" and port > 0, "server starts on an ephemeral port")
check(server.is_running(), "is_running() reports true")

local base = "http://127.0.0.1:" .. port
local token = server.token
check(type(token) == "string" and #token == 32, "a per-session auth token is generated")
local auth = "?t=" .. token

-- Without (or with a wrong) token, every route is locked.
local r = curl({ base .. "/" })
check(r and r.code == 403, "GET / without the token is rejected")
r = curl({ base .. "/?t=wrong" })
check(r and r.code == 403, "GET / with a wrong token is rejected")
r = curl({ "-X", "POST", "--data", "x", base .. "/export-result" })
check(r and r.code == 403, "POST without the token is rejected")

r = curl({ base .. "/" .. auth })
check(r and r.code == 200 and r.body == HTML, "GET / serves the bridge page")

r = curl({ base .. "/index.html" .. auth })
check(r and r.code == 200 and r.body == HTML, "GET /index.html serves the bridge page")

r = curl({ "-H", "Host: localhost:" .. port, base .. "/" .. auth })
check(r and r.code == 200, "GET / accepts Host localhost:<port>")

r = curl({ "-H", "Host: evil.example:" .. port, base .. "/" .. auth })
check(r and r.code == 403, "GET / rejects a foreign Host (DNS rebinding)")

r = curl({ "-H", "Host: 127.0.0.1:1", base .. "/" .. auth })
check(r and r.code == 403, "GET / rejects a Host naming the wrong port")

r = curl({ base .. "/nope" .. auth })
check(r and r.code == 404, "GET on an unknown path is a 404")

r = curl({ "-X", "POST", "--data", "x", base .. "/nope" .. auth })
check(r and r.code == 404, "POST to an unknown path is a 404")

posts = {}
r = curl({ "-X", "POST", "--data", "hello", base .. "/export-result" .. auth })
check(
  r and r.code == 200 and #posts == 1 and posts[1].path == "/export-result" and posts[1].body == "hello",
  "POST /export-result without Origin (non-browser client) is accepted"
)

posts = {}
r = curl({ "-X", "POST", "-H", "Origin: " .. base, "--data", "hi", base .. "/export-result" .. auth })
check(r and r.code == 200 and #posts == 1, "POST with our own Origin is accepted")

posts = {}
r = curl({ "-X", "POST", "-H", "Origin: http://evil.example", "--data", "hi", base .. "/export-result" .. auth })
check(r and r.code == 403 and #posts == 0, "POST with a foreign Origin is rejected")

-- Large PNG payloads arrive in many TCP chunks; make sure reassembly is exact.
posts = {}
local big = string.rep("x", 3 * 1024 * 1024 - 1) .. "!"
local bigfile = vim.fn.tempname()
local bf = assert(io.open(bigfile, "wb"))
bf:write(big)
bf:close()
r = curl({ "-X", "POST", "--data-binary", "@" .. bigfile, base .. "/export-result" .. auth })
os.remove(bigfile)
check(r and r.code == 200, "3 MB POST gets a 200")
check(#posts == 1 and posts[1].body == big, "3 MB body is reassembled from chunks byte-for-byte")

-- ---------------------------------------------------------------------------
-- SSE: connect, broadcast, disconnect detection
-- ---------------------------------------------------------------------------

local sse_file = vim.fn.tempname()
local sse_proc = vim.system({ "curl", "-sN", "-o", sse_file, "--max-time", "60", base .. "/events" .. auth })

check(
  wait_for(function()
    return sse_connects == 1 and server.client_count() == 1
  end),
  "SSE client registers and on_sse_connect fires"
)

local function sse_messages()
  local f = io.open(sse_file, "rb")
  if not f then
    return {}
  end
  local text = f:read("*a")
  f:close()
  local msgs = {}
  for line in text:gmatch("data: ([^\n]+)") do
    local ok, msg = pcall(vim.json.decode, line)
    if ok then
      msgs[#msgs + 1] = msg
    end
  end
  return msgs
end

server.broadcast({ type = "load", xml = "<x/>" })
check(
  wait_for(function()
    local m = sse_messages()
    return #m == 1 and m[1].type == "load" and m[1].xml == "<x/>"
  end),
  "broadcast reaches the SSE client"
)

sse_proc:kill(9)
check(
  wait_for(function()
    return server.client_count() == 0
  end),
  "closed SSE connection is detected and dropped"
)
os.remove(sse_file)

-- ---------------------------------------------------------------------------
-- resource limits: body caps and idle reaping
-- ---------------------------------------------------------------------------

-- An oversized body is refused from its Content-Length alone, before any
-- of it is buffered.
server.max_export_body = 1024
posts = {}
local overfile = vim.fn.tempname()
local of = assert(io.open(overfile, "wb"))
of:write(string.rep("y", 4096))
of:close()
r = curl({ "-X", "POST", "--data-binary", "@" .. overfile, base .. "/export-result" .. auth })
os.remove(overfile)
check(r and r.code == 413 and #posts == 0, "over-cap POST body is refused with 413")
server.max_export_body = 64 * 1024 * 1024

r = curl({ "-X", "GET", "--data", "x", base .. "/" .. auth })
check(r and r.code == 413, "a body on a body-less route is refused with 413")

-- Connections that make no progress (half-open sockets, bodies that never
-- complete) are reaped by the idle timer instead of parking in memory.
server.idle_timeout_ms = 150
local reaped = false
local idle_sock = uv.new_tcp()
idle_sock:connect("127.0.0.1", port, function(cerr)
  if cerr then
    return
  end
  idle_sock:read_start(function(_, data)
    if not data then
      reaped = true
      if not idle_sock:is_closing() then
        idle_sock:close()
      end
    end
  end)
end)
check(
  wait_for(function()
    return reaped
  end, 3000),
  "idle connection is closed by the timeout"
)
server.idle_timeout_ms = 30000

server.stop()
check(not server.is_running(), "stop() shuts the server down")
r = curl({ base .. "/" .. auth })
check(r and r.code ~= 200, "stopped server no longer accepts connections")

-- A taken port must surface as a clean single-line error, not a stack trace.
local blocker = uv.new_tcp()
blocker:bind("127.0.0.1", 0)
local busy_port = blocker:getsockname().port
blocker:listen(1, function() end)
local sok, serr = pcall(server.start, { port = busy_port, html = HTML })
check(
  not sok and tostring(serr):find("failed to bind", 1, true) ~= nil,
  "starting on a taken port raises a clean error",
  tostring(serr)
)
check(not server.is_running(), "failed start leaves the server stopped")
blocker:close()

-- ---------------------------------------------------------------------------
-- config.setup() validation
-- ---------------------------------------------------------------------------

local ok = pcall(config.setup, { drawio_url = "https://example.com/" })
check(ok and config.options.drawio_url == "https://example.com", "setup strips trailing slashes from drawio_url")

check(not pcall(config.setup, { nope = 1 }), "unknown option is rejected")
check(not pcall(config.setup, { port = "8080" }), "wrong option type is rejected")

ok = pcall(config.setup, {})
check(ok and config.options.port == config.defaults.port, "empty setup keeps defaults")

-- Value validation: types alone let broken configs pass setup() and fail
-- much later in obscure ways (blank iframe, exec of the URL, bind errors).
check(not pcall(config.setup, { drawio_url = "localhost:8080" }), "schemeless drawio_url is rejected")
check(not pcall(config.setup, { drawio_url = 'https://x"y' }), "drawio_url with a quote is rejected")
check(not pcall(config.setup, { browser = {} }), "empty browser list is rejected")
check(not pcall(config.setup, { browser = { "chrome", 1 } }), "non-string browser entry is rejected")
check(not pcall(config.setup, { debounce_ms = -1 }), "negative debounce_ms is rejected")
check(not pcall(config.setup, { export_scale = 0 }), "zero export_scale is rejected")
check(not pcall(config.setup, { export_timeout_ms = 0 }), "zero export_timeout_ms is rejected")
check(not pcall(config.setup, { port = 99999 }), "out-of-range port is rejected")
check(not pcall(config.setup, { port = 1.5 }), "non-integer port is rejected")
check(not pcall(config.setup, { debounce_ms = 0 / 0 }), "NaN debounce_ms is rejected")
check(pcall(config.setup, { drawio_url = "HTTP://localhost:8080" }), "uppercase URL scheme is accepted")
check(pcall(config.setup, { port = 65535, debounce_ms = 0, browser = { "true" } }), "boundary values are accepted")
config.setup({})

print(("---\n%d checks, %d failures"):format(checks, failures))
os.exit(failures > 0 and 1 or 0)

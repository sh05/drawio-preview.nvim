--- Minimal HTTP + SSE server built on vim.uv (libuv).
---
--- Routes:
---   GET  /               -> bridge page (assets/index.html, templated)
---   GET  /events         -> Server-Sent Events stream (kept open)
---   POST /export-result  -> PNG payload posted back by the bridge page
---
--- This only ever talks to our own bridge page on 127.0.0.1, so the HTTP
--- parsing is intentionally minimal: request line + Content-Length body.
--- The Host header is still validated on every request (and Origin on
--- POSTs) so a hostile web page cannot reach us via DNS rebinding or
--- cross-site form posts.
local uv = vim.uv or vim.loop

local MAX_HEADER_BYTES = 8192

local M = {
  server = nil,
  port = nil,
  html = "",
  sse_clients = {}, -- set: client handle -> true
  on_post = nil, -- fun(path: string, body: string)
  on_sse_connect = nil, -- fun(client: uv_tcp_t)
}

--- write() that never throws. Returns false for dead clients so callers
--- can drop them.
local function safe_write(client, data)
  if client:is_closing() then
    return false
  end
  return (pcall(client.write, client, data))
end

local function drop_client(client)
  M.sse_clients[client] = nil
  if not client:is_closing() then
    client:close()
  end
end

--- Write a full HTTP response and close the connection.
local function respond(client, status, headers, body)
  body = body or ""
  headers["Content-Length"] = tostring(#body)
  local lines = { "HTTP/1.1 " .. status }
  for k, v in pairs(headers) do
    lines[#lines + 1] = k .. ": " .. v
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  safe_write(client, table.concat(lines, "\r\n"))
  pcall(client.shutdown, client, function()
    if not client:is_closing() then
      client:close()
    end
  end)
end

local function encode_sse(msg)
  local ok, data = pcall(vim.json.encode, msg)
  if not ok then
    vim.notify("[drawio] could not encode preview message (buffer not valid UTF-8?)", vim.log.levels.ERROR)
    return nil
  end
  return "data: " .. data .. "\n\n"
end

--- Send one SSE message (JSON payload) to a single client.
function M.send(client, msg)
  local data = encode_sse(msg)
  if data and not safe_write(client, data) then
    drop_client(client)
  end
end

--- Send one SSE message to every connected client.
function M.broadcast(msg)
  if not next(M.sse_clients) then
    return
  end
  local data = encode_sse(msg)
  if not data then
    return
  end
  for client in pairs(M.sse_clients) do
    if not safe_write(client, data) then
      drop_client(client)
    end
  end
end

function M.client_count()
  local n = 0
  for client in pairs(M.sse_clients) do
    if client:is_closing() then
      M.sse_clients[client] = nil
    else
      n = n + 1
    end
  end
  return n
end

--- Only loopback hosts naming our own port are legitimate; anything else
--- is a DNS-rebinding attempt (attacker-controlled name resolving to
--- 127.0.0.1) or a stray client.
local function host_allowed(host)
  if not host or not M.port then
    return false
  end
  host = host:lower():gsub("%s+$", "")
  local suffix = ":" .. tostring(M.port)
  return host == "127.0.0.1" .. suffix or host == "localhost" .. suffix or host == "[::1]" .. suffix
end

--- Browsers attach an Origin header to POSTs; require it to be our own
--- origin so other sites cannot forge export results. Absent Origin means
--- a non-browser client (curl etc.), which the Host check already covers.
local function origin_allowed(origin)
  if not origin then
    return true
  end
  local host = origin:lower():match("^https?://(.+)$")
  return host ~= nil and host_allowed(host)
end

local function handle_request(client, req)
  if not host_allowed(req.host) then
    respond(client, "403 Forbidden", { ["Connection"] = "close" }, "")
    return
  end
  if req.method == "GET" and (req.path == "/" or req.path == "/index.html") then
    respond(client, "200 OK", {
      ["Content-Type"] = "text/html; charset=utf-8",
      ["Cache-Control"] = "no-store",
      ["Connection"] = "close",
    }, M.html)
  elseif req.method == "GET" and req.path == "/events" then
    -- SSE: send headers, keep the socket open, register the client.
    safe_write(
      client,
      table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Connection: keep-alive",
        "",
        "",
      }, "\r\n")
    )
    M.sse_clients[client] = true
    -- Keep reading: without an active read, libuv never delivers EOF and
    -- a closed browser tab would stay in sse_clients forever. An open SSE
    -- GET never sends data, so anything received is ignored.
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        drop_client(client)
      end
    end)
    if M.on_sse_connect then
      M.on_sse_connect(client)
    end
  elseif req.method == "POST" and req.path == "/export-result" then
    if not origin_allowed(req.origin) then
      respond(client, "403 Forbidden", { ["Connection"] = "close" }, "")
      return
    end
    if M.on_post then
      M.on_post(req.path, req.body)
    end
    respond(client, "200 OK", {
      ["Content-Type"] = "text/plain",
      ["Connection"] = "close",
    }, "ok")
  else
    respond(client, "404 Not Found", { ["Connection"] = "close" }, "")
  end
end

local function on_connection(err)
  if err then
    vim.schedule(function()
      vim.notify("[drawio] accept error: " .. err, vim.log.levels.ERROR)
    end)
    return
  end
  local client = uv.new_tcp()
  M.server:accept(client)

  -- Per-connection parser state. Headers accumulate as a string (they are
  -- small and capped); the body accumulates as a chunk list so large PNG
  -- POSTs stay O(n) instead of re-copying on every chunk.
  local head_buf = ""
  local req
  local body_chunks, body_len = {}, 0

  client:read_start(function(rerr, chunk)
    if rerr or not chunk then
      drop_client(client)
      return
    end

    if not req then
      head_buf = head_buf .. chunk
      local pos = head_buf:find("\r\n\r\n", 1, true)
      if not pos then
        if #head_buf > MAX_HEADER_BYTES then
          client:close()
        end
        return -- headers not complete yet
      end
      local head = head_buf:sub(1, pos - 1)
      local lhead = head:lower()
      local method, path = head:match("^(%u+)%s+(%S+)")
      if not method then
        client:close()
        return
      end
      req = {
        method = method,
        path = path,
        host = lhead:match("\r\nhost:%s*([^\r\n]+)"),
        origin = lhead:match("\r\norigin:%s*([^\r\n]+)"),
        content_length = tonumber(lhead:match("\r\ncontent%-length:%s*(%d+)")) or 0,
      }
      local rest = head_buf:sub(pos + 4)
      head_buf = ""
      if #rest > 0 then
        body_chunks[1] = rest
        body_len = #rest
      end
    else
      body_chunks[#body_chunks + 1] = chunk
      body_len = body_len + #chunk
    end

    if body_len < req.content_length then
      return -- body not complete yet (large PNG POSTs arrive in chunks)
    end
    req.body = table.concat(body_chunks):sub(1, req.content_length)

    client:read_stop()
    vim.schedule(function()
      handle_request(client, req)
    end)
  end)
end

--- Start the server. Returns the bound port.
--- opts = { port, html, on_post, on_sse_connect }
function M.start(opts)
  if M.server then
    -- Already running; allow the HTML/callbacks to be refreshed.
    M.html = opts.html or M.html
    M.on_post = opts.on_post or M.on_post
    M.on_sse_connect = opts.on_sse_connect or M.on_sse_connect
    return M.port
  end

  M.html = opts.html or ""
  M.on_post = opts.on_post
  M.on_sse_connect = opts.on_sse_connect

  M.server = uv.new_tcp()
  -- A taken port fails at bind() on Linux but (SO_REUSEADDR) only at
  -- listen() on macOS; check both so the conflict surfaces everywhere.
  local ok, err = pcall(M.server.bind, M.server, "127.0.0.1", opts.port or 0)
  if ok then
    local lok, lerr = M.server:listen(128, on_connection)
    ok, err = lok == 0, lerr
  end
  if not ok then
    M.server:close()
    M.server = nil
    error(
      "[drawio] failed to bind 127.0.0.1:"
        .. tostring(opts.port)
        .. " ("
        .. tostring(err)
        .. ") — pick another port or set port = 0",
      0
    )
  end
  M.port = M.server:getsockname().port
  return M.port
end

function M.stop()
  for client in pairs(M.sse_clients) do
    -- shutdown (not close) so a just-broadcast farewell message is
    -- flushed before the FIN.
    pcall(client.shutdown, client, function()
      if not client:is_closing() then
        client:close()
      end
    end)
  end
  M.sse_clients = {}
  if M.server and not M.server:is_closing() then
    M.server:close()
  end
  M.server = nil
  M.port = nil
  M.html = ""
  M.on_post = nil
  M.on_sse_connect = nil
end

function M.is_running()
  return M.server ~= nil
end

return M

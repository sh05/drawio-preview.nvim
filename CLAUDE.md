# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A pure-Lua Neovim plugin (Neovim >= 0.10) for editing draw.io diagrams as XML with a live browser preview. On `:w` it writes both the `.drawio` source and a re-editable `.drawio.png` (PNG with embedded XML). There is no build step and no external dependencies — rendering happens inside an embedded draw.io editor in the browser, not via any CLI or headless browser.

## Development / testing

Two headless test scripts (no framework; non-zero exit on failure) live in `tests/`:

```sh
nvim --clean -l tests/smoke.lua   # server routes, Host/Origin validation, SSE, config
nvim --clean -l tests/e2e.lua    # curl plays the bridge page against a child Neovim
```

Both must pass before committing; CI runs them too. When adding waits, poll with `vim.wait` — `vim.system():wait()` only pumps fast events, so the scheduled request handler deadlocks otherwise.

For browser-facing changes, also verify manually by loading the plugin from the working tree:

```sh
nvim --clean --cmd "set rtp+=$(pwd)" test.drawio
```

Then `:DrawioPreview` (opens browser, live-updates on typing), `:w` (should write `test.drawio.png`), `:DrawioExport`, `:DrawioStop`, and `:checkhealth drawio` to exercise the full surface.

Lint before committing (CI runs both): `stylua --check .` and `luacheck lua plugin ftplugin ftdetect tests`.

## Architecture

Data flow is strictly one-way — the Neovim buffer is the single source of truth; nothing from the browser ever flows back into the buffer (only the exported PNG comes back, written to disk):

```
buffer change --debounce--> SSE {type=load}   --> bridge page --> postMessage --> draw.io iframe
:w / :DrawioExport ------> SSE {type=export}  --> iframe renders xmlpng
bridge page --POST /export-result (base64 PNG + token)--> Neovim writes <name>.drawio.png
```

The three moving parts:

- **`lua/drawio/init.lua`** — orchestration. Attaches autocmds (`TextChanged*` for debounced pushes, `BufWritePost` for export), correlates export requests with responses via `hrtime` tokens in `state.waiting_export` (30s timeout), decodes the base64 PNG and writes it to disk. Loads `assets/index.html` and templates `{{DRAWIO_URL}}` into it.
- **`lua/drawio/server.lua`** — a minimal hand-rolled HTTP + SSE server on `vim.uv`, bound to 127.0.0.1 only, with `Host` validation on every request (anti DNS-rebinding) and `Origin` validation on POSTs. Routes: `GET /` (bridge page), `GET /events` (SSE stream, held open; clients tracked in `sse_clients`, reads kept active so disconnects deliver EOF), `POST /export-result`. HTTP parsing is deliberately minimal (request line + Content-Length) since it only ever talks to its own bridge page; large PNG POSTs arrive in chunks, accumulated as a chunk list until Content-Length is satisfied. libuv callbacks hop back to the main loop via `vim.schedule` before touching Neovim APIs.
- **`assets/index.html`** — the bridge page served to the browser. Connects to `/events` via EventSource, embeds the draw.io editor as an iframe (`embed=1&proto=json`), and translates between SSE messages and draw.io's postMessage embed protocol. It buffers state (`lastXml`, `pendingExports`) until the editor sends `{event:'init'}`, and echoes the export token back through draw.io's `message` field.

Entry points: `ftdetect/drawio.lua` registers the `drawio` filetype (kept out of `plugin/` so lazy-loading managers detect the extension before the plugin loads); `plugin/drawio.lua` registers the three user commands; `ftplugin/drawio.lua` just reuses XML syntax/treesitter; `lua/drawio/config.lua` holds defaults merged (and validated) in `setup()`.

## Conventions and constraints

- Requires Neovim 0.10 APIs: `vim.base64`, `vim.system`, `vim.ui.open`, `vim.uv`. Use `vim.uv or vim.loop` for the uv handle.
- Never mutate the user's buffer — one-way data flow is a core design guarantee stated in the README.
- The export token round-trip (init.lua `request_export` → index.html `message.token` → `on_export_result`) is what matches a PNG response to its source file; keep it intact when touching export code.
- Config changes must be reflected in three places: `config.lua` defaults (with comments), the README "Configuration" section, and `health.lua` if checkable.

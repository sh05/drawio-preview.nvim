# drawio-preview.nvim

Edit [draw.io](https://www.drawio.com/) diagrams as plain XML in Neovim, with a
live preview in your browser. On `:w`, both the `.drawio` source **and** a
re-editable `.drawio.png` (PNG with the diagram XML embedded) are written.

Your XML buffer is the single source of truth — markdown-preview style. The
browser only renders; nothing ever flows back into your buffer, so your
hand-written formatting is never touched. (The one exception is the explicit
`:DrawioLayout` command, which rewrites the buffer on request — undoable in
a single step.)

> This is an unofficial project and is not affiliated with JGraph /
> diagrams.net. "draw.io" is a trademark of its respective owner.

## How it works

```
Neovim buffer (XML) --debounce--> local HTTP/SSE server --> browser
                                                             └ embedded draw.io editor (chromeless)
:w  --> .drawio written by Neovim as usual
    --> export request --> browser renders PNG --> POSTed back --> .drawio.png
```

No draw.io CLI, no Electron, no headless Chromium. Rendering and PNG export
happen inside the embedded draw.io editor in your browser.

## Requirements

- Neovim >= 0.10
- A web browser
- Internet access to `embed.diagrams.net`, **or** a self-hosted draw.io
  (e.g. the official `jgraph/drawio` Docker image) for offline use

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "sh05/drawio-preview.nvim",
  main = "drawio", -- lua module name (differs from the repo name)
  ft = "drawio",
  cmd = { "DrawioPreview", "DrawioExport", "DrawioStop" },
  opts = {},
}
```

## Usage

1. Open a `.drawio` file (or any buffer containing mxGraph XML).
2. `:DrawioPreview` — a browser tab opens and renders the diagram.
3. Type XML. The preview updates as you type (debounced).
4. `:w` — Neovim writes `foo.drawio`, and `foo.drawio.png` is written next to
   it a moment later.

Commands:

| Command                 | Description                                            |
| ----------------------- | ------------------------------------------------------ |
| `:DrawioPreview`        | Start the preview for the current buffer               |
| `:DrawioExport`         | Re-export `<name>.drawio.png` without saving           |
| `:DrawioStop`           | Stop the preview server                                |
| `:DrawioLayout {name}`  | Apply a draw.io auto-layout to the buffer (see below)  |

`:DrawioLayout` accepts `tree`, `flow`, `organic`, or `circle` and runs the
corresponding draw.io auto-layout on the diagram, **rewriting the buffer**
with the laid-out XML — the single deliberate exception to the one-way data
flow. It only ever runs on this explicit command, and the change is one
`u` away from being undone. Requires a connected preview.

### Minimal `.drawio` to get started

```xml
<mxGraphModel>
  <root>
    <mxCell id="0"/>
    <mxCell id="1" parent="0"/>
    <mxCell id="a" value="Hello" style="rounded=1;whiteSpace=wrap;" vertex="1" parent="1">
      <mxGeometry x="80" y="80" width="120" height="60" as="geometry"/>
    </mxCell>
    <mxCell id="b" value="World" style="rounded=1;whiteSpace=wrap;" vertex="1" parent="1">
      <mxGeometry x="80" y="240" width="120" height="60" as="geometry"/>
    </mxCell>
    <mxCell id="e1" style="edgeStyle=orthogonalEdgeStyle;" edge="1" parent="1" source="a" target="b">
      <mxGeometry relative="1" as="geometry"/>
    </mxCell>
  </root>
</mxGraphModel>
```

Vertices are positioned explicitly via `<mxGeometry x= y= width= height=>`.
Edges reference vertex ids with `source`/`target`; routing is automatic.

## Configuration

Defaults shown:

```lua
require("drawio").setup({
  port = 0,                                  -- 0 = pick a free port (integer 0..65535)
  drawio_url = "https://embed.diagrams.net", -- must be http(s)://; self-hosted works (offline use)
  debounce_ms = 500,                         -- delay (ms, >= 0) before pushing buffer changes
  export_on_write = true,                    -- write .drawio.png on :w
  export_scale = 2,                          -- PNG resolution multiplier (> 0)
  export_timeout_ms = 30000,                 -- how long (ms, > 0) to wait for the rendered PNG
  browser = nil,                             -- nil = system default browser
  -- browser = { "google-chrome", "--app" }, -- non-empty list of args; chromeless app window
})
```

`setup()` rejects invalid values (wrong types, out-of-range numbers, a
schemeless `drawio_url`, an empty `browser` list) immediately rather than
letting them fail later in obscure ways.

### Offline / self-hosted

```sh
docker run -d -p 8080:8080 jgraph/drawio
```

```lua
opts = { drawio_url = "http://localhost:8080" }
```

Diagram data never leaves your browser either way — the embed protocol runs
entirely client-side.

## Security

The preview server binds to `127.0.0.1` only and requires a random
per-session auth token on every request — it is embedded in the URL that
`:DrawioPreview` opens, so only that browser page can read the diagram or
post exports; other local processes (and other users on shared machines)
are locked out. On top of that it validates the `Host` header on every
request (blocking DNS-rebinding pages) and rejects cross-origin `POST`s.
Requests are vetted from their headers alone: bodies are capped (64 MB for
export uploads, none elsewhere, `413` beyond that) before anything is
buffered, and connections that stop making progress are closed after 30 s.

## Limitations

- One preview per Neovim instance, pinned to one buffer at a time:
  `:DrawioPreview` (re)pins it to the current buffer, and only the pinned
  buffer live-updates the browser. `:w` exports still work from any attached
  buffer — the preview briefly shows that buffer while it renders, then
  returns to the pinned one.
- After `:DrawioStop` the browser tab shows "preview stopped"; start again
  with `:DrawioPreview` (the page must be reopened — the port may change).
- Files not named `*.drawio` keep their extension in the export:
  `foo.xml` exports to `foo.xml.drawio.png`.

## Editing `.drawio.png` files directly

Opening a `.drawio.png` written by this plugin (or any draw.io "editable
PNG" that stores its XML uncompressed) loads the embedded diagram XML into
the buffer instead of binary bytes. Edit it like any `.drawio` buffer;
`:w` renders a fresh PNG through the running preview and replaces the file
in place — so saving needs `:DrawioPreview` connected, and the buffer keeps
its `modified` flag until the rendered PNG is actually on disk. PNGs whose
XML is compressed (`zTXt`) or missing open locked (non-modifiable) so a
save cannot destroy them.

## Roadmap

- CSV / Mermaid sources with automatic layout

## License

MIT

# drawio-preview.nvim

Edit [draw.io](https://www.drawio.com/) diagrams as plain XML in Neovim, with a
live preview in your browser. On `:w`, both the `.drawio` source **and** a
re-editable `.drawio.png` (PNG with the diagram XML embedded) are written.

Your XML buffer is the single source of truth — markdown-preview style. The
browser only renders; nothing ever flows back into your buffer, so your
hand-written formatting is never touched.

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

| Command          | Description                                    |
| ---------------- | ---------------------------------------------- |
| `:DrawioPreview` | Start the preview for the current buffer       |
| `:DrawioExport`  | Re-export `<name>.drawio.png` without saving   |
| `:DrawioStop`    | Stop the preview server                        |

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

The preview server binds to `127.0.0.1` only, validates the `Host` header on
every request (blocking DNS-rebinding pages from reading your diagram), and
rejects cross-origin `POST`s. Other processes of the *same* local user can
still connect, as with any localhost preview server.

## Limitations

- One preview per Neovim instance. All attached buffers share it, and the
  browser shows whichever buffer changed last.
- After `:DrawioStop` the browser tab shows "preview stopped"; start again
  with `:DrawioPreview` (the page must be reopened — the port may change).
- Files not named `*.drawio` keep their extension in the export:
  `foo.xml` exports to `foo.xml.drawio.png`.

## Roadmap

- Open existing `.drawio.png` files directly (extract embedded XML on read)
- `:DrawioLayout` — apply draw.io auto-layouts (tree/flow/organic/…) to the buffer
- CSV / Mermaid sources with automatic layout

## License

MIT

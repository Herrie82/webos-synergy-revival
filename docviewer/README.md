# Document Viewer (PoC) — newer file types beyond frozen QuickOffice

A thin, **view-only** document viewer that covers the file types the native QuickOffice
engine can't — without touching that engine. This is a **proof of concept**: the open-a-
local-file mechanism and the zero-dependency renderers work end-to-end; the heavy formats
(PDF/DOCX/XLSX) are wired and ready but need their JS library dropped in (see
[`com.palm.app.docviewer/lib/README.md`](com.palm.app.docviewer/lib/README.md)).

## Why

QuickOffice's actual renderer, `arxservice`, is a **closed, feature-frozen 2012 ARM/NPAPI
binary** (Office ~2010 OOXML + an old PDF viewer). It can't be extended and there's no newer
webOS build. But the QuickOffice / file-picker reroute we already built **lands the file
bytes on local disk first** — so anything that can read a local file can render it. This app
is that "anything." Leave `arx` to the legacy formats it still handles; route everything
else here.

## The one architectural fact that shapes it

A webOS 3.0.5 web-app **card runs in the stock system webview — WebKit ~2009**. That's fine
for plain text and `<img>`, but it **cannot run modern PDF.js / mammoth / SheetJS**. So the
viewer splits by format across two rendering surfaces:

| Format | Surface | Renderer | Deps |
|---|---|---|---|
| `txt md log csv json xml …` | **in-card** (stock webview) | XHR file:// → `<pre>` | **none** ✅ |
| `png jpg jpeg gif bmp svg` | **in-card** (stock webview) | `<img src=file://…>` | **none** ✅ |
| `pdf` | **Atlas** (WPE, modern JS) | PDF.js → canvas | vendored |
| `docx` | **Atlas** (WPE, modern JS) | mammoth → HTML | vendored |
| `xlsx` | **Atlas** (WPE, modern JS) | SheetJS → HTML table | vendored |
| `pptx`, others | — | graceful "no renderer / Open raw in Atlas" | — |

Atlas (`org.webosports.app.atlas`, `mode:"simple"`) is the **same modern WPE engine the
OAuth logins use**. The card launches it at the render harness
([`render/harness.html`](com.palm.app.docviewer/render/harness.html)), which loads the one
vendored library it needs and renders the local document. Same philosophy as the connectors:
leave the 2009 layer alone, push modern work into Atlas.

## How a caller opens a file

The file-picker (or the QuickOffice reroute's "open" action) launches the viewer with the
already-downloaded **local path** — it does not need to know how each format is rendered:

```js
// see com.palm.app.docviewer/source/launcher.js for the drop-in kind
this.$.dvLauncher.open("/media/internal/.qo/123-report.pdf",
                       { name: "report.pdf", mime: "application/pdf" });
// => applicationManager/launch com.palm.app.docviewer with params:{ target, name, mime }
```

The viewer detects the type by extension, renders in-card if it can, or hands off to Atlas.

### Wiring into the existing reroute

QuickOffice's `RemoteFileService`/`FileStore` "open" path currently hands the downloaded
cache file to the native `arx` viewer. To adopt this viewer, branch on extension at that
open point: known-good legacy Office/PDF → keep `arx`; everything else → `DocViewerLauncher.open(localPath)`.
No service or OAuth changes — the bytes are already local (that's what `downloadFile` / the
reroute guarantee).

## What's proven vs stubbed (PoC honesty)

- ✅ **Dispatch + open-local-file mechanism** — extension routing, `enyo.windowParams` target,
  manual path box for standalone testing, Atlas launch via `applicationManager/launch`.
- ✅ **Zero-dependency renderers** — text (`<pre>` from a file:// XHR) and images (`<img>`)
  render in the card with no libraries; these are also the end-to-end proof that reading a
  local file and displaying it works.
- ✅ **Atlas hand-off + harness** — PDF.js / mammoth / SheetJS integration code is written and
  guarded; it renders as soon as the library file is present, and shows a clear "drop the
  library here" message when it isn't (no white screen).
- ⏳ **Vendored libraries** — not committed; drop them in per `lib/README.md`.
- ⚠️ **file:// XHR under WPE** — file→file reads work on most WebKit/WPE builds; a hardened
  build may block them. Workaround documented in `lib/README.md`. Affects only the Atlas
  formats; the card's text/image paths use the same trick and are the zero-dep proof.
- ❌ **Not editing, not conversion** — view-only by design. On-device format conversion
  (LibreOffice-headless etc.) is far too heavy for a TouchPad and is out of scope.

## Effort / risk

Small relative to a connector: one Enyo card + a standalone harness + three vendored libs.
No service, OAuth, or TLS plumbing (the bytes arrive local). Main risk is the WPE `file://`
access flag above; the fallback ("Open raw in Atlas") still proves the pipe with zero deps,
and Atlas natively renders images/text/HTML and often PDF without any library at all.

## Layout

```
com.palm.app.docviewer/
  appinfo.json depends.js framework_config.json index.html icon.png
  source/docViewer.js     the card: dispatch, in-card text/image, Atlas hand-off
  source/launcher.js      drop-in kind showing how a caller opens a file (reference)
  stylesheets/doc-viewer.css
  render/harness.html     modern-JS page Atlas loads (NOT the card)
  render/harness.js       PDF.js / mammoth / SheetJS render logic + graceful degradation
  render/harness.css
  lib/README.md           exact vendoring instructions (+ file:// caveat)
  lib/{pdfjs,mammoth,sheetjs}/   drop library files here
```

# Third-party notices

EveryAI includes code and files from the projects below. Each entry says what
was taken, where it lives in this repository, and the license it is under.

## Mermaid 11.17.2

- **What:** `mermaid.min.js`, unmodified, from jsDelivr (`https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js`).
- **Where:** `frontend/assets/web/mermaid.min.js`
- **License:** MIT

```
The MIT License (MIT)

Copyright (c) 2014 - 2022 Knut Sveidqvist

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## LibreChat v0.8.8

- **What:** the Mermaid SVG fix-up (`processMermaidSvg`, `applyMermaidBackground`,
  `fixSubgraphTitleContrast`) and the 2x canvas PNG export, ported from
  `client/src/utils/diagram/export.ts` and `client/src/utils/mermaid.ts`.
- **Where:** `frontend/assets/web/mermaid_export.js`
- **License:** MIT

```
MIT License

Copyright (c) 2026 LibreChat

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Excalidraw 0.18.1 and mermaid-to-excalidraw 3.1.0

- **What:** the Excalidraw editor (`@excalidraw/excalidraw@0.18.1`) and the
  Mermaid converter (`@excalidraw/mermaid-to-excalidraw@3.1.0`, which uses
  `pele@1.8.0`), with React 19.2.5 (`react`, `react-dom`). They are not copied
  into the repository: the drawing page loads these pinned versions from
  jsDelivr (`https://cdn.jsdelivr.net/npm/…/+esm`) inside the web sandbox, and
  Excalidraw's fonts come from the same package. Their own dependencies (also
  from jsDelivr) carry their own licenses.
- **Where:** `frontend/lib/features/artifacts/ui/renderers/drawing_page.dart`
- **License:** MIT, for each package, with these copyright lines:
  - Excalidraw: Copyright (c) 2020 Excalidraw
  - mermaid-to-excalidraw: Copyright (c) 2023 Excalidraw
  - pele: Copyright (c) 2026 kepano
  - React: Copyright (c) Meta Platforms, Inc. and affiliates.

```
MIT License

Copyright (c) <year> <copyright holders>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

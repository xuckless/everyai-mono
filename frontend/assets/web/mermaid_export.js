// Checks and renders Mermaid diagrams for the app: parse errors for the model,
// a cleaned-up SVG and a 2x PNG for exports. Runs in a hidden webview next to
// the bundled mermaid.min.js.
//
// The SVG fix-up (processMermaidSvg, applyMermaidBackground,
// fixSubgraphTitleContrast) and the canvas PNG export are ported from
// LibreChat v0.8.8, client/src/utils/diagram/export.ts and
// client/src/utils/mermaid.ts. Copyright (c) 2026 LibreChat, MIT License; see
// THIRD_PARTY_NOTICES.md.
"use strict";

(function () {
  const PNG_EXPORT_SCALE = 2;
  const MAX_CANVAS_DIMENSION = 16384;
  const MAX_CANVAS_PIXELS = 16777216;

  // No HTML labels: they are foreignObject, which taints the canvas and
  // breaks the PNG export.
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    htmlLabels: false,
    flowchart: { htmlLabels: false },
    suppressErrorRendering: true,
    theme: "default",
    fontFamily: "-apple-system, system-ui, 'Segoe UI', Roboto, sans-serif",
  });

  function absoluteDimension(value) {
    const normalized = (value || "").trim();
    if (!/^(?:\d+(?:\.\d+)?|\.\d+)(?:px)?$/i.test(normalized)) return 0;
    return parseFloat(normalized);
  }

  function applyFallbackFixes(svg) {
    let result = svg;
    if (!svg.includes("viewBox") && svg.includes("height=") && svg.includes("width=")) {
      const w = svg.match(/width="([\d.]+)"/);
      const h = svg.match(/height="([\d.]+)"/);
      if (w && h) result = result.replace("<svg", `<svg viewBox="0 0 ${w[1]} ${h[1]}"`);
    }
    if (!result.includes("xmlns")) result = result.replace("<svg", '<svg xmlns="http://www.w3.org/2000/svg"');
    return result;
  }

  function roundMermaidNodeCorners(svgElement) {
    const radius = 8;
    for (const rect of svgElement.querySelectorAll("g.node rect")) {
      const current = Number.parseFloat(rect.getAttribute("rx") || "");
      if (Number.isFinite(current) && current >= radius) continue;
      rect.setAttribute("rx", String(radius));
      rect.setAttribute("ry", String(radius));
    }
  }

  // Perceived luminance (0 = black, 1 = white), BT.601 luma.
  function hexLuminance(hex) {
    let h = hex.replace("#", "");
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    if (h.length < 6) return -1;
    const r = parseInt(h.slice(0, 2), 16) / 255;
    const g = parseInt(h.slice(2, 4), 16) / 255;
    const b = parseInt(h.slice(4, 6), 16) / 255;
    return 0.299 * r + 0.587 * g + 0.114 * b;
  }

  // Subgraph titles take their colour from a theme rule; on a subgraph with
  // its own light or dark fill that can leave them unreadable.
  function fixSubgraphTitleContrast(svgElement) {
    for (const cluster of svgElement.querySelectorAll("g.cluster")) {
      const rect = cluster.querySelector(":scope > rect, :scope > polygon");
      if (!rect) continue;
      const inlineStyle = rect.getAttribute("style") || "";
      const attrFill = rect.getAttribute("fill") || "";
      const styleFill = inlineStyle.match(/fill\s*:\s*(#[0-9a-fA-F]{3,8})/);
      const hex = styleFill ? styleFill[1] : attrFill.startsWith("#") ? attrFill : "";
      if (!hex) continue;
      const bgLum = hexLuminance(hex);
      if (bgLum < 0) continue;
      const isLightBg = bgLum > 0.5;
      for (const text of cluster.querySelectorAll(":scope > g.cluster-label text, :scope > text, :scope > g > text")) {
        const textFill = text.getAttribute("fill") || "";
        const textStyle = text.getAttribute("style") || "";
        const textStyleFill = textStyle.match(/fill\s*:\s*(#[0-9a-fA-F]{3,8})/);
        const currentHex = textStyleFill ? textStyleFill[1] : textFill.startsWith("#") ? textFill : "";
        let newFill = "";
        if (!currentHex) {
          if (isLightBg) newFill = "#1a1a1a";
        } else {
          const textLum = hexLuminance(currentHex);
          if (textLum < 0) continue;
          if (isLightBg && textLum > 0.5) newFill = "#1a1a1a";
          else if (!isLightBg && textLum < 0.4) newFill = "#f0f0f0";
        }
        if (newFill) {
          const sep = textStyle ? (textStyle.trimEnd().endsWith(";") ? " " : "; ") : "";
          text.setAttribute("style", `${textStyle}${sep}fill: ${newFill}`);
        }
      }
    }
  }

  // A standalone SVG with a viewBox and no fixed size, plus its size.
  function processMermaidSvg(svg) {
    const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
    const svgElement = doc.querySelector("svg");
    if (doc.querySelector("parsererror") || !svgElement) return { svg: applyFallbackFixes(svg), dimensions: null };

    let width = absoluteDimension(svgElement.getAttribute("width"));
    let height = absoluteDimension(svgElement.getAttribute("height"));
    if (!width || !height) {
      const viewBox = svgElement.getAttribute("viewBox");
      if (viewBox) {
        const parts = viewBox.split(/[\s,]+/).map(Number);
        if (parts.length === 4) {
          width = parts[2];
          height = parts[3];
        }
      }
    }
    let dimensions = null;
    if (width > 0 && height > 0) {
      dimensions = { width, height };
      if (!svgElement.getAttribute("viewBox")) svgElement.setAttribute("viewBox", `0 0 ${width} ${height}`);
      svgElement.removeAttribute("width");
      svgElement.removeAttribute("height");
      svgElement.removeAttribute("style");
    }
    if (!svgElement.getAttribute("xmlns")) svgElement.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    fixSubgraphTitleContrast(svgElement);
    roundMermaidNodeCorners(svgElement);
    return { svg: new XMLSerializer().serializeToString(doc), dimensions };
  }

  function applyMermaidBackground(svg, background) {
    if (!background) return svg;
    const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
    const svgElement = doc.querySelector("svg");
    if (!svgElement || doc.querySelector("parsererror")) return svg;
    const viewBox = (svgElement.getAttribute("viewBox") || "").split(/[\s,]+/).map(Number);
    const hasViewBox = viewBox.length === 4 && viewBox.every(Number.isFinite) && viewBox[2] > 0 && viewBox[3] > 0;
    const bg = doc.createElementNS("http://www.w3.org/2000/svg", "rect");
    bg.setAttribute("x", hasViewBox ? String(viewBox[0]) : "0");
    bg.setAttribute("y", hasViewBox ? String(viewBox[1]) : "0");
    bg.setAttribute("width", hasViewBox ? String(viewBox[2]) : "100%");
    bg.setAttribute("height", hasViewBox ? String(viewBox[3]) : "100%");
    bg.setAttribute("fill", background);
    svgElement.insertBefore(bg, svgElement.firstChild);
    return new XMLSerializer().serializeToString(doc);
  }

  function resolveCanvasDimensions(width, height) {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      throw new Error("the diagram has no size");
    }
    const scale = Math.min(
      PNG_EXPORT_SCALE,
      MAX_CANVAS_DIMENSION / width,
      MAX_CANVAS_DIMENSION / height,
      Math.sqrt(MAX_CANVAS_PIXELS / (width * height)),
    );
    // Rounded down, so the product stays inside the pixel budget.
    return { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) };
  }

  function loadSvgImage(svg) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error("the SVG could not be loaded as an image"));
      image.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
    });
  }

  // Base64 PNG of [svg] at up to 2x, on [background].
  async function pngOf(svg, dimensions, background) {
    const image = await loadSvgImage(svg);
    const w = (dimensions && dimensions.width) || image.naturalWidth || image.width;
    const h = (dimensions && dimensions.height) || image.naturalHeight || image.height;
    const size = resolveCanvasDimensions(w, h);
    const canvas = document.createElement("canvas");
    canvas.width = size.width;
    canvas.height = size.height;
    const context = canvas.getContext("2d");
    if (!context) throw new Error("no canvas");
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = "high";
    if (background) {
      context.fillStyle = background;
      context.fillRect(0, 0, canvas.width, canvas.height);
    }
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/png").replace(/^data:image\/png;base64,/, "");
  }

  function messageOf(e) {
    if (!e) return "unknown error";
    if (typeof e === "string") return e;
    return String(e.message || e.str || e);
  }

  let counter = 0;

  // {ok:false, error} for source Mermaid rejects; otherwise {ok:true, svg,
  // width, height, png?, png_error?} (the PNG may fail on its own).
  window.everyaiRenderMermaid = async function (source) {
    try {
      await mermaid.parse(source);
    } catch (e) {
      return { ok: false, error: messageOf(e) };
    }
    const id = "everyai-diagram-" + ++counter;
    let rendered;
    try {
      rendered = await mermaid.render(id, source);
    } catch (e) {
      return { ok: false, error: messageOf(e) };
    } finally {
      for (const el of document.querySelectorAll(`#${id}, #d${id}`)) el.remove();
    }
    const processed = processMermaidSvg(rendered.svg);
    const dims = processed.dimensions;
    const result = { ok: true, svg: processed.svg, width: dims ? dims.width : 0, height: dims ? dims.height : 0 };
    try {
      result.png = await pngOf(applyMermaidBackground(processed.svg, "#ffffff"), dims, "#ffffff");
    } catch (e) {
      result.png_error = messageOf(e);
    }
    return result;
  };
})();

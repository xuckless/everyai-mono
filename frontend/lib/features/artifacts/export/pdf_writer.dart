import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'doc_model.dart';
import 'svg_raster.dart';

/// Fonts for [buildPdf]: a Unicode body family and a monospace one.
typedef PdfFonts = ({ByteData regular, ByteData bold, ByteData italic, ByteData boldItalic, ByteData mono});

const _ink = PdfColor.fromInt(0xFF1F1F29);
const _muted = PdfColor.fromInt(0xFF6B6B7B);
const _rule = PdfColor.fromInt(0xFFDDDDE5);
const _codeFill = PdfColor.fromInt(0xFFF4F4F8);
const _link = PdfColor.fromInt(0xFF5B3FD9);

/// A paginated A4 PDF of [blocks]. Figures come pre-rasterized: SVG in
/// [figures] (keyed by SVG source), Mermaid in [diagrams] (keyed by source)
/// and display math in [equations] (keyed by TeX). A diagram or equation
/// without an image is printed as its source.
Future<Uint8List> buildPdf({
  required String title,
  required List<DocBlock> blocks,
  required PdfFonts fonts,
  Map<String, RasterFigure> figures = const {},
  Map<String, RasterFigure> diagrams = const {},
  Map<String, RasterFigure> equations = const {},
}) {
  final mono = pw.Font.ttf(fonts.mono);
  final doc = pw.Document(
    title: title,
    creator: 'EveryAI',
    theme: pw.ThemeData.withFont(
      base: pw.Font.ttf(fonts.regular),
      bold: pw.Font.ttf(fonts.bold),
      italic: pw.Font.ttf(fonts.italic),
      boldItalic: pw.Font.ttf(fonts.boldItalic),
    ).copyWith(defaultTextStyle: const pw.TextStyle(fontSize: 10.5, lineSpacing: 2.5, color: _ink)),
  );

  pw.TextSpan span(DocRun r) => pw.TextSpan(
    text: r.text,
    style: pw.TextStyle(
      font: r.code ? mono : null,
      fontSize: r.code ? 9.5 : null,
      fontWeight: r.bold ? pw.FontWeight.bold : null,
      fontStyle: r.italic && !r.code ? pw.FontStyle.italic : null,
      decoration: r.strike ? pw.TextDecoration.lineThrough : (r.link != null ? pw.TextDecoration.underline : null),
      color: r.link != null ? _link : null,
      background: r.code ? const pw.BoxDecoration(color: _codeFill) : null,
    ),
    annotation: r.link != null ? pw.AnnotationUrl(r.link!) : null,
  );
  pw.Widget text(List<DocRun> runs, {pw.TextStyle? style, pw.TextAlign align = pw.TextAlign.left}) => pw.RichText(
    textAlign: align,
    text: pw.TextSpan(style: style, children: [for (final r in runs) span(r)]),
  );

  pw.Widget codeBox(String code, {String? caption}) {
    // Containers don't split across pages, so long code is cut into chunks.
    final lines = code.split('\n');
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        if (caption != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 3),
            child: pw.Text(caption, style: const pw.TextStyle(fontSize: 8.5, color: _muted)),
          ),
        for (var i = 0; i < lines.length; i += 45)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            color: _codeFill,
            child: pw.Text(
              lines.sublist(i, (i + 45).clamp(0, lines.length)).join('\n'),
              style: pw.TextStyle(font: mono, fontSize: 8.5, lineSpacing: 1.5),
            ),
          ),
      ],
    );
  }

  pw.Widget? image(RasterFigure? f) {
    if (f == null) return null;
    try {
      return pw.Center(
        child: pw.Image(pw.MemoryImage(f.png), width: f.width, height: f.height, fit: pw.BoxFit.contain),
      );
    } on Object {
      return null;
    }
  }

  pw.Widget figure(RasterFigure? f) =>
      image(f) ?? pw.Text('[Figure could not be drawn]', style: const pw.TextStyle(color: _muted));

  // Every block becomes its own top-level widget (nested ones indented), so
  // MultiPage can break between any two of them.
  List<pw.Widget> render(List<DocBlock> blocks, {double indent = 0, bool quoted = false}) {
    final out = <pw.Widget>[];
    for (final b in blocks) {
      switch (b) {
        case ListBlock(:final ordered, :final start, :final items):
          for (final (i, item) in items.indexed) {
            final marker = DocRun(ordered ? '${start + i}.  ' : '•  ');
            final first = item.firstOrNull;
            final rest = first is ParagraphBlock ? item.skip(1).toList() : item;
            if (first is ParagraphBlock) {
              out.addAll(
                render(
                  [
                    ParagraphBlock([marker, ...first.runs]),
                  ],
                  indent: indent,
                  quoted: quoted,
                ),
              );
            }
            out.addAll(render(rest, indent: indent + 16, quoted: quoted));
          }
          continue;
        case QuoteBlock(:final blocks):
          out.addAll(render(blocks, indent: indent, quoted: true));
          continue;
        default:
      }
      final child = switch (b) {
        HeadingBlock(:final level, :final runs) => text(
          runs,
          style: pw.TextStyle(
            fontSize: const [20.0, 16.0, 13.5, 12.0, 11.0, 10.5][(level - 1).clamp(0, 5)],
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        ParagraphBlock(:final runs) => text(runs, style: quoted ? const pw.TextStyle(color: _muted) : null),
        CodeBlock(:final language, text: final code) => codeBox(code, caption: language.isEmpty ? null : language),
        FigureBlock(:final svg) => figure(figures[svg]),
        DiagramBlock(:final source) => image(diagrams[source]) ?? codeBox(source, caption: 'Diagram (Mermaid source)'),
        MathBlock(:final tex) =>
          image(equations[tex]) ??
              pw.Center(
                child: pw.Text(tex, style: pw.TextStyle(font: mono, fontSize: 9.5)),
              ),
        TableBlock(:final header, :final rows) => pw.Table(
          border: pw.TableBorder.all(color: _rule, width: 0.6),
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _codeFill),
              children: [
                for (final c in header)
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: text(c, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9.5)),
                  ),
              ],
            ),
            for (final r in rows)
              pw.TableRow(
                children: [
                  for (var i = 0; i < header.length; i++)
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: text(i < r.length ? r[i] : const [], style: const pw.TextStyle(fontSize: 9.5)),
                    ),
                ],
              ),
          ],
        ),
        RuleBlock() => pw.Divider(color: _rule, thickness: 0.6),
        ListBlock() || QuoteBlock() => throw StateError('handled above'),
      };
      final heading = b is HeadingBlock;
      out.add(
        pw.Container(
          margin: pw.EdgeInsets.only(left: indent, bottom: heading ? 4 : 7, top: heading ? 8 : 0),
          padding: quoted ? const pw.EdgeInsets.only(left: 10) : null,
          decoration: quoted
              ? const pw.BoxDecoration(
                  border: pw.Border(left: pw.BorderSide(color: _rule, width: 2.5)),
                )
              : null,
          child: child,
        ),
      );
    }
    return out;
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.symmetric(horizontal: 56, vertical: 52),
      maxPages: 500,
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: _muted),
        ),
      ),
      build: (_) => render(blocks),
    ),
  );
  return doc.save();
}

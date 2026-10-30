import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'doc_model.dart';
import 'svg_raster.dart';

/// A Word document (.docx) of [blocks]: headings, paragraphs, lists, tables,
/// code, quotes, and figures (pre-rasterized in [figures], keyed by SVG
/// source). Mermaid diagrams and display math are written as their source.
Uint8List buildDocx({
  required String title,
  required List<DocBlock> blocks,
  Map<String, RasterFigure> figures = const {},
}) {
  final body = StringBuffer();
  final rels = <String>[]; // extra relationships of document.xml
  final media = <String, Uint8List>{}; // word/media/<name> → bytes
  var drawingId = 0;

  String esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s).replaceAll('"', '&quot;');

  String rel(String type, String target, {bool external = false}) {
    final id = 'rId${rels.length + 10}';
    rels.add(
      '<Relationship Id="$id" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/$type" '
      'Target="${esc(target)}"${external ? ' TargetMode="External"' : ''}/>',
    );
    return id;
  }

  String run(DocRun r) {
    final props = [
      if (r.bold) '<w:b/>',
      if (r.italic && !r.code) '<w:i/>',
      if (r.strike) '<w:strike/>',
      if (r.code) '<w:rStyle w:val="CodeChar"/>',
      if (r.link != null) '<w:rStyle w:val="Hyperlink"/>',
    ].join();
    final parts = r.text.split('\n');
    final text = [
      for (final (i, p) in parts.indexed) ...[if (i > 0) '<w:br/>', '<w:t xml:space="preserve">${esc(p)}</w:t>'],
    ].join();
    final xml = '<w:r>${props.isEmpty ? '' : '<w:rPr>$props</w:rPr>'}$text</w:r>';
    if (r.link case final href? when href.startsWith('http')) {
      return '<w:hyperlink r:id="${rel('hyperlink', href, external: true)}">$xml</w:hyperlink>';
    }
    return xml;
  }

  void paragraph(String runs, {String? style, int indent = 0, String? extra}) {
    final props = [
      if (style != null) '<w:pStyle w:val="$style"/>',
      if (indent > 0) '<w:ind w:left="$indent"/>',
      ?extra,
    ].join();
    body.write('<w:p>${props.isEmpty ? '' : '<w:pPr>$props</w:pPr>'}$runs</w:p>');
  }

  void code(String text, {int indent = 0}) {
    for (final line in text.split('\n')) {
      paragraph('<w:r><w:t xml:space="preserve">${esc(line)}</w:t></w:r>', style: 'Code', indent: indent);
    }
  }

  void figure(RasterFigure f) {
    final name = 'image${media.length + 1}.png';
    media[name] = f.png;
    final id = rel('image', 'media/$name');
    drawingId++;
    // 1 pt = 12700 EMU.
    final cx = (f.width * 12700).round();
    final cy = (f.height * 12700).round();
    body.write(
      '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>'
      '<wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="$cx" cy="$cy"/>'
      '<wp:docPr id="$drawingId" name="Figure $drawingId"/>'
      '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
      '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:nvPicPr><pic:cNvPr id="$drawingId" name="$name"/><pic:cNvPicPr/></pic:nvPicPr>'
      '<pic:blipFill><a:blip r:embed="$id"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
      '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>',
    );
  }

  void write(List<DocBlock> blocks, {int indent = 0, bool quoted = false}) {
    for (final b in blocks) {
      switch (b) {
        case HeadingBlock(:final level, :final runs):
          paragraph(runs.map(run).join(), style: 'Heading${level.clamp(1, 6)}');
        case ParagraphBlock(:final runs):
          paragraph(runs.map(run).join(), style: quoted ? 'Quote' : null, indent: indent);
        case ListBlock(:final ordered, :final start, :final items):
          for (final (i, item) in items.indexed) {
            final marker = DocRun(ordered ? '${start + i}.\t' : '•\t');
            final first = item.firstOrNull;
            if (first is ParagraphBlock) {
              paragraph(
                [marker, ...first.runs].map(run).join(),
                style: quoted ? 'Quote' : null,
                extra: '<w:ind w:left="${indent + 360}" w:hanging="360"/>',
              );
              write(item.skip(1).toList(), indent: indent + 360, quoted: quoted);
            } else {
              write(item, indent: indent + 360, quoted: quoted);
            }
          }
        case CodeBlock(text: final t):
          code(t, indent: indent);
        case FigureBlock(:final svg):
          if (figures[svg] case final f?) {
            figure(f);
          } else {
            paragraph(run(const DocRun('[Figure could not be drawn]', italic: true)));
          }
        case DiagramBlock(:final source):
          paragraph(run(const DocRun('Diagram (Mermaid source)', italic: true)), indent: indent);
          code(source, indent: indent);
        case MathBlock(:final tex):
          paragraph(run(DocRun(tex, code: true)), extra: '<w:jc w:val="center"/>');
        case TableBlock(:final header, :final rows):
          String cell(List<DocRun> runs, {bool head = false}) =>
              '<w:tc><w:p>${(head ? runs.map((r) => DocRun(r.text, bold: true, code: r.code)) : runs).map(run).join()}</w:p></w:tc>';
          body.write(
            '<w:tbl><w:tblPr><w:tblStyle w:val="Table"/><w:tblW w:w="5000" w:type="pct"/></w:tblPr>'
            '<w:tr>${header.map((c) => cell(c, head: true)).join()}</w:tr>'
            '${rows.map((r) => '<w:tr>${[for (var i = 0; i < header.length; i++) cell(i < r.length ? r[i] : const [])].join()}</w:tr>').join()}'
            '</w:tbl>',
          );
          paragraph('');
        case QuoteBlock(:final blocks):
          write(blocks, indent: indent, quoted: true);
        case RuleBlock():
          paragraph('', extra: '<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="DDDDE5"/></w:pBdr>');
      }
    }
  }

  write(blocks);

  const ns =
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"';
  final document =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document $ns><w:body>$body'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>'
      '</w:sectPr></w:body></w:document>';

  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('[Content_Types].xml', _contentTypes);
  add('_rels/.rels', _rootRels);
  add('docProps/core.xml', _core(esc(title)));
  add('word/document.xml', document);
  add('word/styles.xml', _styles);
  add(
    'word/_rels/document.xml.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '${rels.join()}</Relationships>',
  );
  for (final e in media.entries) {
    archive.addFile(ArchiveFile('word/media/${e.key}', e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _contentTypes =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Default Extension="png" ContentType="image/png"/>'
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
    '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
    '</Types>';

const _rootRels =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
    '</Relationships>';

String _core(String title) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>$title</dc:title><dc:creator>EveryAI</dc:creator>'
    '</cp:coreProperties>';

String _heading(int level, int halfPoints) =>
    '<w:style w:type="paragraph" w:styleId="Heading$level"><w:name w:val="heading $level"/>'
    '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
    '<w:pPr><w:keepNext/><w:spacing w:before="${level == 1 ? 360 : 240}" w:after="120"/><w:outlineLvl w:val="${level - 1}"/></w:pPr>'
    '<w:rPr><w:b/><w:sz w:val="$halfPoints"/></w:rPr></w:style>';

final _styles =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>'
    '<w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
    '${[
      for (final (i, size) in const [40, 32, 28, 24, 22, 22].indexed) _heading(i + 1, size),
    ].join()}'
    '<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>'
    '<w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F4F4F8"/></w:pPr>'
    '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="18"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>'
    '<w:pPr><w:ind w:left="360"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="DDDDE5"/></w:pBdr></w:pPr>'
    '<w:rPr><w:color w:val="6B6B7B"/></w:rPr></w:style>'
    '<w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/>'
    '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="F4F4F8"/></w:rPr></w:style>'
    '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
    '<w:rPr><w:color w:val="5B3FD9"/><w:u w:val="single"/></w:rPr></w:style>'
    '<w:style w:type="table" w:styleId="Table"><w:name w:val="Table"/><w:tblPr>'
    '<w:tblBorders><w:top w:val="single" w:sz="4" w:color="DDDDE5"/><w:left w:val="single" w:sz="4" w:color="DDDDE5"/>'
    '<w:bottom w:val="single" w:sz="4" w:color="DDDDE5"/><w:right w:val="single" w:sz="4" w:color="DDDDE5"/>'
    '<w:insideH w:val="single" w:sz="4" w:color="DDDDE5"/><w:insideV w:val="single" w:sz="4" w:color="DDDDE5"/></w:tblBorders>'
    '<w:tblCellMar><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>'
    '</w:styles>';

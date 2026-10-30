import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A slide for [buildPptx]: a title, bullets and/or a body paragraph, notes.
typedef PptxSlide = ({String title, List<String> bullets, String body, String notes, bool isTitle});

/// Deck colors as `RRGGBB`.
typedef PptxColors = ({String background, String title, String text, String accent});

/// Writes a minimal, valid PowerPoint (OOXML) deck: one master, one blank
/// layout, a theme, and per slide a title box, a body box, an accent bar and
/// a solid background. Speaker notes are not written yet.
Uint8List buildPptx({required String title, required List<PptxSlide> slides, required PptxColors colors}) {
  final files = <String, String>{
    '[Content_Types].xml': _contentTypes(slides.length),
    '_rels/.rels': _rootRels,
    'docProps/core.xml': _core(title),
    'docProps/app.xml': _app(slides.length),
    'ppt/presentation.xml': _presentation(slides.length),
    'ppt/_rels/presentation.xml.rels': _presentationRels(slides.length),
    'ppt/slideMasters/slideMaster1.xml': _master,
    'ppt/slideMasters/_rels/slideMaster1.xml.rels': _rels([
      ('rId1', _relLayout, '../slideLayouts/slideLayout1.xml'),
      ('rId2', _relTheme, '../theme/theme1.xml'),
    ]),
    'ppt/slideLayouts/slideLayout1.xml': _layout,
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels': _rels([('rId1', _relMaster, '../slideMasters/slideMaster1.xml')]),
    'ppt/theme/theme1.xml': _theme,
    for (final (i, s) in slides.indexed) ...{
      'ppt/slides/slide${i + 1}.xml': _slide(s, colors),
      'ppt/slides/_rels/slide${i + 1}.xml.rels': _rels([('rId1', _relLayout, '../slideLayouts/slideLayout1.xml')]),
    },
  };
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

// 16:9 at EMU (914400 per inch): 13.333in × 7.5in.
const _w = 12192000;
const _h = 6858000;

const _ns =
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';
const _decl = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const _relBase = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _relLayout = '$_relBase/slideLayout';
const _relMaster = '$_relBase/slideMaster';
const _relTheme = '$_relBase/theme';
const _relSlide = '$_relBase/slide';

String _x(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s).replaceAll('"', '&quot;');

String _rels(List<(String, String, String)> rels) =>
    '$_decl<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '${rels.map((r) => '<Relationship Id="${r.$1}" Type="${r.$2}" Target="${r.$3}"/>').join()}'
    '</Relationships>';

String _contentTypes(int n) =>
    '$_decl<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
    '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
    '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
    '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
    '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
    '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
    '${[for (var i = 1; i <= n; i++) '<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'].join()}'
    '</Types>';

const _rootRels =
    '$_decl<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="$_relBase/officeDocument" Target="ppt/presentation.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
    '<Relationship Id="rId3" Type="$_relBase/extended-properties" Target="docProps/app.xml"/>'
    '</Relationships>';

String _core(String title) =>
    '$_decl<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    '<dc:title>${_x(title)}</dc:title><dc:creator>EveryAI</dc:creator></cp:coreProperties>';

String _app(int n) =>
    '$_decl<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
    '<Application>EveryAI</Application><Slides>$n</Slides></Properties>';

String _presentation(int n) =>
    '$_decl<p:presentation $_ns>'
    '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
    '<p:sldIdLst>${[for (var i = 0; i < n; i++) '<p:sldId id="${256 + i}" r:id="rId${i + 3}"/>'].join()}</p:sldIdLst>'
    '<p:sldSz cx="$_w" cy="$_h"/><p:notesSz cx="6858000" cy="9144000"/>'
    '</p:presentation>';

String _presentationRels(int n) => _rels([
  ('rId1', _relMaster, 'slideMasters/slideMaster1.xml'),
  ('rId2', _relTheme, 'theme/theme1.xml'),
  for (var i = 0; i < n; i++) ('rId${i + 3}', _relSlide, 'slides/slide${i + 1}.xml'),
]);

const _emptyTree =
    '<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
    '</p:spTree></p:cSld>';

const _master =
    '$_decl<p:sldMaster $_ns>$_emptyTree'
    '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" '
    'accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
    '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
    '</p:sldMaster>';

const _layout =
    '$_decl<p:sldLayout $_ns type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>'
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
    '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>';

String _fill(String rgb) => '<a:solidFill><a:srgbClr val="$rgb"/></a:solidFill>';

String _box(int id, String name, int x, int y, int cx, int cy, String paragraphs) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
    '<p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>$paragraphs</p:txBody></p:sp>';

String _run(String text, {required int size, required String color, bool bold = false}) =>
    '<a:r><a:rPr lang="en-US" sz="$size"${bold ? ' b="1"' : ''} dirty="0">${_fill(color)}'
    '<a:latin typeface="Calibri"/></a:rPr><a:t>${_x(text)}</a:t></a:r>';

String _slide(PptxSlide s, PptxColors c) {
  final shapes = StringBuffer();
  const margin = 914400; // 1in
  if (s.isTitle) {
    shapes
      ..write(_bar(2, margin, 2286000, c.accent))
      ..write(
        _box(
          3,
          'Title',
          margin,
          2514600,
          _w - 2 * margin,
          1371600,
          '<a:p>${_run(s.title, size: 4800, color: c.title, bold: true)}</a:p>',
        ),
      )
      ..write(
        s.body.isEmpty
            ? ''
            : _box(
                4,
                'Subtitle',
                margin,
                3962400,
                _w - 2 * margin,
                914400,
                '<a:p>${_run(s.body, size: 2400, color: c.text)}</a:p>',
              ),
      );
  } else {
    shapes
      ..write(
        _box(
          2,
          'Title',
          margin,
          609600,
          _w - 2 * margin,
          914400,
          '<a:p>${_run(s.title, size: 3600, color: c.title, bold: true)}</a:p>',
        ),
      )
      ..write(_bar(3, margin, 1600200, c.accent));
    final paragraphs = StringBuffer();
    for (final b in s.bullets) {
      paragraphs.write(
        '<a:p><a:pPr marL="342900" indent="-342900"><a:spcAft><a:spcPts val="1200"/></a:spcAft>'
        '<a:buClr><a:srgbClr val="${c.accent}"/></a:buClr><a:buFont typeface="Arial"/><a:buChar char="&#8226;"/></a:pPr>'
        '${_run(b, size: 2200, color: c.text)}</a:p>',
      );
    }
    for (final line in s.body.split('\n').where((l) => l.trim().isNotEmpty)) {
      paragraphs.write(
        '<a:p><a:pPr><a:spcAft><a:spcPts val="800"/></a:spcAft></a:pPr>'
        '${_run(line.replaceAll(RegExp(r'(\*\*|__|`|^#+\s*)'), ''), size: 2000, color: c.text)}</a:p>',
      );
    }
    if (paragraphs.isEmpty) paragraphs.write('<a:p><a:endParaRPr lang="en-US"/></a:p>');
    shapes.write(_box(4, 'Body', margin, 1905000, _w - 2 * margin, _h - 1905000 - 685800, paragraphs.toString()));
  }
  return '$_decl<p:sld $_ns><p:cSld>'
      '<p:bg><p:bgPr>${_fill(c.background)}<a:effectLst/></p:bgPr></p:bg>'
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
      '$shapes</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';
}

String _bar(int id, int x, int y, String color) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="Accent"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="822960" cy="64008"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>${_fill(color)}<a:ln><a:noFill/></a:ln></p:spPr></p:sp>';

const _theme =
    '$_decl<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="EveryAI">'
    '<a:themeElements><a:clrScheme name="EveryAI">'
    '<a:dk1><a:srgbClr val="1C1B22"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>'
    '<a:dk2><a:srgbClr val="2B2A33"/></a:dk2><a:lt2><a:srgbClr val="F2F1F7"/></a:lt2>'
    '<a:accent1><a:srgbClr val="6E56CF"/></a:accent1><a:accent2><a:srgbClr val="2FA866"/></a:accent2>'
    '<a:accent3><a:srgbClr val="E8833A"/></a:accent3><a:accent4><a:srgbClr val="3B8FE5"/></a:accent4>'
    '<a:accent5><a:srgbClr val="D9488B"/></a:accent5><a:accent6><a:srgbClr val="C9A227"/></a:accent6>'
    '<a:hlink><a:srgbClr val="3B8FE5"/></a:hlink><a:folHlink><a:srgbClr val="6E56CF"/></a:folHlink>'
    '</a:clrScheme><a:fontScheme name="EveryAI">'
    '<a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
    '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>'
    '</a:fontScheme><a:fmtScheme name="EveryAI">'
    '<a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>'
    '<a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>'
    '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>'
    '<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>'
    '</a:fmtScheme></a:themeElements></a:theme>';

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';

import '../domain/slide_spec.dart';

/// A picture for a slide: the PNG every PowerPoint shows, the SVG newer ones draw instead (sharp at any zoom),
/// and its size, for fitting it into its box.
typedef PptxPicture = ({Uint8List png, String? svg, double width, double height});

/// One slide to write: its laid-out elements, and the pictures they name, drawn.
typedef PptxPage = ({DeckSlide slide, Map<String, PptxPicture> pictures});

/// Writes a valid PowerPoint (OOXML) deck: one master, one blank layout, a theme, and per slide its own
/// background and elements as native, editable objects: text boxes (fill, padding, alignment, bullets, bold and
/// italic runs), shapes, lines and arrows, tables, and pictures (PNG with an SVG for PowerPoint 2016 and later).
/// Slides with notes get a notes page (under a notes master with its own theme), shown as speaker notes.
Uint8List buildPptx({required String title, required List<PptxPage> pages}) {
  final noted = [
    for (final (i, p) in pages.indexed)
      if (p.slide.notes.trim().isNotEmpty) i + 1,
  ];
  final media = <String, Uint8List>{};
  final slideFiles = <String, String>{};
  for (final (i, page) in pages.indexed) {
    final rels = <(String, String, String)>[
      ('rId1', _relLayout, '../slideLayouts/slideLayout1.xml'),
      if (noted.contains(i + 1)) ('rId2', _relNotesSlide, '../notesSlides/notesSlide${i + 1}.xml'),
    ];
    final pictureRels = <String, ({String png, String? svg})>{};
    for (final e in page.pictures.entries) {
      final n = media.length + 1;
      media['ppt/media/image$n.png'] = e.value.png;
      final pngRel = 'rId${rels.length + 1}';
      rels.add((pngRel, _relImage, '../media/image$n.png'));
      String? svgRel;
      if (e.value.svg case final svg?) {
        media['ppt/media/image$n.svg'] = Uint8List.fromList(utf8.encode(svg));
        svgRel = 'rId${rels.length + 1}';
        rels.add((svgRel, _relImage, '../media/image$n.svg'));
      }
      pictureRels[e.key] = (png: pngRel, svg: svgRel);
    }
    slideFiles['ppt/slides/slide${i + 1}.xml'] = _slide(page, pictureRels);
    slideFiles['ppt/slides/_rels/slide${i + 1}.xml.rels'] = _rels(rels);
  }
  final files = <String, String>{
    '[Content_Types].xml': _contentTypes(pages.length, noted),
    '_rels/.rels': _rootRels,
    'docProps/core.xml': _core(title),
    'docProps/app.xml': _app(pages.length),
    'ppt/presentation.xml': _presentation(pages.length, notes: noted.isNotEmpty),
    'ppt/_rels/presentation.xml.rels': _presentationRels(pages.length, notes: noted.isNotEmpty),
    'ppt/slideMasters/slideMaster1.xml': _master,
    'ppt/slideMasters/_rels/slideMaster1.xml.rels': _rels([
      ('rId1', _relLayout, '../slideLayouts/slideLayout1.xml'),
      ('rId2', _relTheme, '../theme/theme1.xml'),
    ]),
    'ppt/slideLayouts/slideLayout1.xml': _layout,
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels': _rels([('rId1', _relMaster, '../slideMasters/slideMaster1.xml')]),
    'ppt/theme/theme1.xml': _theme,
    if (noted.isNotEmpty) ...{
      'ppt/notesMasters/notesMaster1.xml': _notesMaster,
      'ppt/notesMasters/_rels/notesMaster1.xml.rels': _rels([('rId1', _relTheme, '../theme/theme2.xml')]),
      'ppt/theme/theme2.xml': _theme,
    },
    ...slideFiles,
    for (final i in noted) ...{
      'ppt/notesSlides/notesSlide$i.xml': _notesSlide(pages[i - 1].slide.notes),
      'ppt/notesSlides/_rels/notesSlide$i.xml.rels': _rels([
        ('rId1', _relNotesMaster, '../notesMasters/notesMaster1.xml'),
        ('rId2', _relSlide, '../slides/slide$i.xml'),
      ]),
    },
  };
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  for (final e in media.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
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
const _relNotesMaster = '$_relBase/notesMaster';
const _relNotesSlide = '$_relBase/notesSlide';
const _relImage = '$_relBase/image';
const _ctBase = 'application/vnd.openxmlformats-officedocument';

String _x(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s).replaceAll('"', '&quot;');

String _rels(List<(String, String, String)> rels) =>
    '$_decl<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '${rels.map((r) => '<Relationship Id="${r.$1}" Type="${r.$2}" Target="${r.$3}"/>').join()}'
    '</Relationships>';

String _contentTypes(int n, List<int> noted) =>
    '$_decl<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Default Extension="png" ContentType="image/png"/>'
    '<Default Extension="svg" ContentType="image/svg+xml"/>'
    '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
    '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
    '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
    '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
    '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
    '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
    '${[for (var i = 1; i <= n; i++) '<Override PartName="/ppt/slides/slide$i.xml" ContentType="$_ctBase.presentationml.slide+xml"/>'].join()}'
    '${noted.isEmpty ? '' : '<Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="$_ctBase.presentationml.notesMaster+xml"/>'
              '<Override PartName="/ppt/theme/theme2.xml" ContentType="$_ctBase.theme+xml"/>'}'
    '${[for (final i in noted) '<Override PartName="/ppt/notesSlides/notesSlide$i.xml" ContentType="$_ctBase.presentationml.notesSlide+xml"/>'].join()}'
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

String _presentation(int n, {required bool notes}) =>
    '$_decl<p:presentation $_ns>'
    '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
    '${notes ? '<p:notesMasterIdLst><p:notesMasterId r:id="rId${n + 3}"/></p:notesMasterIdLst>' : ''}'
    '<p:sldIdLst>${[for (var i = 0; i < n; i++) '<p:sldId id="${256 + i}" r:id="rId${i + 3}"/>'].join()}</p:sldIdLst>'
    '<p:sldSz cx="$_w" cy="$_h"/><p:notesSz cx="6858000" cy="9144000"/>'
    '</p:presentation>';

String _presentationRels(int n, {required bool notes}) => _rels([
  ('rId1', _relMaster, 'slideMasters/slideMaster1.xml'),
  ('rId2', _relTheme, 'theme/theme1.xml'),
  for (var i = 0; i < n; i++) ('rId${i + 3}', _relSlide, 'slides/slide${i + 1}.xml'),
  if (notes) ('rId${n + 3}', _relNotesMaster, 'notesMasters/notesMaster1.xml'),
]);

// Notes pages are portrait 7.5in × 10in: the slide picture on top, the notes below.
const _notesSlideImage = '<a:xfrm><a:off x="381000" y="685800"/><a:ext cx="6096000" cy="3429000"/></a:xfrm>';
const _notesBody = '<a:xfrm><a:off x="685800" y="4343400"/><a:ext cx="5486400" cy="4114800"/></a:xfrm>';

String _placeholder(int id, String name, String ph, String spPr, {String locks = '<a:spLocks noGrp="1"/>'}) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/><p:cNvSpPr>$locks</p:cNvSpPr><p:nvPr>$ph</p:nvPr></p:nvSpPr>'
    '<p:spPr>$spPr</p:spPr>';

const _groupProps =
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

final _notesMaster =
    '$_decl<p:notesMaster $_ns><p:cSld><p:spTree>$_groupProps'
    '${_placeholder(2, 'Slide Image Placeholder 1', '<p:ph type="sldImg" idx="2"/>', '$_notesSlideImage<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/>', locks: '<a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/>')}</p:sp>'
    '${_placeholder(3, 'Notes Placeholder 2', '<p:ph type="body" sz="quarter" idx="3"/>', '$_notesBody<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>')}'
    '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>'
    '</p:spTree></p:cSld>'
    '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" '
    'accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
    '<p:notesStyle><a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">'
    '<a:defRPr sz="1200" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>'
    '<a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:notesStyle>'
    '</p:notesMaster>';

/// A notes page: the slide picture and [notes], one paragraph per line.
String _notesSlide(String notes) =>
    '$_decl<p:notes $_ns><p:cSld><p:spTree>$_groupProps'
    '${_placeholder(2, 'Slide Image Placeholder 1', '<p:ph type="sldImg"/>', '', locks: '<a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/>')}</p:sp>'
    '${_placeholder(3, 'Notes Placeholder 2', '<p:ph type="body" idx="1"/>', '')}'
    '<p:txBody><a:bodyPr/><a:lstStyle/>'
    '${notes.trim().split('\n').map(_notesParagraph).join()}'
    '</p:txBody></p:sp>'
    '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>';

String _notesParagraph(String line) => line.trim().isEmpty
    ? '<a:p><a:endParaRPr lang="en-US"/></a:p>'
    : '<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>${_x(line.trimRight())}</a:t></a:r></a:p>';

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

/// Canvas units (960×540) to EMU: the slide is 13.333 in wide, so one unit is 12700 EMU (one point).
int _emu(double v) => (v * 12700).round();

String _hex(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// A colour, with its alpha (and the element's opacity) when not opaque.
String _clr(Color c, [double opacity = 1]) {
  final a = (c.a * opacity).clamp(0.0, 1.0);
  return '<a:srgbClr val="${_hex(c)}">${a < 1 ? '<a:alpha val="${(a * 100000).round()}"/>' : ''}</a:srgbClr>';
}

String _fillOf(Color? c, [double opacity = 1]) =>
    c == null || c.a == 0 ? '<a:noFill/>' : '<a:solidFill>${_clr(c, opacity)}</a:solidFill>';

String _lineOf(Color? c, double width, [double opacity = 1, String ends = '']) => c == null || width <= 0
    ? '<a:ln><a:noFill/></a:ln>'
    : '<a:ln w="${_emu(width)}"><a:solidFill>${_clr(c, opacity)}</a:solidFill>$ends</a:ln>';

String _xfrm(Rect box, double rotation, {bool flipH = false, bool flipV = false}) =>
    '<a:xfrm${rotation != 0 ? ' rot="${(rotation * 60000).round()}"' : ''}${flipH ? ' flipH="1"' : ''}${flipV ? ' flipV="1"' : ''}>'
    '<a:off x="${_emu(box.left)}" y="${_emu(box.top)}"/><a:ext cx="${_emu(box.width.abs())}" cy="${_emu(box.height.abs())}"/></a:xfrm>';

String _geom(String prst, [String adj = '']) => '<a:prstGeom prst="$prst"><a:avLst>$adj</a:avLst></a:prstGeom>';

/// The rounding of a roundRect, as PowerPoint's adjust value (a share of the shorter side, at most half).
String _round(double radius, Rect box) {
  final short = box.width.abs() < box.height.abs() ? box.width.abs() : box.height.abs();
  final share = short <= 0 ? 0 : (radius / short * 100000).round().clamp(0, 50000);
  return '<a:gd name="adj" fmla="val $share"/>';
}

String _nv(int id, String name, {String extra = ''}) =>
    '<p:nvSpPr><p:cNvPr id="$id" name="${_x(name)}"/><p:cNvSpPr$extra/><p:nvPr/></p:nvSpPr>';

String _runsXml(TextElement e, SlideParagraph p) => [
  for (final r in p.runs)
    '<a:r><a:rPr lang="en-US" sz="${(e.size * 100).round()}"'
        '${r.bold || e.weight.value >= 600 ? ' b="1"' : ''}${r.italic ? ' i="1"' : ''} dirty="0">'
        '<a:solidFill>${_clr(e.color, e.opacity)}</a:solidFill><a:latin typeface="${e.font.office}"/></a:rPr>'
        '<a:t>${_x(r.text)}</a:t></a:r>',
].join();

String _paragraphs(TextElement e) {
  final algn = switch (e.align) {
    TextAlign.center => 'ctr',
    TextAlign.right => 'r',
    _ => 'l',
  };
  // PowerPoint's single spacing is about 1.2× the font size.
  final spacing = '<a:lnSpc><a:spcPct val="${(e.lineHeight / 1.2 * 100000).round()}"/></a:lnSpc>';
  final out = StringBuffer();
  for (final p in e.paragraphs) {
    final indent = _emu(e.size * 1.1);
    final props = p.bullet
        ? '<a:pPr algn="$algn" marL="$indent" indent="-$indent">$spacing'
              '<a:buClr>${_clr(e.bulletColor ?? e.color)}</a:buClr><a:buFont typeface="Arial"/><a:buChar char="&#8226;"/></a:pPr>'
        : '<a:pPr algn="$algn">$spacing<a:buNone/></a:pPr>';
    out.write('<a:p>$props');
    out.write(p.runs.isEmpty ? '<a:endParaRPr lang="en-US" sz="${(e.size * 100).round()}"/>' : _runsXml(e, p));
    out.write('</a:p>');
  }
  if (e.paragraphs.isEmpty) out.write('<a:p><a:endParaRPr lang="en-US"/></a:p>');
  return out.toString();
}

String _text(int id, TextElement e) {
  final inset = _emu(e.padding);
  final anchor = switch (e.valign) {
    VAlign.top => 't',
    VAlign.middle => 'ctr',
    VAlign.bottom => 'b',
  };
  return '<p:sp>${_nv(id, e.name ?? 'Text $id', extra: ' txBox="1"')}'
      '<p:spPr>${_xfrm(e.box, e.rotation)}${e.radius > 0 ? _geom('roundRect', _round(e.radius, e.box)) : _geom('rect')}'
      '${_fillOf(e.fill, e.opacity)}${_lineOf(e.border, 2, e.opacity)}</p:spPr>'
      '<p:txBody><a:bodyPr wrap="square" lIns="$inset" tIns="$inset" rIns="$inset" bIns="$inset" anchor="$anchor">'
      '<a:noAutofit/></a:bodyPr><a:lstStyle/>${_paragraphs(e)}</p:txBody></p:sp>';
}

String _shape(int id, ShapeElement e) {
  if (e.kind == ShapeKind.line || e.kind == ShapeKind.arrow) {
    final box = Rect.fromLTWH(
      e.box.width < 0 ? e.box.left + e.box.width : e.box.left,
      e.box.height < 0 ? e.box.top + e.box.height : e.box.top,
      e.box.width.abs(),
      e.box.height.abs(),
    );
    final ends = e.kind == ShapeKind.arrow ? '<a:tailEnd type="triangle" w="med" len="med"/>' : '';
    return '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="$id" name="${_x(e.name ?? 'Line $id')}"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>'
        '<p:spPr>${_xfrm(box, e.rotation, flipH: e.box.width < 0, flipV: e.box.height < 0)}${_geom('line')}'
        '${_lineOf(e.stroke ?? e.fill ?? const Color(0xFF000000), e.strokeWidth > 0 ? e.strokeWidth : 3, e.opacity, ends)}'
        '</p:spPr></p:cxnSp>';
  }
  final geom = switch (e.kind) {
    ShapeKind.rounded => _geom('roundRect', _round(e.radius, e.box)),
    ShapeKind.ellipse => _geom('ellipse'),
    _ => _geom('rect'),
  };
  return '<p:sp>${_nv(id, e.name ?? 'Shape $id')}<p:spPr>${_xfrm(e.box, e.rotation)}$geom'
      '${_fillOf(e.fill, e.opacity)}${_lineOf(e.stroke, e.strokeWidth, e.opacity)}</p:spPr>'
      '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>';
}

String _table(int id, TableElement e) {
  final cols = e.columns;
  if (cols == 0 || e.rows.isEmpty) return '';
  final colW = _emu(e.box.width / cols);
  final rowH = _emu(e.box.height / e.rows.length);
  final border = '<a:solidFill>${_clr(e.stroke ?? const Color(0x33000000))}</a:solidFill>';
  String cell(String text, {required bool head}) {
    final fill = head ? e.headerFill : e.fill;
    final color = head ? (e.headerColor ?? e.color) : e.color;
    final pad = _emu(e.size * 0.6);
    return '<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="${(e.size * 100).round()}"'
        '${head ? ' b="1"' : ''} dirty="0"><a:solidFill>${_clr(color, e.opacity)}</a:solidFill>'
        '<a:latin typeface="${SlideFont.sans.office}"/></a:rPr><a:t>${_x(text)}</a:t></a:r></a:p></a:txBody>'
        '<a:tcPr marL="$pad" marR="$pad" anchor="ctr"><a:lnL><a:noFill/></a:lnL><a:lnR><a:noFill/></a:lnR>'
        '<a:lnT w="9525">$border</a:lnT><a:lnB w="9525">$border</a:lnB>${_fillOf(fill, e.opacity)}</a:tcPr></a:tc>';
  }

  final rows = [
    for (final (i, r) in e.rows.indexed)
      '<a:tr h="$rowH">${[for (var c = 0; c < cols; c++) cell(c < r.length ? r[c] : '', head: i == 0 && e.header)].join()}</a:tr>',
  ].join();
  return '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="$id" name="${_x(e.name ?? 'Table $id')}"/>'
      '<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>'
      '<p:xfrm><a:off x="${_emu(e.box.left)}" y="${_emu(e.box.top)}"/><a:ext cx="${_emu(e.box.width)}" cy="${_emu(e.box.height)}"/></p:xfrm>'
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>'
      '<a:tblPr firstRow="${e.header ? 1 : 0}"/><a:tblGrid>${'<a:gridCol w="$colW"/>' * cols}</a:tblGrid>$rows'
      '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>';
}

String _picture(int id, PictureElement e, PptxPicture? pic, ({String png, String? svg})? rel) {
  if (pic == null || rel == null) return '';
  // Contain: the largest box of the picture's shape inside the element's, centred. Cover: crop the picture.
  final ratio = pic.width <= 0 || pic.height <= 0 ? 1.0 : pic.width / pic.height;
  var box = e.box;
  var crop = '';
  if (e.fit == PictureFit.contain) {
    final w = e.box.width / e.box.height > ratio ? e.box.height * ratio : e.box.width;
    final h = w / ratio;
    box = Rect.fromLTWH(e.box.left + (e.box.width - w) / 2, e.box.top + (e.box.height - h) / 2, w, h);
  } else {
    final boxRatio = e.box.width / e.box.height;
    if (boxRatio > ratio) {
      final cut = ((1 - ratio / boxRatio) / 2 * 100000).round();
      crop = '<a:srcRect t="$cut" b="$cut"/>';
    } else {
      final cut = ((1 - boxRatio / ratio) / 2 * 100000).round();
      crop = '<a:srcRect l="$cut" r="$cut"/>';
    }
  }
  final svg = rel.svg == null
      ? ''
      : '<a:extLst><a:ext uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}">'
            '<asvg:svgBlip xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main" r:embed="${rel.svg}"/>'
            '</a:ext></a:extLst>';
  return '<p:pic><p:nvPicPr><p:cNvPr id="$id" name="${_x(e.name ?? e.ref)}"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
      '<p:blipFill><a:blip r:embed="${rel.png}">${e.opacity < 1 ? '<a:alphaModFix amt="${(e.opacity * 100000).round()}"/>' : ''}$svg</a:blip>'
      '$crop<a:stretch><a:fillRect/></a:stretch></p:blipFill>'
      '<p:spPr>${_xfrm(box, e.rotation)}${e.radius > 0 ? _geom('roundRect', _round(e.radius, box)) : _geom('rect')}</p:spPr></p:pic>';
}

String _slide(PptxPage page, Map<String, ({String png, String? svg})> rels) {
  final shapes = StringBuffer();
  for (final (i, e) in page.slide.elements.indexed) {
    final id = i + 2;
    shapes.write(switch (e) {
      TextElement() => _text(id, e),
      ShapeElement() => _shape(id, e),
      TableElement() => _table(id, e),
      PictureElement() => _picture(id, e, page.pictures[e.ref], rels[e.ref]),
    });
  }
  return '$_decl<p:sld $_ns><p:cSld>'
      '<p:bg><p:bgPr>${_fillOf(page.slide.background)}<a:effectLst/></p:bgPr></p:bg>'
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
      '$shapes</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';
}

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

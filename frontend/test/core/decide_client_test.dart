import 'dart:convert';

import 'package:every_ai/core/api/decide_client.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _questions = [
  DecideQuestion.yesNo('read_only', 'Does it only read?'),
  DecideQuestion.choice('lang', 'Which language?', ['en', 'fr']),
  DecideQuestion.score('urgency', 'How urgent?'),
];

DecideClient _client(Future<http.Response> Function(http.Request) handler, {Duration? timeout}) => DecideClient(
  ApiClient(baseUrl: Uri.parse('http://test/'), client: MockClient(handler)),
  timeout: timeout ?? const Duration(seconds: 8),
);

void main() {
  test('"unsure", wrong types, unoffered choices and missing answers are unsure', () async {
    final client = _client(
      (_) async => http.Response(
        jsonEncode({
          'answers': [
            {'id': 'read_only', 'value': 'unsure'},
            {'id': 'lang', 'value': 'de'},
            {'id': 'urgency', 'value': 3},
          ],
        }),
        200,
      ),
    );
    final r = await client.decide(text: 'x', questions: [..._questions, const DecideQuestion.yesNo('gone', '?')]);
    expect(r.failed, isFalse);
    expect(r.allUnsure, isTrue);
    expect(r['never_asked'].unsure, isTrue);
  });
}

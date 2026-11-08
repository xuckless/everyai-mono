// The owner's live check of one BYOK provider before flipping it to
// `"status": "connected"` in backend-exp/src/providers.json (and re-running
// the generator in the commit that does). Spends a few cents on the key.
//
// Start a backend that takes keys and routes to providers still marked
// "saved" (without ROUTE_SAVED_PROVIDERS their keys are never used), e.g. in backend-exp:
//   ACCEPT_PROVIDER_KEYS=true ROUTE_SAVED_PROVIDERS=true DEV_AUTH=true zig build run   (development only)
// then:
//   BYOK_KEY=sk-... dart run tool/byok_live_check.dart openai openai/gpt-6.1-sol [http://127.0.0.1:8080]
//
// It checks, through the server's gateway, a streamed reply, a tool call,
// and a usage row priced from the catalog (GET /v1/usage/session/:id).
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: BYOK_KEY=… dart run tool/byok_live_check.dart <provider id> <model id> [server]');
    exit(64);
  }
  final key = Platform.environment['BYOK_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('Set BYOK_KEY to the provider key.');
    exit(64);
  }
  final table = jsonDecode(File('../backend-exp/src/providers.json').readAsStringSync()) as Map<String, Object?>;
  final providers = (table['providers']! as List).cast<Map<String, Object?>>();
  final p = providers.firstWhere((p) => p['id'] == args[0], orElse: () => throw 'No provider ${args[0]}');
  final server = Uri.parse(args.length > 2 ? args[2] : 'http://127.0.0.1:8080/');
  final session = 'byok-check-${DateTime.now().millisecondsSinceEpoch}';
  final headers = {'Content-Type': 'application/json', p['header']! as String: key, 'X-EveryAI-Session': session};
  final http = HttpClient();
  var failed = 0;

  Future<String> post(Map<String, Object?> body) async {
    final req = await http.postUrl(server.resolve('v1/chat/completions'));
    headers.forEach(req.headers.set);
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw 'HTTP ${res.statusCode}: $text';
    return text;
  }

  void report(String what, bool ok, [String detail = '']) {
    if (!ok) failed++;
    stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $what${detail.isEmpty ? '' : ': $detail'}');
  }

  try {
    final streamed = await post({
      'model': args[1],
      'stream': true,
      'messages': [
        {'role': 'user', 'content': 'Say hello in three words.'},
      ],
    });
    final deltas = streamed.split('\n').where((l) => l.startsWith('data: ') && l.contains('"content"')).length;
    report('streamed reply', deltas > 0, '$deltas chunks');
  } on Object catch (e) {
    report('streamed reply', false, '$e');
  }
  try {
    final tool = await post({
      'model': args[1],
      'messages': [
        {'role': 'user', 'content': 'What is the weather in Paris? Use the tool.'},
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'get_weather',
            'description': 'Weather for a city',
            'parameters': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
              'required': ['city'],
            },
          },
        },
      ],
    });
    report('tool call', tool.contains('get_weather'));
  } on Object catch (e) {
    report('tool call', false, '$e');
  }
  try {
    final req = await http.getUrl(server.resolve('v1/usage/session/$session'));
    final res = await req.close();
    final u = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, Object?>;
    report('usage recorded', (u['calls'] as num? ?? 0) >= 2, '${u['calls']} calls');
    report('priced from the catalog', (u['byok_cost_micros'] as num? ?? 0) > 0, '${u['byok_cost_micros']} µ\$');
  } on Object catch (e) {
    report('usage', false, '$e');
  }
  http.close();
  stdout.writeln(failed == 0 ? '\n${p['name']} passes: flip its status to "connected".' : '\n$failed check(s) failed.');
  exit(failed == 0 ? 0 : 1);
}

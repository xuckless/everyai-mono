import 'dart:convert';

import 'package:every_ai/core/security/link_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? concern(String url) => linkConcern(Uri.parse(url));

  test('flags data and secrets in the address', () {
    final blob = base64Url.encode(utf8.encode('the user said: my bank PIN is 4242 and the chat goes on'));
    expect(concern('https://img.example/p.png?d=$blob'), contains('long block of data'));
    expect(concern('https://x.example/sk-proj-abcdefghijklmnopqrstuvwxyz012345/c'), contains('an API key'));
    expect(concern('https://x.example/c?t=ghp_abcdefghijklmnopqrstuvwxyz0123'), contains('a GitHub token'));
    // Percent-encoding doesn't hide it.
    expect(concern('https://x.example/c?t=%73k-proj-abcdefghijklmnopqrstuvwxyz012345'), contains('an API key'));
    expect(concern('https://x.example/#${'Q' * 30}${'7' * 30}'), contains('long block of data'));
    expect(concern('mailto:x@example.com?body=${'word%20' * 60}'), contains('long block of data'));
  });

  test('flags data cut into short pieces, put in the host, or punctuated', () {
    final segments = List.filled(30, 'aGVsbG8gd29yb0GQgdGhpcyBpcyBhIHNl.Y3Jl').join('/');
    expect(concern('https://evil.example/$segments'), contains('long block of data'));
    expect(concern('https://dGhlIHVzZXIgcGFzc3dvcmQgaXMgaHVudGVyMg.evil.example/'), contains('long block of data'));
    expect(
      concern('https://evil.example/?q=Ali%27s+home:+12+Main+St,+Springfield,+card+4111+1111+1111+1111+exp+12/29'),
      contains('long block of data'),
    );
  });

  test('flags addresses that hide where they go', () {
    expect(
      concern('https://docs.python.org@evil.example/'),
      allOf(contains('docs.python.org@'), contains('evil.example')),
    );
    expect(concern('https://xn--pple-43d.com/'), contains('another alphabet'));
    expect(concern('http://203.0.113.5/a'), contains('network number'));
    expect(concern('http://[2001:db8::1]/a'), contains('network number'));
    // Shorthand forms a browser still reads as an address.
    expect(concern('http://0x7f.1/a'), contains('network number'));
    expect(concern('http://3232235777/a'), contains('network number'));
    expect(concern('http://10.1/a'), contains('network number'));
    // A Unicode lookalike (Cyrillic а) that Dart keeps percent-encoded.
    expect(concern('https://\u0430pple.com/login'), contains('another alphabet'));
  });
}

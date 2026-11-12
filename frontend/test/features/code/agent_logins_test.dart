import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart' show appFill;
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:every_ai/features/code/live/app_view.dart' show AppError, dartString;
import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:every_ai/features/code/live/live_session.dart' show LiveControl;
import 'package:every_ai/features/code/live/login_import.dart';
import 'package:every_ai/features/code/live/totp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TOTP (RFC 6238 vectors)', () {
    final at = {
      59: ['94287082', '46119246', '90693936'],
      1111111109: ['07081804', '68084774', '25091201'],
      1234567890: ['89005924', '91819424', '93441116'],
      20000000000: ['65353130', '77737706', '47863826'],
    };
    final keys = [
      (TotpHash.sha1, '12345678901234567890'),
      (TotpHash.sha256, '12345678901234567890123456789012'),
      (TotpHash.sha512, '1234567890123456789012345678901234567890123456789012345678901234'),
    ];
    for (final MapEntry(key: t, value: codes) in at.entries) {
      test('T=$t', () {
        for (final (i, (hash, key)) in keys.indexed) {
          final spec = (key: utf8.encode(key), hash: hash, digits: 8, period: 30);
          expect(totpCode(spec, at: DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true)), codes[i]);
        }
      });
    }
  });

  group('CSV import', () {
    test('Safari, with a code and a note across lines', () {
      final r = parseLoginCsv(
        'Title,URL,Username,Password,Notes,OTPAuth\n'
        'Acme,https://acme.test/,ada@acme.test,s3cret,"line 1\nline 2",otpauth://totp/Acme?secret=GEZDGNBVGY3TQOJQ\n',
      );
      expect(r.format, LoginCsvFormat.safari);
      expect(r.logins.single.totp, startsWith('otpauth://'));
      expect(r.logins.single.username, 'ada@acme.test');
    });
  });

  group('the store', () {
    late Directory tmp;
    late SealedStore sealed;
    late AgentLogins store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('logins');
      sealed = SealedStore('${tmp.path}/sealed', () async => SecretKey(List.filled(32, 7)));
      store = AgentLogins(sealed);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('sealed round trip; the index holds no secrets', () async {
      final e = await store.save(
        name: 'GitHub (work)',
        url: 'https://gist.github.com/login',
        username: 'ada',
        password: 'hunter2-long',
        totp: 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
        scope: LoginScope.global,
      );
      expect((e.name, e.site, e.hasCode), ('github-work', 'github.com', true));
      final again = AgentLogins(sealed);
      await again.load();
      expect(again.entries.value.single.name, 'github-work');
      expect((await again.secretsOf(e.id))!.password, 'hunter2-long');
      // On disk nothing is readable, and the index's plain JSON has no password.
      for (final f in Directory('${tmp.path}/sealed').listSync().whereType<File>()) {
        expect(utf8.decode(f.readAsBytesSync(), allowMalformed: true), isNot(contains('hunter2')));
      }
      expect(jsonEncode(await sealed.read('agent-logins')), isNot(contains('hunter2')));
      // An edit with no password keeps it; '' removes the code.
      await again.save(id: e.id, name: 'github-work', url: e.url, username: 'ada2', totp: '', scope: LoginScope.global);
      expect((await again.secretsOf(e.id))!.password, 'hunter2-long');
      expect(again.entries.value.single.hasCode, isFalse);
    });

    test('names are unique; scopes decide who sees a login', () async {
      await store.save(name: 'app', url: 'localhost:3000', username: 'a', password: 'p1', scope: LoginScope.global);
      await expectLater(
        store.save(name: 'APP', url: 'x.com', username: 'b', password: 'p2', scope: LoginScope.global),
        throwsA(isA<LoginSaveError>()),
      );
      expect(store.freeName('App'), 'app-2');
      await store.save(
        name: 'mine',
        url: 'https://mine.dev',
        username: 'c',
        password: 'p3',
        scope: LoginScope.project,
        projectId: 'p1',
      );
      expect(store.usable('p1').map((l) => l.name), ['mine', 'app']);
      expect(store.usable('p2').map((l) => l.name), ['app']);
      await store.setAgentsCanUse(store.named('app', 'p2')!.id, false);
      expect(store.usable('p2'), isEmpty);
      await store.forgetProject('p1');
      expect(store.entries.value.map((l) => l.name), ['app']);
      await expectLater(
        store.save(name: 'bad', url: 'x.com', username: '', password: 'p', totp: 'nope!', scope: LoginScope.global),
        throwsA(isA<LoginSaveError>()),
      );
    });

    test('import keeps codes only when the switch allows; deleting revokes approvals', () async {
      final rows = parseLoginCsv(
        'Title,URL,Username,Password,Notes,OTPAuth\n'
        'Acme,https://acme.test/,ada,s3cret-1,,otpauth://totp/A?secret=GEZDGNBVGY3TQOJQ\n'
        'Acme,https://acme.test/,ada,s3cret-1,,\n',
      ).logins;
      final r = await store.importAll(rows, scope: LoginScope.global, codes: false);
      expect((r.added, r.skipped), (1, 1));
      expect(store.entries.value.single.hasCode, isFalse);
      final gate = LoginGate.of('s-del');
      final waiting = gate.ensure('acme', site: 'acme.test');
      gate.answer('acme', allow: true);
      expect(await waiting, ConsentOutcome.allowed);
      await store.delete(store.entries.value.single.id);
      expect(gate.stateOf('acme'), isA<ConsentUnasked>());
      expect(store.entries.value, isEmpty);
    });
  });

  group('policy', () {
    final e = LoginEntry(
      id: '1',
      name: 'github',
      site: 'github.com',
      url: 'https://github.com',
      username: 'ada',
      scope: LoginScope.global,
      saved: DateTime(2026),
    );

    test('own site only, codes, and the per-login switch', () {
      const strict = LoginPolicy(anySite: false, codes: false);
      expect(fillRefusal(e, LoginField.password, policy: strict, pageUrl: 'https://gist.github.com/x'), isNull);
      expect(fillRefusal(e, LoginField.password, policy: strict, pageUrl: 'https://github.com.evil.io/'), isNotNull);
      expect(fillRefusal(e, LoginField.password, policy: LoginPolicy.open, pageUrl: 'https://evil.io/'), isNull);
      expect(fillRefusal(e, LoginField.code, policy: strict), contains('user types the code'));
      expect(fillRefusal(e, LoginField.code, policy: LoginPolicy.open), contains('needs the user'));
      expect(fillRefusal(e.copyWith(agentsCanUse: false), LoginField.username, policy: LoginPolicy.open), isNotNull);
      expect(loginFitsHost('github.com', 'notgithub.com'), isFalse);
    });

    test('right before typing: the focused document counts too, and a frame that cannot be read is another site', () {
      const strict = LoginPolicy(anySite: false);
      const page = 'https://github.com/login';
      expect(fillSiteRefusal(e, policy: strict, pageUrl: page, focus: const FocusIn(page)), isNull);
      expect(
        fillSiteRefusal(e, policy: strict, pageUrl: page, focus: const FocusIn('https://evil.io')),
        contains('the focused field is on evil.io'),
      );
      expect(
        fillSiteRefusal(e, policy: strict, pageUrl: page, focus: const FocusInForeignFrame()),
        contains('frame of another site'),
      );
      expect(fillSiteRefusal(e, policy: strict, pageUrl: 'https://evil.io/', focus: null), contains('this page'));
      // The switch on: no site check at all.
      expect(fillSiteRefusal(e, policy: LoginPolicy.open, pageUrl: 'https://evil.io/', focus: null), isNull);
      // App screens: the one decision point, open for now.
      expect(appScreenFillVerdict(e, strict), isNull);
    });

    test('asking first: unasked → asking → allowed, revoke, deny, stop', () async {
      final gate = LoginGate.of('s-ask');
      final first = gate.ensure('github', site: 'github.com');
      final second = gate.ensure('github', site: 'github.com');
      expect(gate.stateOf('github'), isA<ConsentAsking>());
      expect(LoginGate.asks.value.where((a) => a.gate == gate).map((a) => a.login), ['github']);
      gate.answer('github', allow: true);
      expect([await first, await second], [ConsentOutcome.allowed, ConsentOutcome.allowed]);
      expect(gate.allowed, ['github']);
      gate.revoke('github');
      expect(gate.stateOf('github'), isA<ConsentUnasked>());
      final third = gate.ensure('github', site: 'github.com');
      gate.answer('github', allow: false);
      expect(await third, ConsentOutcome.denied);
      LoginGate.revokeAll();
      final fourth = gate.ensure('github', site: 'github.com');
      gate.stop();
      expect(await fourth, ConsentOutcome.stopped);
      expect(gate.stateOf('github'), isA<ConsentUnasked>());
      expect(LoginGate.asks.value.where((a) => a.gate == gate), isEmpty);
    });
  });

  test('an app fill says what it filled, never the value, even when the driver quotes it', () async {
    final tmp = Directory.systemTemp.createTempSync('logins');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = AgentLogins(SealedStore('${tmp.path}/s', () async => SecretKey(List.filled(32, 1))));
    await store.save(name: 'app', url: 'localhost', username: 'ada', password: 'pw-secret-9', scope: LoginScope.global);
    final access = LoginAccess(logins: () async => store, gate: LoginGate.of('s-app'));
    String? typed;
    final ok = await appFill({'login': 'app', 'ref': 's3', 'field': 'password'}, access, (ref, v, submit) async {
      typed = v;
    });
    expect(typed, 'pw-secret-9');
    expect(ok.did, "Filled the password of 'app' into s3.");
    final bad = await appFill({'login': 'app', 'ref': 's3'}, access, (ref, v, submit) async {
      throw AppError('the field shows "$v"');
    });
    expect(bad.error, isNot(contains('pw-secret-9')));
    // Asking first: a Stop while the card is up ends the fill at once, typing nothing.
    final asking = LoginAccess(
      policy: const LoginPolicy(withoutAsking: false),
      logins: () async => store,
      gate: LoginGate.of('s-stop'),
    );
    typed = null;
    final pending = appFill({'login': 'app', 'ref': 's3'}, asking, (ref, v, submit) async => typed = v);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(LoginGate.of('s-stop').stateOf('app'), isA<ConsentAsking>());
    LoginGate.find('s-stop')!.stop();
    expect((await pending).error, contains('the session stopped'));
    expect(typed, isNull);
    expect(LoginGate.of('s-stop').stateOf('app'), isA<ConsentUnasked>());
    final unknown = await appFill({'login': 'nope', 'ref': 's3'}, access, (r, v, s) async {});
    expect(unknown.error, contains('Saved logins: app (localhost)'));
    expect(access.redact('echo pw-secret-9'), isNot(contains('pw-secret-9')));
  });

  test('a value is hidden in its escaped forms too, and a code only while it is valid', () {
    final gate = LoginGate.of('s-forms');
    const pw = r"it's$a\back";
    gate.remember(pw);
    // As the Flutter driver writes it into an expression (a compile error echoes it), and as JSON quotes it.
    final dart = dartString(pw), json = jsonEncode({'text': pw});
    expect(dart, isNot(contains(pw)));
    expect(gate.redact('Error: final t = $dart;'), 'Error: final t = \'[EVERYAI-HIDDEN: saved login]\';');
    expect(gate.redact(json), '{"text":"[EVERYAI-HIDDEN: saved login]"}');
    expect(secretForms(pw), hasLength(3));
    final now = DateTime(2026, 11, 11, 12);
    gate.rememberFor('482913', const Duration(seconds: 20), now: now);
    expect(gate.redact('code 482913', now: now.add(const Duration(seconds: 19))), isNot(contains('482913')));
    expect(gate.redact('code 482913', now: now.add(const Duration(seconds: 21))), 'code 482913');
  });

  test('an app fill whose screen the user took during the wait types nothing', () async {
    final tmp = Directory.systemTemp.createTempSync('logins');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = AgentLogins(SealedStore('${tmp.path}/s', () async => SecretKey(List.filled(32, 2))));
    await store.save(name: 'app', url: 'localhost', username: 'ada', password: 'pw-take-1', scope: LoginScope.global);
    final gate = LoginGate.of('s-app-take');
    final access = LoginAccess(policy: const LoginPolicy(withoutAsking: false), logins: () async => store, gate: gate);
    final control = LiveControl(hold: const Duration(milliseconds: 50));
    String? typed;
    final pending = appFill({'login': 'app', 'ref': 's3'}, access, (ref, v, s) async => typed = v, control: control);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    control.take();
    gate.answer('app', allow: true);
    expect((await pending).error, contains('driving this view'));
    expect(typed, isNull);
  });
}

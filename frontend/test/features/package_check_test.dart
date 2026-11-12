import 'package:every_ai/features/code/harness/everyai/package_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// What [command] installs, as `ecosystem:name` keys.
  List<String> keys(
    String command, {
    Map<String, String> files = const {},
    Map<String, String> env = const {},
    Map<String, List<String>> dirs = const {},
  }) => installsIn(
    command,
    cwd: '/p',
    env: env,
    readFile: (path) => files[path],
    listDir: (d) => dirs[d] ?? const [],
  ).packages.map((p) => p.key).toList();

  group('installsIn', () {
    test('JavaScript managers, scoped, versioned and aliased names', () {
      expect(keys('npm install lodash'), ['npm:lodash']);
      expect(keys('npm i -D @types/node@^20 typescript@5.4'), ['npm:@types/node', 'npm:typescript']);
      expect(keys('pnpm add -g esbuild'), ['npm:esbuild']);
      expect(keys('yarn add left-pad@npm:right-pad@1'), ['npm:right-pad']);
      expect(keys('bun add Zod'), ['npm:zod']);
      expect(keys('npm install --registry https://npm.example.com foo'), ['npm:foo']);
      expect(keys('npx create-vite@latest my-app --template react'), ['npm:create-vite']);
      expect(keys('pnpm dlx degit user/repo app'), ['npm:degit']);
      expect(keys('npx -p cowsay -y cowsay hi'), ['npm:cowsay']);
    });

    test('Python: pip in its forms, uv, uvx, pipx and poetry', () {
      expect(keys("python3 -m pip install 'requests[socks]>=2'"), ['pypi:requests']);
      expect(keys('.venv/bin/python -m pip install Flask_Login==0.6'), ['pypi:flask-login']);
      expect(keys('pip3 install -U numpy pandas'), ['pypi:numpy', 'pypi:pandas']);
      expect(keys('uv pip install httpx'), ['pypi:httpx']);
      expect(keys('uv add --dev pytest'), ['pypi:pytest']);
      expect(keys('uvx ruff check .'), ['pypi:ruff']);
      expect(keys('uvx --from httpie http GET x'), ['pypi:httpie']);
      expect(keys('pipx install black'), ['pypi:black']);
      expect(keys('poetry add -G dev mypy'), ['pypi:mypy']);
      expect(keys('pip install -i https://example.com/simple x'), ['pypi:x']);
    });

    test('shapes the shell parser gives up on are still scanned', () {
      for (final c in [
        'npm install reactt > install.log 2>&1',
        '(cd web && npm install reactt)',
        r'cd $(git rev-parse --show-toplevel) && npm install reactt',
        'bash -c "npm install reactt"',
        "sh -lc 'cd web && npm i reactt'",
        'npm install reactt && echo ok &',
        'echo `date` && npm i reactt',
        'bash <<EOF\nnpm i reactt\nEOF',
      ]) {
        expect(keys(c), ['npm:reactt'], reason: c);
      }
      expect(keys(r'npm i $PKG > log'), isEmpty);
      expect(keys("cat > notes.md <<'EOF'\nRun pip install reqests\nEOF\nls > out"), isEmpty);
      expect(installsIn('(cd web && npm install reactt) > log', cwd: '/p').dirs, ['/p/web']);
      expect(installsIn(r'cd $(pwd)/x && npm i reactt > log', cwd: '/p').dirs, ['/p']);
      expect(installsIn('bash -c "cd web && npm i a" && npm i b', cwd: '/p').dirs, ['/p/web', '/p']);
    });
  });

  group('typoTargetOf', () {
    String? typo(Ecosystem e, String n) => typoTargetOf(PackageRef(e, n));

    test('look-alikes of popular names', () {
      expect(typo(Ecosystem.pypi, 'reqests'), 'requests');
      expect(typo(Ecosystem.npm, 'lodahs'), 'lodash');
      expect(typo(Ecosystem.npm, 'expresss'), 'express');
      expect(typo(Ecosystem.npm, 'react2'), 'react');
      expect(typo(Ecosystem.npm, 'colour-name'), 'color-name');
      expect(typo(Ecosystem.npm, 'types-node'), '@types/node');
      expect(typo(Ecosystem.npm, 'dom-react'), 'react-dom');
      expect(typo(Ecosystem.pypi, 'python-dateutils'), 'python-dateutil');
      expect(typo(Ecosystem.pypi, 'beautifulsoup-4'), 'beautifulsoup4');
    });
  });

  group('verdictOf', () {
    final now = DateTime.utc(2026, 11, 5);
    PackageVerdict v(PackageRef p, PackageInfo? info) => verdictOf(p, info, now: now);
    const npm = Ecosystem.npm;

    test('a missing name is refused, with the likely name when there is one', () {
      final a = v(const PackageRef(Ecosystem.pypi, 'reqests'), PackageInfo.missing);
      expect(a.kind, VerdictKind.refuse);
      expect(a.text, contains('Did you mean `requests`'));
      final b = v(const PackageRef(npm, 'fastjsonfix-utils'), PackageInfo.missing);
      expect(b.kind, VerdictKind.refuse);
      expect(b.text, contains('made-up name'));
    });

    test('a new or little-used look-alike is refused; a popular one passes', () {
      final young = v(const PackageRef(npm, 'lodahs'), PackageInfo(created: DateTime.utc(2026, 11, 1), downloads: 0));
      expect(young.kind, VerdictKind.refuse);
      expect(young.text, contains('typo of the popular `lodash`'));
      final popular = v(const PackageRef(npm, 'expresss'), const PackageInfo(downloads: 900000));
      expect(popular.kind, VerdictKind.pass);
    });
  });
}

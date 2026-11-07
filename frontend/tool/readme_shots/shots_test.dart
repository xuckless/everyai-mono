// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// README screenshots: the real screens with demo data (the scripted demo session, seeded chats, faked agent and
// Ollama checks; no model calls, no network), rendered offscreen at 2x with the app's own fonts inside a
// macOS-style window, saved as PNGs.
//
//   cd frontend && flutter test tool/readme_shots/shots_test.dart && tool/readme_shots/to_webp.sh
//
// Output folder: EVERYAI_SHOTS_OUT (default build/readme_shots).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:every_ai/app/router.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/artifact_providers.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/chat/ui/chat_screen.dart';
import 'package:every_ai/features/code/board/board_screen.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/drivers/detection/desktop_apps.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/ui/code_home.dart';
import 'package:every_ai/features/code/ui/console/console_state.dart';
import 'package:every_ai/features/code/ui/session_view.dart';
import 'package:every_ai/features/code/ui/transcript/approval_card.dart';
import 'package:every_ai/features/history/ui/sidebar.dart';
import 'package:every_ai/features/local_models/local_models_providers.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/onboarding/onboarding_harness_providers.dart';
import 'package:every_ai/features/onboarding/ui/onboarding_screen.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:every_ai/features/settings/settings_registry.dart';
import 'package:every_ai/features/settings/ui/settings_modal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../test/features/local_models/fakes.dart';
import '../../test/layout/layout_host.dart';
import '../../test/support/fake_leads.dart';

final _out = Directory(Platform.environment['EVERYAI_SHOTS_OUT'] ?? 'build/readme_shots');
const _shotKey = ValueKey('readme.shot');
const _symbols = 'ShotSymbols';
final _dark = EveryTheme.resolve(DesignLanguage.material, Brightness.dark);

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

final class _Store implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// What the agent check "found" on this computer.
const _found = <String, DriverStatus>{
  'claude-code': DriverStatus(installed: true, path: '/opt/homebrew/bin/claude', version: '2.1.318', signedIn: true),
  'codex': DriverStatus(installed: true, path: '/opt/homebrew/bin/codex', version: 'codex-cli 0.166.0', signedIn: true),
  'opencode': DriverStatus(installed: true, path: '/opt/homebrew/bin/opencode', version: 'v2.1.3', signedIn: true),
  'gemini': DriverStatus(installed: true, path: '/opt/homebrew/bin/gemini', version: '0.52.0', signedIn: true),
  'github-copilot-cli': DriverStatus(installed: true, path: '/opt/homebrew/bin/copilot', version: '1.4.0'),
  'cursor': DriverStatus(installed: true, path: '/usr/local/bin/cursor-agent', version: '2026.10.28'),
};

/// The agents "found" on this computer, as drivers whose check answers [_found] (no real CLI runs).
List<Override> _fakeAgents() => [
  driverRegistryProvider.overrideWithValue(
    DriverRegistry({
      everyaiHarnessName: FakeLeadDriver(everyaiHarnessName, label: 'EveryAI'),
      'claude-code': FakeLeadDriver(
        'claude-code',
        label: 'Claude Code',
        needsConsent: true,
        status: _found['claude-code']!,
      ),
      'codex': FakeLeadDriver('codex', label: 'Codex', status: _found['codex']!),
      'opencode': FakeLeadDriver('opencode', label: 'OpenCode', status: _found['opencode']!),
      'gemini': FakeLeadDriver('gemini', label: 'Gemini CLI', needsConsent: true, status: _found['gemini']!),
      'github-copilot-cli': FakeLeadDriver(
        'github-copilot-cli',
        label: 'GitHub Copilot CLI',
        status: _found['github-copilot-cli']!,
      ),
      'cursor': FakeLeadDriver('cursor', label: 'Cursor CLI', status: _found['cursor']!),
    }),
  ),
  driverStatusesProvider.overrideWith(
    () => DriverStatuses(scanApps: () async => const AppScan(), loadShell: () async {}, reloadShell: () async {}),
  ),
];

const _tags =
    '{"models":[{"name":"qwen3.5-coder:14b","size":9100000000},{"name":"gemma4:12b","size":8100000000},'
    '{"name":"qwen3.5:4b","size":3400000000}]}';

/// Every font the app bundles (FontManifest), so text renders as in the app instead of the test font.
Future<void> _loadFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
  // Symbols the app's fonts lack (✓) come from the system on a Mac; the test engine has no system fallback, so the
  // pages get this font as an explicit fallback.
  const unicode = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
  if (File(unicode).existsSync()) {
    final bytes = File(unicode).readAsBytesSync();
    await (FontLoader(_symbols)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

Future<T> _until<T>(T Function() read, bool Function(T) cond) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A macOS window around the whole app (so popovers and dialogs are in the picture): rounded, hairline, traffic
/// lights over the sidebar's title row.
class _Window extends StatelessWidget {
  const _Window({required this.child, this.lights = true});
  final Widget child;
  final bool lights;

  @override
  Widget build(BuildContext context) {
    Widget light(Color c) => Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: _shotKey,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
            ),
            child: ColoredBox(
              color: _dark.background,
              child: Stack(
                children: [
                  Positioned.fill(child: child),
                  if (lights)
                    Positioned(
                      left: 18,
                      top: 18,
                      child: Row(
                        children: [
                          light(const Color(0xFFFF5F57)),
                          light(const Color(0xFFFEBC2E)),
                          light(const Color(0xFF28C840)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's wide layout: the real sidebar beside [content], as `AppShell` builds it.
Widget _shell(String location, Widget content) => ShellScope(
  sidebarVisible: true,
  compact: false,
  toggleSidebar: () {},
  child: ShellSplitView(
    compact: false,
    collapsed: false,
    drawerOpen: false,
    onDismissDrawer: () {},
    sidebar: Sidebar(location: location, onNavigate: (_) {}, onToggle: () {}),
    content: content,
  ),
);

/// One app world: an in-memory DB, preferences, and every outside call faked.
final class _World {
  late final AppDatabase db;
  late final Preferences prefs;
  late final ProviderContainer c;

  Future<void> open({List<Override> extra = const [], void Function(Preferences)? seed}) async {
    db = AppDatabase(NativeDatabase.memory());
    prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([
      const CodeProject(id: 'p1', name: 'counter-app', path: '${demoScheme}counter-app').toJson(),
    ]);
    prefs[CodeSettings.key] = jsonEncode({
      'global': {
        'ownClis': ['claude-code', 'gemini'],
      },
    });
    prefs[harnessStatusesKey] = jsonEncode({
      'v': 1,
      'checkedAt': DateTime.now().toIso8601String(),
      'statuses': {
        for (final e in _found.entries) e.key: e.value.toJson(),
        everyaiHarnessName: {'installed': true},
      },
    });
    seed?.call(prefs);
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(_Store()),
        harnessProvider.overrideWithValue(FakeHarness(step: Duration.zero)),
        modelCatalogProvider.overrideWith(_Catalog.new),
        harnessEnvStatusesProvider.overrideWithValue([
          for (final e in _found.entries) (env: HostEnv.instance, driverId: e.key, status: e.value),
        ]),
        localHttpProvider.overrideWithValue(
          FakeLocalHttp({
            'GET 127.0.0.1:11434/api/version': json('{"version":"0.21.0"}'),
            'GET 127.0.0.1:11434/api/tags': json(_tags),
            for (final (tag, ctx, vision) in [
              ('qwen3.5-coder:14b', 262144, false),
              ('gemma4:12b', 131072, true),
              ('qwen3.5:4b', 262144, true),
            ])
              'POST 127.0.0.1:11434/api/show#$tag': json(
                jsonEncode({
                  'capabilities': ['completion', 'tools', if (vision) 'vision'],
                  'model_info': {'general.context_length': ctx},
                }),
              ),
          }),
        ),
        localSystemProvider.overrideWithValue(FakeLocalSystem(ollama: '/opt/homebrew/bin/ollama')),
        bundledCatalogueProvider.overrideWith((ref) async => File('assets/local_models.json').readAsStringSync()),
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: Uri.parse('http://backend/'),
            client: MockClient((_) async => http.Response('offline', 599)),
          ),
        ),
        ...extra,
      ],
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 10));
    await tester.runAsync(() async {
      c.dispose();
      await db.close();
    });
  }

  /// A demo Code session in [mode], driven until [stop] holds (questions answered with the first option; approvals
  /// allowed while [approve]).
  Future<String> demoSession(AgentMode mode, bool Function(CodeSessionState) stop, {bool approve = true}) async {
    final info = await c
        .read(codeSessionsProvider.notifier)
        .start(
          project: c.read(codeProjectsProvider).single,
          prompt: 'Add a decrement method to Counter that never goes below zero, with tests',
          model: 'anthropic/claude-opus-5.5',
          mode: mode,
        );
    c.listen(codeSessionProvider(info.id), (_, _) {});
    final controller = c.read(codeSessionProvider(info.id).notifier);
    await _until(() {
      final state = c.read(codeSessionProvider(info.id));
      if (stop(state)) return true;
      if (state.transcript.openQuestion case final q?) {
        unawaited(
          controller.answer(q, [
            for (final _ in q.questions) const QuestionAnswer(selected: {0}),
          ]),
        );
      }
      if (approve && state.transcript.pending.isNotEmpty) unawaited(controller.approve());
      return false;
    }, (done) => done);
    return info.id;
  }
}

final class _Shots {
  _Shots(this.tester);
  final WidgetTester tester;

  /// Pumps [home] in the app (dark) in a [size] window and lets async work (DB reads, SVG logos) land.
  Future<void> show(ProviderContainer c, Size size, Widget home, {bool lights = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: _Window(
          lights: lights,
          child: LayoutHost(
            language: DesignLanguage.material,
            child: m.Material(
              color: _dark.background,
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontFamilyFallback: [_symbols]),
                child: home,
              ),
            ),
          ),
        ),
      ),
    );
    await settle();
  }

  Future<void> settle() async {
    for (var round = 0; round < 4; round++) {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    }
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> tap(Finder f) async {
    await tester.tap(f, warnIfMissed: false);
    await settle();
  }

  /// Saves the window as `<name>.png` at 2x, or only [crop] (logical pixels) of it.
  Future<void> save(String name, {Rect? crop}) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
    const scale = 2.0;
    final bytes = await tester.runAsync(() async {
      var image = await boundary.toImage(pixelRatio: scale);
      if (crop != null) {
        final src = Rect.fromLTRB(crop.left * scale, crop.top * scale, crop.right * scale, crop.bottom * scale);
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawImageRect(image, src, Offset.zero & src.size, Paint());
        final cropped = await recorder.endRecording().toImage(src.width.round(), src.height.round());
        image.dispose();
        image = cropped;
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    _out.createSync(recursive: true);
    File('${_out.path}/$name.png').writeAsBytesSync(bytes!);
    debugPrint('shot: ${_out.path}/$name.png');
  }

  /// [f]'s rect grown by [pad], kept inside the window.
  Rect around(Finder f, {double pad = 16}) {
    final r = tester.getRect(f).inflate(pad);
    final size = tester.view.physicalSize;
    return Rect.fromLTRB(
      r.left.clamp(0, size.width),
      r.top.clamp(0, size.height),
      r.right.clamp(0, size.width),
      r.bottom.clamp(0, size.height),
    );
  }
}

// ---- Chat demo data ----

Message _msg(String conv, String id, Role role, List<MessagePart> parts, {String? model}) => Message(
  id: id,
  conversationId: conv,
  role: role,
  parts: parts,
  createdAt: DateTime(2026, 11, 7, 10),
  model: model == null ? null : ModelId(model),
);

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id, resultJson: '"ok"');

Future<void> _chat(ProviderContainer c, String id, String title, String model, List<Message> messages) async {
  final repo = c.read(chatRepositoryProvider);
  await repo.createConversationWithId(id: id, title: title, model: ModelId(model));
  for (final m in messages) {
    await repo.saveMessage(m);
  }
}

const _studyGuide = r'''# Photosynthesis: One-Page Study Guide

## 1. The big picture
Photosynthesis turns light energy into chemical energy stored in glucose.

$$6\,CO_2 + 6\,H_2O + \text{light} \rightarrow C_6H_{12}O_6 + 6\,O_2$$

- **Where:** chloroplasts (thylakoid membranes for the light reactions, stroma for the Calvin cycle)
- **Pigments:** chlorophyll a and b, plus carotenoids that catch extra wavelengths

## 2. Two stages at a glance

| | Light-dependent reactions | Calvin cycle |
|---|---|---|
| Where | Thylakoid membrane | Stroma |
| Needs light directly? | Yes | No |
| Inputs | H₂O, light, ADP, NADP⁺ | CO₂, ATP, NADPH |
| Outputs | O₂, ATP, NADPH | G3P, ADP, NADP⁺ |

## 3. Light-dependent reactions
1. **Photon capture:** photosystems II and I absorb light.
2. **Water splitting:** 2 H₂O → 4 H⁺ + 4 e⁻ + O₂.
3. **ATP synthase** uses the proton gradient to make ATP.
''';

Future<void> _seedChats(ProviderContainer c) async {
  await _chat(c, 'guide', 'Photosynthesis study guide', 'anthropic/claude-sonnet-5.5', [
    _msg('guide', 'g1', Role.user, [
      const TextPart('Write a one-page study guide on photosynthesis for my biology exam'),
    ]),
    _msg('guide', 'g2', Role.assistant, [
      const TextPart(
        "Here's a one-page guide you can print, with the equation, a table of the two stages and the steps.",
      ),
      _call('create_artifact', {
        'id': 'guide',
        'kind': 'markdown',
        'title': 'Photosynthesis: One-Page Study Guide',
        'content': _studyGuide,
      }, 'a1'),
    ], model: 'anthropic/claude-sonnet-5.5'),
  ]);
  await _chat(c, 'deck', 'Pitch deck for a bike-share app', 'openai/gpt-6.1-terra', [
    _msg('deck', 'd1', Role.user, [const TextPart('Make a 3-slide pitch deck for a neighbourhood bike-share app')]),
    _msg('deck', 'd2', Role.assistant, [
      const TextPart('Here is the deck. Download it as PowerPoint from the panel.'),
      _call('make_slides', {
        'title': 'Spokes',
        'subtitle': 'Bike sharing for every street',
        'theme': 'navy',
        'slides': [
          {
            'title': 'The problem',
            'bullets': [
              'Half of all car trips are under 5 km',
              'Docked bikes miss most side streets',
              "Parking is the city's scarcest space",
            ],
          },
          {
            'title': 'How Spokes works',
            'bullets': ['Unlock with the app or a tap card', 'Park at any marked kerb', 'Pay per minute or monthly'],
          },
        ],
      }, 's1'),
    ], model: 'openai/gpt-6.1-terra'),
  ]);
  await _chat(c, 'chart', 'Electric car sales by region', 'anthropic/claude-sonnet-5.5', [
    _msg('chart', 'c1', Role.user, [const TextPart('Chart electric car sales by region since 2021')]),
    _msg('chart', 'c2', Role.assistant, [
      const TextPart('China leads by a wide margin; Europe and the United States grow more slowly.'),
      _call('render_chart', {
        'type': 'bar',
        'title': 'Electric car sales by region',
        'unit': 'million',
        'categories': ['2021', '2022', '2023', '2024', '2025'],
        'series': [
          {
            'name': 'China',
            'values': [3.3, 5.9, 8.1, 11.3, 13.0],
          },
          {
            'name': 'Europe',
            'values': [2.3, 2.7, 3.2, 3.2, 3.7],
          },
          {
            'name': 'United States',
            'values': [0.6, 1.0, 1.4, 1.6, 1.7],
          },
        ],
        'caption': 'Battery-electric and plug-in hybrid cars, new sales per year.',
        'source': 'Illustrative figures',
      }, 'ch1'),
    ], model: 'anthropic/claude-sonnet-5.5'),
  ]);
  Source src(String url, String title, String snippet) => Source(url: Uri.parse(url), title: title, snippet: snippet);
  await _chat(c, 'search', 'Latest stable Flutter release', 'anthropic/claude-sonnet-5.5', [
    _msg('search', 'q1', Role.user, [const TextPart('What changed in the latest stable Flutter release?')]),
    _msg('search', 'q2', Role.assistant, [
      SourcesPart([
        src('https://docs.flutter.dev/release/release-notes', 'Flutter release notes', 'What is new in each release.'),
        src('https://medium.com/flutter', "What's new in Flutter", 'The release announcement on the Flutter blog.'),
        src('https://github.com/flutter/flutter/blob/master/CHANGELOG.md', 'flutter/CHANGELOG.md', 'Changes by PR.'),
        src('https://dart.dev/guides/whats-new', "What's new in Dart", 'The Dart release that ships with it.'),
      ]),
      const TextPart(
        'The latest stable release focuses on rendering and desktop [1][2]:\n\n'
        '- **Impeller everywhere:** the new renderer is the default on every platform, with smoother first '
        'frames [1].\n'
        '- **Desktop windows:** multiple windows and native menus on macOS, Windows and Linux [2].\n'
        '- **WebAssembly:** `--wasm` builds are the default for the web, with faster startup [3].\n'
        '- **Dart:** dot shorthands and faster analysis come with the paired Dart release [4].\n\n'
        'Upgrade with `flutter upgrade`; the breaking changes are listed in the release notes [1].',
      ),
      const FollowUpsPart([
        'How do I migrate to the new window API?',
        'Is Impeller faster on older Android phones?',
        'Which packages break on this release?',
      ]),
    ], model: 'anthropic/claude-sonnet-5.5'),
  ]);
}

void main() {
  setUpAll(_loadFonts);
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);

  Future<void> run(WidgetTester tester, Future<void> Function(_World w, _Shots s) body) async {
    final w = _World();
    final s = _Shots(tester);
    try {
      await body(w, s);
    } finally {
      await w.close(tester);
      tester.view.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('console: a finished demo session with Session info open', (tester) async {
    await run(tester, (w, s) async {
      late String id;
      await tester.runAsync(() async {
        await w.open();
        id = await w.demoSession(AgentMode.fullAuto, (st) => st.status == SessionStatus.done);
      });
      w.c.read(consolePanelProvider(id).notifier).show(ConsoleView.info);
      await s.show(w.c, const Size(1440, 900), _shell(Routes.codeSession(id), CodeSessionScreen(sessionId: id)));
      await s.save('console');
    });
  });

  testWidgets('approval: the card for a command', (tester) async {
    await run(tester, (w, s) async {
      late String id;
      await tester.runAsync(() async {
        await w.open();
        id = await w.demoSession(AgentMode.ask, (st) => st.transcript.pending.isNotEmpty, approve: false);
      });
      w.c.read(consolePanelProvider(id).notifier).close();
      await s.show(w.c, const Size(1100, 900), _shell(Routes.codeSession(id), CodeSessionScreen(sessionId: id)));
      await s.save('approval', crop: s.around(find.byType(ApprovalCard).first, pad: 12));
    });
  });

  testWidgets('agents: the entry tour lists the agents found on this computer', (tester) async {
    await run(tester, (w, s) async {
      await tester.runAsync(() => w.open(extra: _fakeAgents()));
      await s.show(w.c, const Size(1100, 760), const OnboardingScreen(desktop: true));
      for (var i = 0; i < 3; i++) {
        await s.tap(find.byKey(const ValueKey('onboarding.next')));
      }
      await s.save('agents');
    });
  });

  testWidgets('picker + workflows: the new session page with its menus open', (tester) async {
    await run(tester, (w, s) async {
      // A real (empty) folder: demo projects hide the agent and workflow menus.
      final dir = Directory('${Directory.systemTemp.createTempSync('everyai-shots').path}/counter-app')..createSync();
      addTearDown(() => dir.parent.deleteSync(recursive: true));
      await tester.runAsync(
        () => w.open(
          extra: _fakeAgents(),
          seed: (p) =>
              p['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'counter-app', path: dir.path).toJson()]),
        ),
      );
      await s.show(w.c, const Size(1280, 820), _shell(Routes.code, const CodeHome()));
      await s.save('home');
      Rect menu(String first, String last) => s
          .around(find.byType(CodeComposer), pad: 24)
          .expandToInclude(s.around(find.text(first).last, pad: 28))
          .expandToInclude(s.around(find.text(last).last, pad: 28));
      await s.tap(find.byKey(const ValueKey('composer.strip.harness')));
      await s.save('picker', crop: menu('Harness', 'Check again'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await s.settle();
      await s.tap(find.byKey(const ValueKey('composer.strip.workflow')));
      await s.save('workflows', crop: menu('Workflow', 'Security review'));
    });
  });

  testWidgets('board: sessions from several agents in their columns', (tester) async {
    await run(tester, (w, s) async {
      CodeSessionInfo session(String id, String title, String harness, String model, int minutes) => CodeSessionInfo(
        id: id,
        projectId: 'p1',
        title: title,
        conversationId: 'c-$id',
        model: model,
        mode: AgentMode.autoEdit,
        workingDir: '${demoScheme}counter-app',
        createdAt: DateTime.now().subtract(Duration(minutes: minutes)),
        harness: harness,
      );
      await tester.runAsync(
        () => w.open(
          seed: (p) => p['code.sessions'] = jsonEncode([
            session('a', 'Fix the flaky login test', 'claude-code', 'opus', 4).toJson(),
            session('b', 'Add dark mode to settings', 'codex', 'gpt-6.1-sol', 9).toJson(),
            session('c', 'Upgrade to Riverpod 3', everyaiHarnessName, 'anthropic/claude-opus-5.5', 15).toJson(),
            session('d', 'Security review of the auth flow', 'opencode', 'kimi-k2.5', 22).toJson(),
            session('e', 'Write release notes for 1.4', 'gemini', 'gemini-3.5-pro', 40).toJson(),
            session('f', 'Profile the image cache', everyaiHarnessName, 'local/qwen3.5-coder:14b', 65).toJson(),
            session('g', 'Port the CLI to Windows', 'codex', 'gpt-6.1-terra', 90).toJson(),
          ]),
        ),
      );
      w.c.listen(codeStatusesProvider, (_, _) {});
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      w.c.read(codeStatusesProvider.notifier).state = {
        'a': SessionStatus.needsInput,
        'b': SessionStatus.running,
        'c': SessionStatus.running,
        'd': SessionStatus.needsInput,
        'e': SessionStatus.done,
        'f': SessionStatus.running,
        'g': SessionStatus.done,
      };
      await s.show(w.c, const Size(1440, 860), _shell(Routes.board, const BoardScreen()));
      await s.save('board');
    });
  });

  testWidgets('local models: Settings → Local models with Ollama running', (tester) async {
    await run(tester, (w, s) async {
      await tester.runAsync(w.open);
      w.c.read(settingsTargetProvider.notifier).go(SettingsSection.localModels);
      await s.show(
        w.c,
        const Size(1280, 820),
        Stack(
          children: [
            Positioned.fill(child: _shell(Routes.code, const CodeHome())),
            Positioned.fill(child: ColoredBox(color: _dark.scrim)),
            const SettingsModal(),
          ],
        ),
      );
      await s.save('keys');
    });
  });

  testWidgets('chat: artifact, slides, chart, search', (tester) async {
    await run(tester, (w, s) async {
      late List<Message> deckMessages;
      await tester.runAsync(() async {
        await w.open();
        await _seedChats(w.c);
        deckMessages = await w.c.read(chatRepositoryProvider).messages('deck');
      });
      Widget chat(String id) => _shell('/chat/$id', ChatScreen(conversationId: id));

      w.c.listen(artifactPanelProvider('guide'), (_, _) {});
      w.c.read(artifactPanelProvider('guide').notifier).openArtifact('guide');
      await s.show(w.c, const Size(1400, 900), chat('guide'));
      await s.save('artifact');

      w.c.listen(artifactPanelProvider('deck'), (_, _) {});
      final deck = Visual.fromPart(deckMessages.expand((m) => m.parts).whereType<ToolCallPart>().first)!;
      w.c.read(artifactPanelProvider('deck').notifier).openVisual(deck);
      await s.show(w.c, const Size(1400, 900), chat('deck'));
      await s.save('slides');

      await s.show(w.c, const Size(1400, 900), chat('chart'));
      await s.save('chart');

      await s.show(w.c, const Size(1400, 900), chat('search'));
      await s.save('search');
    });
  });
}

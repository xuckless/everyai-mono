import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/workflows/workflow_library.dart';
import 'package:every_ai/features/code/workflows/workflow_picker.dart';
import 'package:every_ai/features/code/workflows/workflow_runs.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/services.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fake_leads.dart';
import 'workflow_fakes.dart';

// The agent menu's Workflow page, and what a pick does: a script workflow
// takes the next message as its task, Max turns the approach skill on.

WorkflowEntry _entry(String id, String title, {WorkflowOrigin origin = WorkflowOrigin.bundled}) =>
    WorkflowEntry(id: id, title: title, source: 'return 1', digest: id, origin: origin, description: '$title does it');

Attachment _file(String name) =>
    Attachment.from(id: name, name: name, bytes: Uint8List.fromList(utf8.encode('log line'))).attachment!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each bundled workflow gets its own args from the task; a project one gets {task}', () {
    final review = _entry('security_review', 'Security review');
    expect(workflowArgsFor(_entry('bugfix', 'Bug fix'), 'It crashes'), {'bug': 'It crashes'});
    expect(workflowArgsFor(review, 'main', gitRef: true), {'base': 'main'});
    // A word that isn't a ref of the project is a focus, like any other text.
    expect(workflowArgsFor(review, 'auth'), {'focus': 'auth'});
    expect(workflowArgsFor(review, 'check the auth change'), {'focus': 'check the auth change'});
    expect(looksLikeRef('auth'), isTrue);
    expect(looksLikeRef('check the auth change'), isFalse);
    // Ultra's first agent splits the task into items.
    expect(workflowArgsFor(_entry('ultra', 'Ultra'), 'Dark mode\nand export'), {'task': 'Dark mode\nand export'});
    expect(workflowArgsFor(_entry('bugfix', 'Mine', origin: WorkflowOrigin.project), 'x'), {'task': 'x'});
  });

  group('a pick in a session', () {
    late AppDatabase db;
    late Directory tmp;
    late Directory project;
    late FakeLeadSession lead;
    late FakeLeadDriver driver;
    late ProviderContainer container;
    late Preferences prefs;
    late FakeBridge bridge;
    final started = <({String source, Map<String, Object?> args})>[];

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      tmp = await Directory.systemTemp.createTemp('workflow-picker');
      project = await Directory('${tmp.path}/project').create();
      lead = FakeLeadSession();
      driver = FakeLeadDriver('test', session: lead);
      bridge = FakeBridge();
      started.clear();
      prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(FixedCatalog.new),
          codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
          driverRegistryProvider.overrideWithValue(DriverRegistry({'test': driver})),
          hostServerProvider.overrideWithValue(FakeHost()),
          driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: Uri.parse('http://backend/'),
              client: MockClient((req) async => http.Response('no network in this test', 599)),
            ),
          ),
          codeSideModelProvider.overrideWithValue((messages) async => ''),
          workflowBridgeProvider.overrideWithValue(({required dir, required source, required args, sessionId}) async {
            started.add((source: source, args: args));
            return bridge;
          }),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<(CodeSessionController, CodeSessionInfo)> open({WorkflowPick? workflow, String prompt = 'Lead'}) async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: prompt,
            model: '',
            mode: AgentMode.autoEdit,
            harness: 'test',
            workflow: workflow,
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
      return (container.read(codeSessionProvider(info.id).notifier), info);
    }

    Future<WorkflowEntry> bundled(String id) async => (await loadBundledWorkflows()).firstWhere((w) => w.id == id);

    test('an armed Bug fix takes the next message as its task; the one after is a plain turn', () async {
      final (c, _) = await open();
      c.pickWorkflow(WorkflowPick.script(await bundled('bugfix')));
      expect(container.read(codeSessionProvider(c.sessionId)).armed?.id, 'bugfix');
      expect(c.workflowPick?.id, 'bugfix');
      expect(await c.sendTyped('Saving crashes', files: [_file('crash.log')]), isTrue);
      await pumpEventQueue();
      expect(lead.sent.last, contains('<everyai-workflow name="bugfix" state="picked"'));
      expect(lead.sent.last, contains('Saving crashes'));
      // The draft args carry the attached file's path with the task, for the workflow's agents.
      expect(lead.sent.last, contains('{"bug":"Saving crashes'));
      expect(lead.sent.last, contains('crash.log'));
      expect(started, isEmpty);
      expect(c.workflowPick, isNull);

      expect(await c.sendTyped('And the title too'), isTrue);
      await pumpEventQueue();
      expect(lead.sent.last, isNot(contains('<everyai-workflow')));
      expect(started, isEmpty);
    });

    test('Max is kept on the session and its note goes with the next message once', () async {
      final (c, info) = await open();
      c.pickWorkflow(const WorkflowPick.max());
      final saved = container.read(codeSessionsProvider.notifier).byId(info.id)!;
      expect(saved.workflow, maxWorkflowId);
      expect(CodeSessionInfo.fromJson(saved.toJson()).workflow, maxWorkflowId);
      expect(c.workflowPick!.isMax, isTrue);
      await c.send('Build a game');
      await c.send('Make it blue');
      final noted = lead.sent.where((m) => m.contains(maxWorkflowNote(on: true))).toList();
      expect(noted, hasLength(1));
      expect(noted.single, contains('Build a game'));
      expect(noted.single, contains(maxSkillId));
      // Off again: the opposite note, once.
      c.pickWorkflow(null);
      expect(container.read(codeSessionsProvider.notifier).byId(info.id)!.workflow, isNull);
      await c.send('Now plain');
      expect(lead.sent.last, contains(maxWorkflowNote(on: false)));
      expect(started, isEmpty);
    });

    test('a project workflow edited after it was picked does not run', () async {
      final file = File('${project.path}/.everyai/workflows/notes.js')
        ..createSync(recursive: true)
        ..writeAsStringSync("export const meta = { name: 'Notes' }\nreturn 1\n");
      final entry = (await loadProjectWorkflows(project.path)).single;
      container.read(workflowTrustProvider.notifier).set(entry, true);
      final (c, _) = await open();
      c.pickWorkflow(WorkflowPick.script(entry));
      file.writeAsStringSync("export const meta = { name: 'Notes' }\nreturn 2\n");
      final before = lead.sent.length;
      expect(await c.sendTyped('Write them'), isFalse);
      expect(started, isEmpty);
      expect(lead.sent.length, before);
      final t = container.read(codeSessionProvider(c.sessionId)).transcript;
      expect(t.items.whereType<NoticeItem>().last.message, contains('changed since you picked it'));
      // What the user typed is kept with the notice.
      expect(t.items.whereType<NoticeItem>().last.detail, 'Write them');
    });
  });
}

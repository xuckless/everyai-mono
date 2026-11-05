import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';

import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/uploads/uploads.dart';
import 'package:every_ai/features/attachments/ui/attachment_tray.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/questions/ui/question_card.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

final class _Session implements HarnessSession {
  final sent = <({String text, List<String> images})>[];
  final responses = <String?>[];
  var resumed = 0;
  final _events = StreamController<HarnessEvent>.broadcast();
  void emit(Map<String, Object?> event) => _events.add(HarnessEvent.decode(event));
  @override
  String get id => 'c1';
  @override
  Stream<HarnessEvent> get events => _events.stream;
  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    if (!accept) responses.add(reason);
  }

  @override
  Future<void> resume() async => resumed++;
  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async =>
      sent.add((text: text, images: images));
  @override
  dynamic noSuchMethod(Invocation i) => Future<void>.value();
}

final class _Driver implements HarnessDriver {
  _Driver(this.session);
  final _Session session;
  @override
  Set<DriverCap> get caps => const {};
  @override
  DriverInfo get info => DriverInfo(id: everyaiHarnessName, label: 'Test');
  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);
  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async => session;
  @override
  Future<HarnessSession> attach(String conversationId) async => session;
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> ids) async => const {};
}

final _args = {
  'questions': [
    {
      'question': 'Which look?',
      'header': 'Look',
      'options': [
        {'label': 'Flat', 'description': 'a'},
        {'label': 'Deep', 'description': 'b'},
      ],
    },
  ],
};
final _item = QuestionItem(
  HarnessEvent.decode({'kind': 'ActionEvent', 'id': 'q', 'tool_name': 'ask_user_question', 'action': _args})
      as ActionCall,
  Question.listFrom(_args),
);
const _answers = [QuestionAnswer(other: 'like this')];
final _png = Attachment(
  id: 'f1',
  name: 'mock.png',
  mime: 'image/png',
  kind: AttachmentKind.image,
  bytes: Uint8List.fromList([1, 2, 3]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('card', () {
    Widget host({Future<bool> Function(List<QuestionAnswer>, List<Attachment>)? onFiles, void Function()? onPlain}) =>
        m.MaterialApp(
          home: m.Material(
            child: EveryThemeScope(
              theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
              child: SingleChildScrollView(
                child: QuestionCard(
                  questions: _item.questions,
                  onSubmit: (_) => onPlain?.call(),
                  onSubmitWithFiles: onFiles,
                  pickFiles: ({allowed}) async => [
                    XFile.fromData(Uint8List.fromList('hello'.codeUnits), name: 'a.txt', path: '/x/a.txt'),
                  ],
                ),
              ),
            ),
          ),
        );

    testWidgets('no attach button without onSubmitWithFiles', (tester) async {
      await tester.pumpWidget(host());
      expect(find.byTooltip('Attach files'), findsNothing);
    });

    testWidgets('files show as a chip, can be removed, and go with the answer', (tester) async {
      List<Attachment>? got;
      final result = Completer<bool>();
      await tester.pumpWidget(
        host(
          onFiles: (a, f) {
            got = f;
            return result.future;
          },
        ),
      );
      await tester.tap(find.byTooltip('Attach files'));
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(find.byType(AttachmentChip), findsOneWidget);
      // A file alone does not make the card submittable.
      await tester.tap(find.text('Submit answer'));
      await tester.pump();
      expect(got, isNull);

      await tester.tap(find.descendant(of: find.byType(AttachmentChip), matching: find.byType(GestureDetector)).last);
      await tester.pump();
      expect(find.byType(AttachmentChip), findsNothing);

      await tester.tap(find.byTooltip('Attach files'));
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      await tester.tap(find.text('Flat'));
      await tester.pump();
      await tester.tap(find.text('Submit answer'));
      await tester.pump();
      expect(got!.map((f) => f.name), ['a.txt']);

      // A refused submit opens the card again.
      result.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Submit answer'), findsOneWidget);
    });
  });

  group('controller', () {
    late AppDatabase db;
    late Directory tmp;
    late _Session session;
    late ProviderContainer container;

    Future<CodeSessionController> open(String model) async {
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: tmp.path).toJson()]);
      prefs['code.sessions'] = jsonEncode([
        CodeSessionInfo(
          id: 's1',
          projectId: 'p1',
          title: 't',
          conversationId: 'c1',
          model: model,
          mode: AgentMode.fullAuto,
          workingDir: tmp.path,
          createdAt: DateTime(2026),
          harness: everyaiHarnessName,
        ).toJson(),
      ]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
          codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
          driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
          driverRegistryProvider.overrideWithValue(DriverRegistry({everyaiHarnessName: _Driver(session)})),
        ],
      );
      container.listen(codeSessionProvider('s1'), (_, _) {});
      final done = Completer<void>();
      final sub = container.listen(codeSessionProvider('s1').select((s) => s.connected), (_, c) {
        if (c && !done.isCompleted) done.complete();
      }, fireImmediately: true);
      await done.future;
      sub.close();
      return container.read(codeSessionProvider('s1').notifier);
    }

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      tmp = await Directory.systemTemp.createTemp('question-files');
      session = _Session();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    });

    final seeing = builtInCatalog.all.firstWhere((s) => s.accepts(AttachmentKind.image)).id.value;
    final blind = builtInCatalog.all.firstWhere((s) => !s.accepts(AttachmentKind.image)).id.value;

    test('a free answer with a picture ends in the Attached note and sends the picture to a model that sees', () async {
      final c = await open(seeing);
      expect(await c.answer(_item, _answers, files: [_png]), isTrue);
      final sent = session.sent.single;
      final (text, paths) = splitAttachedNote(splitModeNote(sent.text).$2);
      expect(paths.single, startsWith('$uploadsDir/'));
      expect(File('${tmp.path}/${paths.single}').readAsBytesSync(), [1, 2, 3]);
      expect(sent.images, [_png.dataUrl]);
      // The answers still parse the same with the note after the fence.
      expect(parseAnswers(text, _item.questions)!.single.other, 'like this');
    });

    test('a model that cannot see gets the path only', () async {
      final c = await open(blind);
      await c.answer(_item, _answers, files: [_png]);
      expect(session.sent.single.images, isEmpty);
      expect(splitAttachedNote(session.sent.single.text).$2, hasLength(1));
    });

    Map<String, Object?> status(String value) => {
      'kind': 'ConversationStateUpdateEvent',
      'key': 'execution_status',
      'value': value,
    };

    Future<void> hold() async {
      session.emit(status('waiting_for_confirmation'));
      session.emit({'kind': 'ActionEvent', 'id': 'q', 'tool_name': 'ask_user_question', 'action': _args});
      await pumpEventQueue();
    }

    test('a held question gets the note in the call result and no images', () async {
      final c = await open(seeing);
      await hold();
      expect(await c.answer(_item, _answers, files: [_png]), isTrue);
      expect(session.sent, isEmpty);
      final (_, paths) = splitAttachedNote(session.responses.single!);
      expect(paths.single, startsWith('$uploadsDir/'));
      expect(session.resumed, 1);
    });

    test('a call closed while the files were saved is not answered or resumed', () async {
      final c = await open(seeing);
      await hold();
      final done = c.answer(_item, _answers, files: [_png]);
      session.emit(status('idle'));
      expect(await done, isTrue);
      expect(session.responses, isEmpty);
      expect(session.resumed, 0);
    });

    test("the app's own cards take no files", () async {
      final c = await open(seeing);
      expect(c.acceptsFiles(_item), isTrue);
      final bug = QuestionItem(
        HarnessEvent.decode({
          'kind': 'ActionEvent',
          'id': 'bugask-1',
          'tool_name': 'ask_user_question',
          'action': _args,
        }) as ActionCall,
        _item.questions,
      );
      expect(c.acceptsFiles(bug), isFalse);
    });

    test('no files: the message is as before', () async {
      final c = await open(blind);
      await c.answer(_item, _answers);
      expect(session.sent.single.text, isNot(contains('[Attached:')));
    });

    test('files that cannot be saved keep the card open', () async {
      final c = await open(blind);
      File('${tmp.path}/.everyai').writeAsStringSync('in the way');
      expect(await c.answer(_item, _answers, files: [_png]), isFalse);
      expect(session.sent, isEmpty);
      expect(container.read(codeSessionProvider('s1')).error, contains("Couldn't save the attachments"));
    });
  });
}

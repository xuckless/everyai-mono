import 'package:every_ai/features/slash/slash_command.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ran = <String>[];
  SlashCommand cmd(
    String name,
    String description, {
    SlashGroup group = SlashGroup.builtIn,
    SlashScope scope = SlashScope.both,
    String? argsHint,
  }) => SlashCommand(
    name: name,
    description: description,
    group: group,
    scope: scope,
    argsHint: argsHint,
    run: (ctx, args) => ran.add('$name|$args'),
  );

  final commands = [
    cmd('review', 'Review the diff with a subagent', group: SlashGroup.custom),
    cmd('plan', 'Switch to Plan mode', scope: SlashScope.code, argsHint: '[what to plan]'),
    cmd('pdf-tools', 'Fill and merge PDFs', group: SlashGroup.skills),
    cmd('search', 'Search the web', scope: SlashScope.chat),
    cmd('stop', 'Stop the agent', scope: SlashScope.code),
    cmd('compact', 'Summarize to free context'),
  ];

  setUp(ran.clear);

  group('slashQuery', () {
    TextEditingValue at(String text, [int? caret]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    );

    test('opens only for a slash at the start, with the caret in the first word', () {
      expect(slashQuery(at('/')), '');
      expect(slashQuery(at('/pl')), 'pl');
      expect(slashQuery(at('/plan now')), isNull);
      expect(slashQuery(at('hi /plan')), isNull);
      expect(slashQuery(at(' /plan')), isNull);
      expect(slashQuery(at('/plan', 3)), isNull);
      expect(slashQuery(at('/pl x', 3)), 'pl');
    });
  });

  group('filterSlashCommands', () {
    test('keeps the scope, groups in order and ranks prefix over substring over description', () {
      final names = [for (final c in filterSlashCommands(commands, '', SlashScope.code)) c.name];
      expect(names, ['compact', 'plan', 'stop', 'review', 'pdf-tools']);
      expect(
        [for (final c in filterSlashCommands(commands, '', SlashScope.chat)) c.name],
        ['compact', 'search', 'review', 'pdf-tools'],
      );
      expect(
        [for (final c in filterSlashCommands(commands, 'p', SlashScope.code)) c.name],
        ['plan', 'compact', 'stop', 'pdf-tools'],
      );
      expect([for (final c in filterSlashCommands(commands, 'PDF', SlashScope.code)) c.name], ['pdf-tools']);
      expect([for (final c in filterSlashCommands(commands, 'subagent', SlashScope.code)) c.name], ['review']);
      expect(filterSlashCommands(commands, 'zzz', SlashScope.code), isEmpty);
    });
  });

  test('parseSlashLine finds known commands with their arguments', () {
    final line = parseSlashLine('/plan add a login page\nwith tests', commands, SlashScope.code)!;
    expect(line.command.name, 'plan');
    expect(line.args, 'add a login page\nwith tests');
    expect(parseSlashLine('/search x', commands, SlashScope.code), isNull);
    expect(parseSlashLine('/etc/hosts is odd', commands, SlashScope.code), isNull);
    expect(parseSlashLine('/stop', commands, SlashScope.code)!.args, '');
  });
}

import 'package:every_ai/features/slash/custom/custom_command.dart';
import 'package:every_ai/features/slash/slash_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses frontmatter and body', () {
    final c = CustomCommand.parse(
      'review',
      '---\ndescription: "Review: staged"\nargs: <focus>\nmode: Auto-Edit\nmodel: x/y\n---\n\nLook at \$ARGUMENTS.\n',
    );
    expect(c.description, 'Review: staged');
    expect(c.args, '<focus>');
    expect(c.model, 'x/y');
    expect(c.body, 'Look at \$ARGUMENTS.');
    expect(c.modeFor(SlashScope.code), 'autoEdit');
    expect(c.modeFor(SlashScope.chat), isNull);
  });

  test('no frontmatter: description from first line, args hint from placeholder', () {
    final c = CustomCommand.parse('x', '# Summarize\nDo it for \$ARGUMENTS');
    expect(c.description, 'Summarize');
    expect(c.args, '[arguments]');
    expect(CustomCommand.parse('y', 'plain').args, isNull);
  });

  test('substitution', () {
    final c = CustomCommand.parse('x', 'A \$ARGUMENTS | \$1 and \$2 and \$3');
    expect(c.expand('one two'), 'A one two | one and two and');
    final plain = CustomCommand.parse('p', 'Do the thing');
    expect(plain.expand(''), 'Do the thing');
    expect(plain.expand('now'), 'Do the thing\n\nnow');
  });

  test('round trips through toSource', () {
    const c = CustomCommand(name: 'a', body: 'B \$ARGUMENTS', description: 'D: e', args: '<q>', mode: 'plan');
    final back = CustomCommand.parse('a', c.toSource());
    expect((back.description, back.args, back.mode, back.body), ('D: e', '<q>', 'plan', 'B \$ARGUMENTS'));
  });

  test('names are validated and scope follows project', () {
    expect(CustomCommand.validName.hasMatch('fix-it_2'), isTrue);
    expect(CustomCommand.validName.hasMatch('Bad Name'), isFalse);
    expect(const CustomCommand(name: 'a', body: 'b').toSlash().scope, SlashScope.both);
    expect(const CustomCommand(name: 'a', body: 'b', project: 'p').toSlash().scope, SlashScope.code);
  });

  test('a project command never turns approvals off', () {
    String? mode(String m, {String? project}) => CustomCommand.parse(
      't',
      '---\nmode: $m\n---\nGo',
      project: project,
      projectDir: project,
    ).modeFor(SlashScope.code);
    expect(mode('full-auto'), 'fullAuto');
    expect(mode('auto-edit'), 'autoEdit');
    expect(mode('full-auto', project: '/repo'), isNull);
    expect(mode('auto-edit', project: '/repo'), isNull);
    expect(mode('plan', project: '/repo'), 'plan');
    expect(mode('ask', project: '/repo'), 'ask');
  });

  test('a project command only shows in its own project', () {
    final c = CustomCommand.parse('deploy', 'Ship it', project: 'b', projectDir: '/work/b').toSlash();
    expect(c.project, '/work/b');
    expect(filterSlashCommands([c], 'deploy', SlashScope.code, project: '/work/b'), [c]);
    expect(filterSlashCommands([c], 'deploy', SlashScope.code, project: '/work/a'), isEmpty);
    expect(filterSlashCommands([c], 'deploy', SlashScope.code), isEmpty);
    // In another project it no longer shadows a global command of the same name.
    final global = CustomCommand.parse('deploy', 'Global').toSlash();
    expect(filterSlashCommands([c, global], 'deploy', SlashScope.code, project: '/work/a'), [global]);
    expect(filterSlashCommands([c, global], 'deploy', SlashScope.code, project: '/work/b'), [c]);
  });
}

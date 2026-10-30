/// A `SKILL.md`: YAML-style front matter (`name`, `description`) and a Markdown
/// body of instructions, following the Agent Skills format.
final class SkillMd {
  const SkillMd({required this.name, required this.description, required this.body});

  final String name;
  final String description;
  final String body;

  static const maxName = 64;
  static const maxDescription = 1024;

  /// Lowercase letters, digits and single hyphens; not starting or ending with one.
  static final validName = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  /// Turns any title into a valid skill name, or '' when nothing is left.
  static String slug(String text) {
    final s = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length <= maxName) return s;
    return s.substring(0, maxName).replaceAll(RegExp(r'-+$'), '');
  }

  /// Reads [source]. Throws [FormatException] naming the first problem.
  static SkillMd parse(String source) {
    final text = source.replaceAll('\r\n', '\n').trim();
    final m = RegExp(r'^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)').firstMatch(text);
    if (m == null) throw const FormatException('The skill needs front matter between --- lines.');
    final meta = <String, String>{};
    for (final line in m.group(1)!.split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0 || line.startsWith(' ') || line.startsWith('#')) continue;
      meta[line.substring(0, i).trim().toLowerCase()] = _unquote(line.substring(i + 1).trim());
    }
    final name = meta['name'] ?? '';
    final description = meta['description'] ?? '';
    final body = text.substring(m.end).trim();
    if (name.isEmpty) throw const FormatException('The skill needs a name.');
    if (name.length > maxName) throw const FormatException('The skill name is longer than 64 characters.');
    if (!validName.hasMatch(name)) {
      throw const FormatException('The skill name may use lowercase letters, digits and single hyphens only.');
    }
    if (description.isEmpty) throw const FormatException('The skill needs a description.');
    if (description.length > maxDescription) {
      throw const FormatException('The skill description is longer than 1024 characters.');
    }
    if (body.isEmpty) throw const FormatException('The skill has no instructions.');
    return SkillMd(name: name, description: description, body: body);
  }

  /// Fixes what a model gets slightly wrong before validating: a name that is
  /// not a slug, a long description. Anything else still fails [parse].
  static SkillMd repairAndParse(String source) {
    final text = source.replaceAll('\r\n', '\n').trim();
    final m = RegExp(r'^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)').firstMatch(text);
    if (m == null) return parse(text);
    final lines = m.group(1)!.split('\n');
    final fixed = <String>[];
    for (final line in lines) {
      final lower = line.toLowerCase();
      if (lower.startsWith('name:')) {
        fixed.add('name: ${slug(_unquote(line.substring(5).trim()))}');
      } else if (lower.startsWith('description:')) {
        var d = _unquote(line.substring(12).trim());
        if (d.length > maxDescription) d = d.substring(0, maxDescription).trimRight();
        fixed.add('description: ${_quote(d)}');
      } else {
        fixed.add(line);
      }
    }
    return parse('---\n${fixed.join('\n')}\n---\n${text.substring(m.end)}');
  }

  /// The file text.
  String toSource() => '---\nname: $name\ndescription: ${_quote(description)}\n---\n$body\n';

  static String _unquote(String v) {
    if (v.length < 2) return v;
    if (v.startsWith('"') && v.endsWith('"')) {
      return v.substring(1, v.length - 1).replaceAllMapped(RegExp(r'\\(["\\])'), (m) => m.group(1)!);
    }
    if (v.startsWith("'") && v.endsWith("'")) return v.substring(1, v.length - 1);
    return v;
  }

  static String _quote(String v) {
    final plain = RegExp(r'^[^\s"#:\[\]{}>|&*!%@`-][^"#]*$');
    if (plain.hasMatch(v) && !v.contains(': ') && !v.endsWith(':')) return v;
    return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
}

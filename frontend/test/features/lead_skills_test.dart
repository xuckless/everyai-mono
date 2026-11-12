import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/drivers/lead_skills.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the off list round trips per project and lead, sorted, and empties out', () {
    final prefs = Preferences.inMemory();
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    final ctl = c.read(leadSkillsProvider.notifier);
    ctl.setOff('p1', 'claude-code', 'pdf', off: true);
    ctl.setOff('p1', 'claude-code', 'docx', off: true);
    ctl.setOff('p2', 'claude-code', 'pdf', off: true);
    expect(jsonDecode(prefs[leadSkillsOffKey]!), {
      'p1': {
        'claude-code': ['docx', 'pdf'],
      },
      'p2': {
        'claude-code': ['pdf'],
      },
    });
    expect(ctl.off('p1', 'claude-code'), {'docx', 'pdf'});
    expect(ctl.off('p1', 'codex'), isEmpty);
    expect(ctl.off(null, 'claude-code'), isEmpty);
    ctl.setOff('p2', 'claude-code', 'pdf', off: false);
    expect((jsonDecode(prefs[leadSkillsOffKey]!) as Map).keys, ['p1']);
  });
}

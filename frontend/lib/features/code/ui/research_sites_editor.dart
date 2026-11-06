import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/adaptive.dart';
import '../code_settings_providers.dart';
import '../harness/everyai/research_sites.dart' show defaultResearchSites;

/// Why [text] isn't a site the research list can hold, or null when it is ("docs.python.org", "*.example.com";
/// a pasted URL is cut down to its host).
String? researchSiteProblem(String text) {
  final host = siteOf(text);
  return RegExp(r'^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(host) ? null : 'A domain, like docs.python.org';
}

/// [text] as a host: lower case, no scheme or path.
String siteOf(String text) => text.trim().toLowerCase().replaceFirst(RegExp(r'^[a-z]+://'), '').split('/').first;

/// The sites Max and Ultra research may read, as a list (+ adds, − removes, Defaults restores).
class ResearchSitesEditor extends ConsumerWidget {
  const ResearchSitesEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sites = ref.watch(codeSettingsProvider.select((s) => s.researchSites));
    final notifier = ref.read(codeSettingsProvider.notifier);
    return KitListEditor(
      key: const ValueKey('research-sites'),
      items: sites,
      itemLabel: 'Site',
      kindLabel: 'Covers',
      kindOf: (s) => s.startsWith('*.') ? 'Site and subdomains' : 'This site',
      placeholder: 'docs.python.org or *.example.com',
      empty: 'Empty: the defaults apply',
      validate: researchSiteProblem,
      onChanged: (next) => notifier.setResearchSites([for (final s in next) siteOf(s)]),
      onReset: () => notifier.setResearchSites(defaultResearchSites),
    );
  }
}

/// The research sites in a dialog (the session settings popover's row).
Future<void> showResearchSites(BuildContext context) => showKitDialog<void>(
  context,
  builder: (context) => KitDialog(
    title: 'Research sites',
    width: 480,
    body: const ResearchSitesEditor(),
    actions: [KitButton(label: 'Done', onPressed: () => Navigator.of(context).pop())],
  ),
);

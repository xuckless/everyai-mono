import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/every_icons.dart';
import '../artifact_providers.dart';
import '../domain/artifact.dart';
import 'renderers/svg_view.dart';
import '../../../core/ui/segmented.dart';
import '../data/artifact_library.dart';
import 'visual_view.dart';

/// "Artifacts": documents, code, pages, diagrams and images from every chat.
/// Opening one goes to its chat with the artifact in the side panel.
class ArtifactsScreen extends ConsumerStatefulWidget {
  const ArtifactsScreen({super.key});

  @override
  ConsumerState<ArtifactsScreen> createState() => _ArtifactsScreenState();
}

/// What the page lists: every artifact, or only figures (with where each is used).
enum ArtifactsView { all, figures }

class _ArtifactsScreenState extends ConsumerState<ArtifactsScreen> {
  final _query = TextEditingController();
  String _filter = '';
  ArtifactsView _view = ArtifactsView.all;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(LibraryArtifact item) {
    ref.read(pendingArtifactOpenProvider)[item.conversationId] = item.artifact.id;
    context.go(Routes.chat(item.conversationId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final library = ref.watch(artifactLibraryProvider);
    final all = library.value ?? const <LibraryArtifact>[];
    final figures = {for (final f in figuresInLibrary(all)) f.item: f.usedIn};
    final visible = all
        .where((a) => a.matches(_filter) && (_view == ArtifactsView.all || figures.containsKey(a)))
        .toList();

    return AdaptivePage(
      title: 'Artifacts',
      header: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: AdaptiveTextField(
                  controller: _query,
                  placeholder: 'Search artifacts…',
                  prefix: AdaptiveIcon(EveryIcon.search, size: 16, color: theme.textMuted),
                  onChanged: (q) => setState(() => _filter = q.trim().toLowerCase()),
                  textInputAction: TextInputAction.search,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: AdaptiveSegmented<ArtifactsView>(
                      values: ArtifactsView.values,
                      selected: _view,
                      label: (v) => switch (v) {
                        ArtifactsView.all => 'All',
                        ArtifactsView.figures => 'Figures',
                      },
                      onSelected: (v) => setState(() => _view = v),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                child: Text(
                  _view == ArtifactsView.figures
                      ? '${visible.length} figure${visible.length == 1 ? '' : 's'}'
                      : '${visible.length} artifact${visible.length == 1 ? '' : 's'}',
                  style: theme.type.callout.tint(theme.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: switch (library) {
                  AsyncLoading() when all.isEmpty => const Center(child: AdaptiveProgress()),
                  _ when visible.isEmpty =>
                    all.isEmpty
                        ? BrandEmptyState(
                            kind: 'empty-chats',
                            title: 'No artifacts yet',
                            message: 'Documents, code, web pages, diagrams and images made in your chats collect here.',
                            action: AdaptiveButton(label: 'New chat', onPressed: () => context.go(Routes.newChat)),
                          )
                        : const BrandEmptyState(
                            kind: 'no-results',
                            title: 'No artifacts match',
                            message: 'Try other words.',
                          ),
                  _ => ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final item in visible)
                        AdaptiveListTile(
                          leading: _view == ArtifactsView.figures && item.artifact.latest.kind == VisualKind.svg
                              ? SizedBox(
                                  width: 48,
                                  height: 36,
                                  child: SvgView(
                                    svg:
                                        item.artifact.latest.args['svg'] as String? ??
                                        item.artifact.latest.str('content'),
                                    maxHeight: 36,
                                  ),
                                )
                              : AdaptiveIcon(iconOf(item.artifact.latest.kind), size: 18, color: theme.accent),
                          title: Text(item.artifact.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [
                              if (_view == ArtifactsView.figures) item.artifact.id else item.artifact.latest.kind.label,
                              item.chatTitle,
                              if (_view == ArtifactsView.figures)
                                switch (figures[item] ?? const []) {
                                  [] => 'not used yet',
                                  final used => 'in ${used.join(', ')}',
                                },
                              if (item.artifact.versions.length > 1) '${item.artifact.versions.length} versions',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _open(item),
                        ),
                    ],
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

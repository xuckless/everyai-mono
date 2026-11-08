import 'dart:convert';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../domain/notebook.dart';

/// A Jupyter notebook in the Files tab, read-only: Markdown cells rendered, code cells in mono with their run count,
/// and the outputs saved with them (text, errors in red, pictures). Nothing runs; the agent edits with notebook_edit.
class NotebookView extends StatelessWidget {
  const NotebookView({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final nb = parseNotebook(text);
    if (nb == null) {
      return Center(child: Text('This notebook could not be read.', style: theme.type.callout.tint(theme.textMuted)));
    }
    final mono = theme.type.caption.mono.copyWith(color: theme.text, height: 1.45);
    return ListView(
      key: const ValueKey('files.notebook'),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
      children: [
        for (final c in nb.cells)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: c.type == 'markdown'
                ? ChatMarkdown(c.source)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        c.type == 'code' ? '[${c.count ?? ' '}]' : c.type,
                        style: theme.type.micro.mono.tint(theme.textSubtle),
                      ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.surfaceRaised,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.border),
                        ),
                        child: SelectableText(c.source, style: mono),
                      ),
                      for (final o in c.outputs) _Output(o, mono: mono),
                    ],
                  ),
          ),
      ],
    );
  }
}

class _Output extends StatelessWidget {
  const _Output(this.output, {required this.mono});

  final NotebookOutput output;
  final TextStyle mono;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final image = output.image;
    Widget? picture;
    if (image != null) {
      try {
        picture = Image.memory(base64Decode(image), fit: BoxFit.contain, alignment: Alignment.centerLeft);
      } on FormatException {
        picture = null;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 8),
      child:
          picture ??
          SelectableText(
            output.text.trimRight(),
            style: mono.copyWith(color: output.error ? theme.danger : theme.textMuted),
          ),
    );
  }
}

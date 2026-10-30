import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';

/// The panel's text editor for an artifact's source (Markdown, code, HTML,
/// SVG or Mermaid). ⌘S / Ctrl+S saves, Esc cancels.
class ArtifactTextEditor extends StatefulWidget {
  const ArtifactTextEditor({
    super.key,
    required this.initialText,
    required this.onChanged,
    required this.onSave,
    required this.onCancel,
  });

  final String initialText;
  final ValueChanged<String> onChanged;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  State<ArtifactTextEditor> createState() => _ArtifactTextEditorState();
}

class _ArtifactTextEditorState extends State<ArtifactTextEditor> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): widget.onSave,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): widget.onSave,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
      },
      child: ColoredBox(
        color: theme.background,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 32),
          child: AdaptiveTextField(
            controller: _controller,
            autofocus: true,
            borderless: true,
            minLines: 24,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            onChanged: widget.onChanged,
          ),
        ),
      ),
    );
  }
}

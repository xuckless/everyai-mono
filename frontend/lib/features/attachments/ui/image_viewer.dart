import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';

/// Shows [bytes] full size in a dialog: pinch or scroll to zoom, drag to pan, double-tap to toggle 2.5x, Esc or a
/// tap on the backdrop to close.
Future<void> showImageViewer(BuildContext context, Uint8List bytes, {String? label}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close image',
    barrierColor: const Color(0xE6000000),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, _, _) => ImageViewer(bytes: bytes, label: label),
    transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
}

class ImageViewer extends StatefulWidget {
  const ImageViewer({super.key, required this.bytes, this.label});

  final Uint8List bytes;
  final String? label;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final _transform = TransformationController();
  Offset _tap = Offset.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (!_transform.value.isIdentity()) {
      _transform.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    // Zoom about the tapped point.
    _transform.value = Matrix4.identity()
      ..translateByDouble(-_tap.dx * (scale - 1), -_tap.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop()},
      child: Focus(
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
              child: const SizedBox.expand(),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: GestureDetector(
                onDoubleTapDown: (d) => _tap = d.localPosition,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _transform,
                  maxScale: 8,
                  child: Center(
                    child: Image.memory(widget.bytes, fit: BoxFit.contain, semanticLabel: widget.label),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: AdaptiveIconButton(
                icon: EveryIcon.close,
                tooltip: 'Close',
                color: const Color(0xFFFFFFFF),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

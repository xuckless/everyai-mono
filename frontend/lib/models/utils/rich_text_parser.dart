import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_tex/flutter_tex.dart'; // Import flutter_tex for LaTeX support
import '../../widgets/chat-screen-widgets/code_block_widget.dart';

class RichTextParser {
  /// Parses the given [message] and returns a list of [InlineSpan] for rendering in rich text.
  static List<InlineSpan> parseMessage(String message, BuildContext context) {
    final List<InlineSpan> spans = [];

    // Parse Markdown into an AST (Abstract Syntax Tree)
    final md.Document document = md.Document(
      inlineSyntaxes: [md.CodeSyntax()],
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );

    final List<md.Node> nodes = document.parseLines(message.split('\n'));

    for (final node in nodes) {
      if (node is md.Element) {
        spans.addAll(_parseElement(node));
      } else if (node is md.Text) {
        spans.add(TextSpan(text: node.text));
      }
    }

    return spans;
  }

  /// Parses individual Markdown elements and returns a list of [InlineSpan].
  static List<InlineSpan> _parseElement(md.Element element) {
    final List<InlineSpan> spans = [];

    switch (element.tag) {
      case 'h1':
        spans.add(_styledText('${element.textContent}\n\n', fontSize: 24, fontWeight: FontWeight.bold));
        break;
      case 'h2':
        spans.add(_styledText('${element.textContent}\n\n', fontSize: 20, fontWeight: FontWeight.bold));
        break;
      case 'h3':
        spans.add(_styledText('${element.textContent}\n\n', fontSize: 18, fontWeight: FontWeight.bold));
        break;
      case 'ul':
        spans.addAll(_parseList(element, bullet: '• '));
        spans.add(const TextSpan(text: '\n')); // Add spacing after lists
        break;
      case 'ol':
        spans.addAll(_parseList(element, isOrdered: true));
        spans.add(const TextSpan(text: '\n')); // Add spacing after lists
        break;
      case 'blockquote':
        spans.add(_buildBlockquote(element.textContent));
        spans.add(const TextSpan(text: '\n\n')); // Add spacing after blockquotes
        break;
      case 'pre':
        spans.add(_buildCodeBlock(element.textContent.trim()));
        spans.add(const TextSpan(text: '\n\n')); // Add spacing after code blocks
        break;
      case 'strong':
        spans.add(_styledText(element.textContent, fontWeight: FontWeight.bold));
        break;
      case 'em':
        spans.add(_styledText(element.textContent, fontStyle: FontStyle.italic));
        break;
      case 'code':
        spans.add(_styledText(
          element.textContent,
          fontFamily: 'SourceCodePro',
          backgroundColor: Colors.grey.shade200,
          color: Colors.black,
        ));
        break;
      case 'latex': // Add support for LaTeX
        spans.add(_buildLatex(element.textContent));
        break;
      case 'a':
        spans.add(_buildLink(element.textContent, element.attributes['href'] ?? ''));
        break;
      case 'hr':
        spans.add(_buildDivider());
        spans.add(const TextSpan(text: '\n\n')); // Add spacing after horizontal rules
        break;
      default:
        spans.add(TextSpan(text: element.textContent));
    }

    return spans;
  }

  /// Parses list elements and returns [InlineSpan]s.
  static List<InlineSpan> _parseList(md.Element list, {String bullet = '', bool isOrdered = false, int indentLevel = 0}) {
    final List<InlineSpan> spans = [];
    int index = 1;

    for (final item in list.children ?? []) {
      if (item is md.Element && item.tag == 'li') {
        final prefix = isOrdered ? '$index. ' : bullet;

        // Add indentation for nested lists
        final String indentation = '  ' * indentLevel;

        spans.add(_styledText('$indentation$prefix${item.textContent}\n', fontSize: 14));

        // Check for nested lists within this list item
        for (final child in item.children ?? []) {
          if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
            spans.addAll(_parseList(child, bullet: '• ', isOrdered: child.tag == 'ol', indentLevel: indentLevel + 1));
          }
        }

        index++;
      }
    }

    return spans;
  }

  /// Builds a LaTeX widget span using flutter_tex.
  static WidgetSpan _buildLatex(String latexContent) {
    return WidgetSpan(
      child: TeXView(
        child: TeXViewDocument(
          latexContent,
          style: const TeXViewStyle(
          ),
        ),
      ),
    );
  }

  /// Returns a styled text span.
  static TextSpan _styledText(
      String text, {
        double? fontSize,
        FontWeight? fontWeight,
        FontStyle? fontStyle,
        String? fontFamily,
        Color? color,
        Color? backgroundColor,
      }) {
    return TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        fontFamily: fontFamily,
        color: color,
        backgroundColor: backgroundColor,
      ),
    );
  }

  /// Builds a blockquote widget span.
  static WidgetSpan _buildBlockquote(String text) {
    return WidgetSpan(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          border: Border(left: BorderSide(width: 4.0, color: Colors.grey.shade500)),
        ),
        child: Text(
          text,
          style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
        ),
      ),
    );
  }

  /// Builds a code block widget span.
  static WidgetSpan _buildCodeBlock(String codeContent) {
    return WidgetSpan(
      child: CodeBlockWidget(codeContent: codeContent),
    );
  }

  /// Builds a divider widget span.
  static WidgetSpan _buildDivider() {
    return WidgetSpan(
      child: Divider(color: Colors.grey, thickness: 1.0),
    );
  }

  /// Builds a link text span with a tap recognizer.
  static TextSpan _buildLink(String text, String url) {
    return TextSpan(
      text: text,
      style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
      recognizer: TapGestureRecognizer()..onTap = () => debugPrint('Link tapped: $url'),
    );
  }
}
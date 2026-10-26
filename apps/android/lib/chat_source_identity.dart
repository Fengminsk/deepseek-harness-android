import 'package:material_ui/material_ui.dart';

/// A local domain cue. No remote favicon request is made while reading chat.
class ChatSourceHostMark extends StatelessWidget {
  const ChatSourceHostMark({required this.host, this.size = 28, super.key});

  final String host;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = host.toLowerCase().startsWith('www.')
        ? host.substring(4)
        : host;
    final letter = name.isEmpty ? '?' : name[0].toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.surfaceContainerHighest,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Text(
          letter,
          style: TextStyle(
            fontSize: size * .48,
            fontWeight: FontWeight.w700,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

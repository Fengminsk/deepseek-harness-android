import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'chat_site_marks.g.dart';

String? chatSiteMarkPath(String host) {
  final normalized = host.toLowerCase();
  String? match;
  var length = 0;
  for (final entry in chatSitePaths.entries) {
    if ((normalized == entry.key || normalized.endsWith('.${entry.key}')) &&
        entry.key.length > length) {
      match = entry.value;
      length = entry.key.length;
    }
  }
  return match;
}

/// A local domain cue. No remote favicon request is made while reading chat.
class ChatSourceHostMark extends StatelessWidget {
  const ChatSourceHostMark({required this.host, this.size = 28, super.key});

  final String host;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final path = chatSiteMarkPath(host);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.onSurface.withValues(alpha: .04),
        ),
        child: path == null
            ? Icon(
                Icons.language_rounded,
                size: size * .72,
                color: colors.onSurfaceVariant,
              )
            : SvgPicture.string(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 28 28"><path d="$path"/></svg>',
                width: size * .85,
                height: size * .85,
                colorFilter: ColorFilter.mode(
                  colors.onSurface,
                  BlendMode.srcIn,
                ),
              ),
      ),
    );
  }
}

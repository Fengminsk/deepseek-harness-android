import 'package:material_ui/material_ui.dart';

import 'ui.dart';

/// A settings row keeps the label and value legible at narrow widths and large
/// text scales. The owning group supplies its rectangular press and dividers;
/// editing takes place on a separate page.
class ConfigurationValueRow extends StatelessWidget {
  const ConfigurationValueRow({
    required this.title,
    required this.summary,
    this.onTap,
    this.protected = false,
    super.key,
  });

  final String title, summary;
  final VoidCallback? onTap;
  final bool protected;

  double _singleLineWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.didExceedMaxLines ? double.infinity : painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) => PocketTile(
    onTap: onTap,
    title: LayoutBuilder(
      builder: (context, bounds) {
        final titleStyle = DefaultTextStyle.of(context).style;
        final summaryStyle = titleStyle.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
        final sameLine =
            title.length + summary.length <= 256 &&
            _singleLineWidth(context, title, titleStyle) +
                    _singleLineWidth(context, summary, summaryStyle) +
                    16 <=
                bounds.maxWidth;
        final titleText = Text(title);
        final summaryText = Text(summary, style: summaryStyle);
        return sameLine
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [titleText, summaryText],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [titleText, const SizedBox(height: 4), summaryText],
              );
      },
    ),
    trailing: Icon(
      protected ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
      size: 18,
      color: Theme.of(context).colorScheme.outline,
    ),
  );
}

import 'package:material_ui/material_ui.dart';

import 'ui.dart';

/// A settings row keeps its value summary beside its label. The owning group
/// supplies clipping and dividers; editing takes place on a separate page.
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

  @override
  Widget build(BuildContext context) => PocketTile(
    onTap: onTap,
    title: Row(
      children: [
        Expanded(
          flex: 5,
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 4,
          child: Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
    trailing: Icon(
      protected ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
      size: 18,
      color: Theme.of(context).colorScheme.outline,
    ),
  );
}

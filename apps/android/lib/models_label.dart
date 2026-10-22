import 'package:material_ui/material_ui.dart';

/// Mirrors the original ui-deepseek-model-label-1017 display-only predicate.
/// Keep the catalog name and routing ID untouched; this is never an alias.
bool showsDeepSeek1017Badge({
  required String providerId,
  required String modelId,
  required String modelName,
  bool enabled = true,
}) =>
    enabled &&
    (providerId == 'deepseek-account' || providerId == 'deepseek-official') &&
    modelId == 'deepseek-flash' &&
    modelName == 'DeepSeek-V4.1-Flash';

/// Inline presentation used by model selection surfaces, never by API calls.
class ModelReleaseLabel extends StatelessWidget {
  const ModelReleaseLabel({
    super.key,
    required this.providerId,
    required this.modelId,
    required this.modelName,
    this.suffix,
    this.badgeEnabled = true,
  });

  final String providerId;
  final String modelId;
  final String modelName;
  final String? suffix;
  final bool badgeEnabled;

  @override
  Widget build(BuildContext context) {
    final badge = showsDeepSeek1017Badge(
      providerId: providerId,
      modelId: modelId,
      modelName: modelName,
      enabled: badgeEnabled,
    );
    if (!badge) return Text('$modelName${suffix ?? ''}');
    final colors = Theme.of(context).colorScheme;
    final style = DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: modelName),
          const TextSpan(text: ' '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                child: Text(
                  '1017',
                  style: style.copyWith(
                    fontSize: 11,
                    height: 1.1,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
          if (suffix != null) TextSpan(text: suffix),
        ],
      ),
    );
  }
}

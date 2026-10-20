// Extracted from FlClash v0.9.1; see licenses/flclash-source.json.
import 'package:material_ui/material_ui.dart';

import 'context.dart';
import 'elastic_press.dart';

/// The M3 switch at 52 × 32 with a 24 dp thumb in both states and no outline,
/// so an off switch reads as a solid track.
class DashboardSwitch extends StatelessWidget {
  const DashboardSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  static const _thumbIcon = WidgetStatePropertyAll(Icon(null));

  /// A shrink-wrapped Switch still lays out 4 dp above and below its track,
  /// which would set the height of every row it sits in.
  static const trackWidth = 52.0;
  static const _trackHeight = 32.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Semantics(
      label: semanticLabel,
      child: ElasticPress(
        enabled: onChanged != null,
        child: SizedBox(
          width: trackWidth,
          height: _trackHeight,
          child: OverflowBox(
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Switch(
              value: value,
              onChanged: onChanged,
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              thumbIcon: _thumbIcon,
              overlayColor: const WidgetStateMapper<Color?>({
                WidgetState.pressed: Colors.transparent,
              }),
              trackOutlineColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              trackOutlineWidth: const WidgetStatePropertyAll(0),
              trackColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colorScheme.primary
                    : colorScheme.surfaceContainerHighest,
              ),
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colorScheme.onPrimary
                    : colorScheme.outline,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

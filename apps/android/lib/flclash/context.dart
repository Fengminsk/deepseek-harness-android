import 'package:material_ui/material_ui.dart';

/// Host adapter used by the imported FlClash glass component.
extension GlassMotionContext on BuildContext {
  ColorScheme get colorScheme => Theme.of(this).colorScheme;
  Duration motionDuration(Duration duration) =>
      MediaQuery.disableAnimationsOf(this) ? Duration.zero : duration;
}

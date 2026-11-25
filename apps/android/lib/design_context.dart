import 'package:material_ui/material_ui.dart';

/// Host adapter the vendored glass components build against.
///
/// The adapted copies read the surrounding Material theme and this app's
/// reduced-motion setting through it, so they carry no dependency on
/// FlClash's own settings or on a particular theme implementation.
extension GlassMotionContext on BuildContext {
  /// The surrounding Material color scheme.
  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  /// [duration], or nothing when the system asks for reduced motion.
  Duration motionDuration(Duration duration) =>
      MediaQuery.disableAnimationsOf(this) ? Duration.zero : duration;
}

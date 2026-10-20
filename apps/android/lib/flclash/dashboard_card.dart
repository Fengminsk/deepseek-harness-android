// Extracted from FlClash v0.9.1; see licenses/flclash-source.json.
import 'package:material_ui/material_ui.dart';

import 'context.dart';
import 'shape.dart';
import 'surface.dart';

/// Values are the design's CSS shadows. A CSS blur is twice its sigma while
/// Flutter turns a blur radius r into a sigma of 0.577 r + 0.5, so each one
/// goes through [_blur] or it renders a third heavier.
abstract final class DashboardShadows {
  static List<BoxShadow> e1(BuildContext context) =>
      context.colorScheme.brightness == Brightness.dark ? _e1Dark : _e1Light;

  static List<BoxShadow> e2(BuildContext context) =>
      context.colorScheme.brightness == Brightness.dark ? _e2Dark : _e2Light;

  static BoxShadow _shadow(
    int alpha,
    double y,
    double cssBlur, [
    double spread = 0,
  ]) => BoxShadow(
    color: Color.fromARGB(alpha, 0, 0, 0),
    offset: Offset(0, y),
    blurRadius: _blur(cssBlur),
    spreadRadius: spread,
  );

  static double _blur(double cssBlur) =>
      cssBlur <= 1 ? 0 : (cssBlur / 2 - 0.5) / 0.57735;

  static final _e1Light = [
    _shadow(0x0D, 0.5, 1),
    _shadow(0x0A, 2, 6),
    _shadow(0x17, 12, 32, -6),
  ];

  static final _e1Dark = [_shadow(0x80, 1, 2), _shadow(0x8C, 10, 28, -6)];

  static final _e2Light = [
    _shadow(0x0F, 1, 3),
    _shadow(0x14, 10, 24),
    _shadow(0x38, 32, 64, -12),
  ];

  static final _e2Dark = [_shadow(0x80, 2, 6), _shadow(0xB3, 32, 64, -12)];
}

/// Mobile DashboardCard, with host-independent density and color lookup.
class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.onTap,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final shape = AppShape.all(34);
    final content = Padding(padding: padding, child: child);
    return Container(
      decoration: ShapeDecoration(
        color: SurfaceLevel.card.colorOf(context.colorScheme),
        shape: shape,
        shadows: DashboardShadows.e1(context),
      ),
      child: SurfaceScope(
        level: SurfaceLevel.card,
        child: Material(
          type: MaterialType.transparency,
          child: onTap == null
              ? content
              : FocusRing(
                  shape: shape,
                  child: InkWell(
                    customBorder: shape,
                    onTap: onTap,
                    child: content,
                  ),
                ),
        ),
      ),
    );
  }
}

// SPDX-License-Identifier: GPL-3.0-only
// Adapted from FlClash v0.9.1 lib/ui/sheet_header.dart; see licenses/flclash-source.json.
import 'package:material_ui/material_ui.dart';

/// A floating header's surface dissolves into the content below it. Its
/// overhang paints outside the toolbar without reducing the scroll viewport.
class FloatingHeader extends StatelessWidget {
  const FloatingHeader({
    super.key,
    required this.backgroundColor,
    this.fadeStart = .5,
    this.overhang = 0,
    required this.child,
  });
  final Color backgroundColor;
  final double fadeStart, overhang;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        bottom: -overhang,
        child: FloatingEdgeScrim(
          backgroundColor: backgroundColor,
          fadeStart: fadeStart,
          overhang: overhang,
        ),
      ),
      child,
    ],
  );
}

/// FlClash's eased eight-step surface fade, shared by page, sheet and sidebar
/// chrome. It paints only: content and pointer events continue underneath.
class FloatingEdgeScrim extends StatelessWidget {
  const FloatingEdgeScrim({
    super.key,
    required this.backgroundColor,
    this.fadeStart = .5,
    this.overhang = 0,
    this.bottom = false,
  });
  final Color backgroundColor;
  final double fadeStart, overhang;
  final bool bottom;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final start = height <= 0
            ? 0.0
            : ((height - overhang) * fadeStart / height).clamp(0.0, 1.0);
        final stops = <double>[0];
        final colors = <Color>[backgroundColor.withValues(alpha: .9)];
        for (var i = 0; i <= 8; i++) {
          final t = i / 8;
          stops.add(start + (1 - start) * t);
          colors.add(
            backgroundColor.withValues(
              alpha: .9 * (1 - Curves.easeInOut.transform(t)),
            ),
          );
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: bottom ? Alignment.bottomCenter : Alignment.topCenter,
              end: bottom ? Alignment.topCenter : Alignment.bottomCenter,
              stops: stops,
              colors: colors,
            ),
          ),
        );
      },
    ),
  );
}

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// A quiet console-inspired ambient field with distant light and a drifting
/// ribbon. Static atmosphere and moving light have separate paint boundaries.
class DaylightBackdrop extends StatefulWidget {
  const DaylightBackdrop({this.suspendMotion, super.key});
  final ValueListenable<bool>? suspendMotion;

  @override
  State<DaylightBackdrop> createState() => _DaylightBackdropState();
}

class _DaylightBackdropState extends State<DaylightBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void initState() {
    super.initState();
    widget.suspendMotion?.addListener(_syncMotion);
  }

  @override
  void didUpdateWidget(DaylightBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.suspendMotion != widget.suspendMotion) {
      oldWidget.suspendMotion?.removeListener(_syncMotion);
      widget.suspendMotion?.addListener(_syncMotion);
      _syncMotion();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  void _syncMotion() {
    final animate =
        widget.suspendMotion?.value != true &&
        !MediaQuery.disableAnimationsOf(context) &&
        Theme.of(context).colorScheme.surface.toARGB32() != 0xff000000;
    if (animate && !_ripple.isAnimating) {
      _ripple.repeat();
    } else if (!animate) {
      _ripple.stop();
    }
  }

  @override
  void dispose() {
    widget.suspendMotion?.removeListener(_syncMotion);
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(painter: _DaylightPainter(scheme)),
            ),
            if (scheme.surface.toARGB32() != 0xff000000)
              RepaintBoundary(
                child: CustomPaint(painter: _RipplePainter(scheme, _ripple)),
              ),
          ],
        ),
      ),
    );
  }
}

class _DaylightPainter extends CustomPainter {
  const _DaylightPainter(this.scheme);
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || scheme.surface.toARGB32() == 0xff000000) return;
    final dark = scheme.brightness == Brightness.dark;
    final rect = Offset.zero & size;
    const cool = Color(0xff6d91c5);
    const pearl = Color(0xffd9d3c3);
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-1.05, -.3),
          radius: 1.5,
          colors: [
            cool.withValues(alpha: dark ? .075 : .10),
            cool.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(1.2, -.65),
          radius: 1.45,
          colors: [
            pearl.withValues(alpha: dark ? .035 : .16),
            pearl.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );

    // The page stays smooth; micrograin belongs to glass surfaces, not a
    // full-screen texture. No shafts, polygon edges or per-frame blur targets.
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DaylightPainter oldDelegate) =>
      scheme != oldDelegate.scheme;
}

class _RipplePainter extends CustomPainter {
  _RipplePainter(this.scheme, this.phase) : super(repaint: phase);
  final ColorScheme scheme;
  final Animation<double> phase;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final dark = scheme.brightness == Brightness.dark;
    final rect = Offset.zero & size;
    final time = phase.value * math.pi * 2;
    final light = dark ? const Color(0xffa2b5d5) : const Color(0xff9daec7);
    canvas.save();
    canvas.clipRect(rect);
    final drift = math.sin(time) * size.height * .012;
    final path = Path()
      ..moveTo(-size.width * .2, size.height * .24 + drift)
      ..cubicTo(
        size.width * .55,
        size.height * .23 - drift,
        size.width * .18,
        size.height * .63 + drift,
        size.width * 1.2,
        size.height * .65,
      );
    // Feather the same curve with translucent strokes. Cost stays bounded;
    // unlike MaskFilter, these do not allocate offscreen blur surfaces.
    for (var band = 12; band >= 1; band--) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * .018 * band
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              light.withValues(alpha: 0),
              light.withValues(alpha: dark ? .0025 : .0035),
              light.withValues(alpha: dark ? .004 : .005),
              light.withValues(alpha: 0),
            ],
            stops: const [0, .25, .7, 1],
          ).createShader(rect),
      );
    }
    final paint = Paint();
    for (var i = 0; i < 26; i++) {
      final x = ((i * .61803398875 + .13) % 1) * size.width;
      final y = ((i * .38196601125 + .17) % 1) * size.height;
      final twinkle = .65 + .35 * math.sin(time + i * 1.7);
      final center = Offset(
        x + math.sin(time + i) * 2,
        y + math.cos(time + i) * 3,
      );
      paint.color = light.withValues(alpha: (dark ? .035 : .055) * twinkle);
      canvas.drawCircle(center, i % 7 == 0 ? 1.15 : .65, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) =>
      scheme != oldDelegate.scheme || phase != oldDelegate.phase;
}

/// A quiet frosted surface for long lists. It borrows the page's light, but does
/// not create another live blur/capture for every row.
class DaylightSurface extends StatelessWidget {
  const DaylightSurface({
    super.key,
    required this.shape,
    required this.color,
    required this.enabled,
    required this.child,
    this.shadows = const [],
  });
  final ShapeBorder shape;
  final Color color;
  final bool enabled;
  final Widget child;
  final List<BoxShadow> shadows;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: enabled ? null : color,
        gradient: enabled
            ? LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  Color.lerp(
                    color,
                    dark ? const Color(0xffc6c7bc) : Colors.white,
                    dark ? .035 : .4,
                  )!.withValues(alpha: .94),
                  color.withValues(alpha: dark ? .87 : .76),
                  color.withValues(alpha: .93),
                ],
                stops: const [0, .55, 1],
              )
            : null,
        shape: shape,
        shadows: shadows,
      ),
      child: CustomPaint(
        painter: enabled ? DaylightFinish(shape: shape, dark: dark) : null,
        child: child,
      ),
    );
  }
}

/// Paint before the content, so fine grain never reduces text/icon sharpness.
class DaylightFinish extends CustomPainter {
  const DaylightFinish({required this.shape, required this.dark});
  final ShapeBorder shape;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final path = shape.getOuterPath(rect);
    canvas.save();
    canvas.clipPath(path);
    DaylightGrain.paint(canvas, rect, dark: dark);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            Colors.white.withValues(alpha: dark ? .24 : .9),
            Colors.white.withValues(alpha: dark ? .035 : .25),
            const Color(0xff647477).withValues(alpha: dark ? .13 : .16),
          ],
          stops: const [0, .45, 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(DaylightFinish oldDelegate) =>
      shape != oldDelegate.shape || dark != oldDelegate.dark;
}

/// Seeded, sparse micrograin: no random shimmer when a widget repaints.
abstract final class DaylightGrain {
  static const _tile = 96.0;
  static final _points = _makePoints();
  static List<Offset> _makePoints() {
    final random = math.Random(4107);
    return List.generate(
      220,
      (_) => Offset(random.nextDouble() * _tile, random.nextDouble() * _tile),
    );
  }

  static void paint(Canvas canvas, Rect rect, {required bool dark}) {
    final paint = Paint()
      ..color = (dark ? Colors.white : const Color(0xff42535a)).withValues(
        alpha: dark ? .027 : .04,
      )
      ..strokeWidth = .5;
    canvas.save();
    canvas.clipRect(rect);
    for (var y = rect.top; y < rect.bottom; y += _tile) {
      for (var x = rect.left; x < rect.right; x += _tile) {
        canvas.save();
        canvas.translate(x, y);
        canvas.drawPoints(ui.PointMode.points, _points, paint);
        canvas.restore();
      }
    }
    canvas.restore();
  }
}

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Shared entrance motion. It changes painting only; layout and scroll extent
/// are final from the first frame. Retained content never repeats its entrance.
abstract final class PocketEntryMotion {
  static const duration = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;
  static const blur = 6.0;
}

/// Reuses an owner's animation for a newly visible surface or transcript row.
class PocketBlurTransition extends StatelessWidget {
  const PocketBlurTransition({
    super.key,
    required this.animation,
    required this.child,
  });
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final parentEntering = _EntryScope.activeOf(context);
        final disabled = MediaQuery.disableAnimationsOf(context);
        final progress = disabled || parentEntering
            ? 1.0
            : animation.value.clamp(0.0, 1.0);
        return _EntryScope(
          active: parentEntering || progress < .999,
          child: ImageFiltered(
            enabled: progress < .999,
            imageFilter: ui.ImageFilter.blur(
              sigmaX: PocketEntryMotion.blur * (1 - progress),
              sigmaY: PocketEntryMotion.blur * (1 - progress),
            ),
            child: Opacity(opacity: progress, child: child),
          ),
        );
      },
    );
  }
}

class _EntryScope extends InheritedWidget {
  const _EntryScope({required this.active, required super.child});
  final bool active;
  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EntryScope>()?.active ??
      false;
  @override
  bool updateShouldNotify(_EntryScope oldWidget) => active != oldWidget.active;
}

/// Apply at shared UI boundaries, not to every text token. New children inside
/// an entering surface share that one filter; later insertions animate alone.
class PocketReveal extends StatefulWidget {
  const PocketReveal({super.key, this.animate = true, required this.child});

  /// Whether this mount represents new content. A recycled list row suppresses
  /// its whole initial subtree, then lets genuinely new descendants enter.
  /// Changing this after mounting never replays an existing entrance.
  final bool animate;
  final Widget child;
  @override
  State<PocketReveal> createState() => _PocketRevealState();
}

class _PocketRevealState extends State<PocketReveal>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: PocketEntryMotion.duration,
  );
  late final animation = CurvedAnimation(
    parent: controller,
    curve: PocketEntryMotion.curve,
  );
  bool started = false;
  bool suppressInitialChildren = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    final parentEntering = _EntryScope.activeOf(context);
    if (!started) {
      started = true;
      if (!widget.animate) {
        suppressInitialChildren = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => suppressInitialChildren = false);
        });
      }
      if (!widget.animate || disabled || parentEntering) {
        controller.value = 1;
      } else {
        controller.forward();
      }
    } else if (disabled && controller.value != 1) {
      controller.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) => _EntryScope(
    active: _EntryScope.activeOf(context) || suppressInitialChildren,
    child: PocketBlurTransition(animation: animation, child: widget.child),
  );

  @override
  void dispose() {
    animation.dispose();
    controller.dispose();
    super.dispose();
  }
}

// SPDX-License-Identifier: GPL-3.0-only
// Adapted from FlClash v0.9.1; see licenses/flclash-source.json.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'context.dart';
import 'liquid_glass.dart';
import 'motion.dart';
import 'shape.dart';
import 'surface.dart';
import 'typography.dart';

final _selectionCurve = SpringCurve(
  SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 330),
    bounce: .12,
  ),
  seconds: .4,
);

/// A controlled selection. Dragging only previews a value; release commits
/// once. A null [onChanged] disables pointer, keyboard and semantic actions.
class SegmentedControl<T> extends StatefulWidget {
  const SegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> segments;
  final T value;
  final ValueChanged<T>? onChanged;

  @override
  State<SegmentedControl<T>> createState() => _SegmentedControlState<T>();
}

class _SegmentedControlState<T> extends State<SegmentedControl<T>>
    with TickerProviderStateMixin {
  static const _inset = 4.0;
  // FlClash's lifted navigation lens grows eight dp on each edge.
  static const _lensGrowth = 8.0;
  final _focus = FocusNode();
  late final AnimationController _position, _press;
  late final Listenable _motion;
  bool _active = false, _dragging = false;
  bool _invalidated = false;
  bool _reduceMotion = false;
  TextDirection? _direction;
  double _width = 0, _height = 0;

  int get _selectedIndex =>
      widget.segments.indexWhere((segment) => segment.$1 == widget.value);
  bool get _enabled => widget.onChanged != null && widget.segments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _position = AnimationController.unbounded(
      vsync: this,
      value: math.max(0, _selectedIndex).toDouble(),
    );
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _motion = Listenable.merge([_position, _press]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final direction = Directionality.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (_direction != null && direction != _direction) {
      _invalidated = true;
      _abandon();
    }
    _direction = direction;
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      if (reduce) {
        _position.stop();
        if (!_active) _position.value = math.max(0, _selectedIndex).toDouble();
        _press.value = _active ? 1 : 0;
      }
    }
  }

  @override
  void didUpdateWidget(covariant SegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.value != widget.value ||
        !listEquals(oldWidget.segments, widget.segments);
    if (changed || !_enabled) {
      // An owner update invalidates the uncommitted gesture, including an
      // external preference change arriving while the finger is still down.
      _invalidated = true;
      _abandon();
    }
  }

  void _animateTo(double target) {
    if (_reduceMotion) {
      _position.value = target;
    } else {
      _position.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: _selectionCurve,
      );
    }
  }

  void _setPressed(bool pressed) {
    if (_reduceMotion) {
      _press.value = pressed ? 1 : 0;
    } else if (pressed) {
      _press.forward();
    } else {
      _press.reverse();
    }
  }

  double _positionAt(Offset point) {
    final physical = point.dx / (_width / widget.segments.length) - .5;
    final logical = _direction == TextDirection.rtl
        ? widget.segments.length - 1 - physical
        : physical;
    return logical.clamp(0.0, widget.segments.length - 1.0);
  }

  void _begin(DragDownDetails details) {
    if (!_enabled || _width <= 0) return;
    setState(() {
      _active = true;
      _dragging = false;
      _invalidated = false;
    });
    _setPressed(true);
    _animateTo(_positionAt(details.localPosition));
  }

  void _start(DragStartDetails details) {
    if (!_enabled || !_active) return;
    _dragging = true;
    _position.value = _positionAt(details.localPosition);
  }

  void _move(DragUpdateDetails details) {
    if (!_active || !_dragging) return;
    if (details.localPosition.dy < -kTouchSlop ||
        details.localPosition.dy > _height + kTouchSlop) {
      _invalidated = true;
      setState(_abandon);
      return;
    }
    _position.value = _positionAt(details.localPosition);
  }

  void _abandon() {
    _active = false;
    _dragging = false;
    _setPressed(false);
    _animateTo(math.max(0, _selectedIndex).toDouble());
  }

  void _cancel() {
    if (!_active) return;
    // Losing to a vertical scroll or receiving pointer cancellation never
    // invokes the owner. A winning tap uses its own release coordinates.
    setState(_abandon);
  }

  void _pointerCancelled(PointerCancelEvent event) {
    // Once a drag has won its arena, Flutter reports PointerCancel as drag
    // end. Invalidate before that callback so cancellation cannot commit.
    _invalidated = true;
    if (_active) setState(_abandon);
  }

  void _commit(int index) {
    if (!_enabled || index < 0 || index >= widget.segments.length) return;
    _invalidated = true;
    setState(_abandon);
    final next = widget.segments[index].$1;
    if (next != widget.value) widget.onChanged!(next);
  }

  void _end(DragEndDetails details) {
    if (!_active || !_dragging) return;
    _commit(_position.value.round());
  }

  void _tap(TapUpDetails details) {
    if (!_enabled || _invalidated || _width <= 0) return;
    _commit(_positionAt(details.localPosition).round());
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!_enabled || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final current = _selectedIndex;
    int? target;
    if (key == LogicalKeyboardKey.home) {
      target = 0;
    } else if (key == LogicalKeyboardKey.end) {
      target = widget.segments.length - 1;
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final physicalStep = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
      final step = _direction == TextDirection.rtl
          ? -physicalStep
          : physicalStep;
      target = current < 0 ? 0 : current + step;
      target = target.clamp(0, widget.segments.length - 1);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.enter) {
      target = math.max(0, current);
    }
    if (target == null) return KeyEventResult.ignored;
    _commit(target);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _position.dispose();
    _press.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.segments.isEmpty) return const SizedBox.shrink();
    final colors = context.colorScheme;
    final glass = LiquidGlassScope.of(context);
    final style = AppTextStyle.subheadline.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = math.max(0, constraints.maxWidth - _inset * 2);
        final segmentWidth = _width / widget.segments.length;
        var labelHeight = 20.0;
        for (final segment in widget.segments) {
          final painter = TextPainter(
            text: TextSpan(
              text: segment.$2,
              style: style.copyWith(fontWeight: FontWeight.w600),
            ),
            textDirection: _direction!,
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 2,
          )..layout(maxWidth: math.max(0, segmentWidth - 12));
          labelHeight = math.max(labelHeight, painter.height);
          painter.dispose();
        }
        _height = math.max(36, labelHeight + 8);
        return Opacity(
          opacity: _enabled ? 1 : .5,
          child: FocusRing(
            shape: AppShape.full,
            child: Focus(
              focusNode: _focus,
              canRequestFocus: _enabled,
              onKeyEvent: _key,
              child: Container(
                padding: const EdgeInsets.all(_inset),
                decoration: ShapeDecoration(
                  color: colors.surfaceContainerHighest,
                  shape: AppShape.full,
                ),
                child: MouseRegion(
                  cursor: _enabled
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: Listener(
                    onPointerCancel: _pointerCancelled,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      dragStartBehavior: DragStartBehavior.down,
                      onHorizontalDragDown: _enabled ? _begin : null,
                      onHorizontalDragStart: _enabled ? _start : null,
                      onHorizontalDragUpdate: _enabled ? _move : null,
                      onHorizontalDragEnd: _enabled ? _end : null,
                      onHorizontalDragCancel: _enabled ? _cancel : null,
                      onTapUp: _enabled ? _tap : null,
                      child: SizedBox(
                        height: _height,
                        child: AnimatedBuilder(
                          animation: _motion,
                          builder: (context, _) {
                            final lift = Curves.easeOutCubic.transform(
                              _press.value,
                            );
                            final position = _position.value.clamp(
                              0.0,
                              widget.segments.length - 1.0,
                            );
                            final physical = _direction == TextDirection.rtl
                                ? widget.segments.length - 1 - position
                                : position;
                            final emphasized = _active
                                ? position.round()
                                : _selectedIndex;
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                if (_selectedIndex >= 0 || _active)
                                  Positioned(
                                    left: segmentWidth * physical,
                                    top: 0,
                                    width: segmentWidth,
                                    height: _height,
                                    child: IgnorePointer(
                                      child: Transform.scale(
                                        scaleX:
                                            _reduceMotion || segmentWidth == 0
                                            ? 1
                                            : 1 +
                                                  _lensGrowth *
                                                      2 *
                                                      lift /
                                                      segmentWidth,
                                        scaleY: _reduceMotion
                                            ? 1
                                            : 1 +
                                                  _lensGrowth *
                                                      2 *
                                                      lift /
                                                      _height,
                                        child: _SelectionThumb(
                                          glass: glass,
                                          lift: lift,
                                        ),
                                      ),
                                    ),
                                  ),
                                Row(
                                  children: [
                                    for (
                                      var i = 0;
                                      i < widget.segments.length;
                                      i++
                                    )
                                      Expanded(
                                        child: Semantics(
                                          selected: i == _selectedIndex,
                                          inMutuallyExclusiveGroup: true,
                                          button: true,
                                          enabled: _enabled,
                                          label: widget.segments[i].$2,
                                          onTap: _enabled
                                              ? () => _commit(i)
                                              : null,
                                          child: ExcludeSemantics(
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                  ),
                                              child: Center(
                                                child: Text(
                                                  widget.segments[i].$2,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  textAlign: TextAlign.center,
                                                  style: style.copyWith(
                                                    color: i == emphasized
                                                        ? colors.onSurface
                                                        : colors
                                                              .onSurfaceVariant,
                                                    fontWeight: i == emphasized
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SelectionThumb extends StatelessWidget {
  const _SelectionThumb({required this.glass, required this.lift});
  final bool glass;
  final double lift;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final platter = colors.brightness == Brightness.dark
        ? Color.alphaBlend(
            colors.onSurface.withValues(alpha: .2),
            colors.surfaceContainerHighest,
          )
        : colors.surfaceBright;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(
            color: glass
                ? platter.withValues(alpha: 1 - lift)
                : Color.alphaBlend(
                    colors.onSurface.withValues(alpha: .06 * lift),
                    platter,
                  ),
            shape: AppShape.full,
            shadows: [
              BoxShadow(
                color: colors.shadow.withValues(alpha: .12 * (1 - lift)),
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
        if (glass && lift > 0)
          LiquidGlass(
            style: LiquidGlassStyle.lens(colors).scale(lift),
            shadows: [
              BoxShadow(
                color: colors.shadow.withValues(alpha: .1 * lift),
                blurRadius: 5,
                offset: const Offset(0, 3),
              ),
            ],
          ),
      ],
    );
  }
}

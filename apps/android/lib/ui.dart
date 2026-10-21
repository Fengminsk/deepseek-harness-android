import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import 'flclash/drag_back.dart';
import 'flclash/liquid_glass.dart';
import 'flclash/page_transition.dart';
import 'flclash/shape.dart';
import 'flclash/surface.dart';
import 'flclash/typography.dart';
import 'flclash/color.dart';
import 'flclash/elastic_press.dart';
import 'flclash/button.dart';
import 'flclash/input.dart';
import 'flclash/switch.dart';
import 'flclash/dashboard_card.dart';
import 'flclash/floating_header.dart';
import 'entry_motion.dart';

export 'flclash/liquid_glass.dart';
export 'flclash/shape.dart';
export 'flclash/elastic_press.dart';
export 'flclash/button.dart';
export 'flclash/segmented_control.dart';
export 'flclash/floating_header.dart';

ThemeData pocketTheme(
  Brightness brightness, {
  Color seed = const Color(0xff556f63),
  ColorStyle style = ColorStyle.soft,
  bool pureBlack = false,
}) => ThemeData(
  useMaterial3: true,
  colorScheme: seededColorScheme(
    seedColor: seed,
    brightness: brightness,
    style: style,
  ).toPureBlack(pureBlack),
).withAppShapes.withAppSurfaces.withAppTypography;

/// The imported FlClash page motion, including interactive drag back.
class PocketRoute<T> extends PageRoute<T>
    with DragBackRouteMixin<T>, SharedXPageRouteMixin<T> {
  PocketRoute({required this.builder});
  final WidgetBuilder builder;
  @override
  bool sharesMotionWith(Route<dynamic>? route) =>
      route is PocketRoute || route is MaterialPageRoute;
  @override
  Color backdropOf(Color surface, {required bool dragging}) => surface;
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => MediaQuery.disableAnimationsOf(context)
      ? child
      : super.buildTransitions(context, animation, secondaryAnimation, child);
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    child: PocketReveal(child: builder(context)),
  );
}

class GlassSurface extends StatelessWidget {
  const GlassSurface({required this.child, this.radius = 30, super.key});
  final Widget child;
  final double radius;
  @override
  Widget build(BuildContext context) => !LiquidGlassScope.of(context)
      ? Material(
          color: SurfaceLevel.card.colorOf(Theme.of(context).colorScheme),
          shape: AppShape.all(radius),
          child: child,
        )
      : LiquidGlass(
          style: LiquidGlassStyle.regular(Theme.of(context).colorScheme),
          borderRadius: BorderRadius.circular(radius),
          child: child,
        );
}

/// A round FlClash control, including while its press follows a dragging finger.
class GlassButton extends StatelessWidget {
  const GlassButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.solid = false,
    super.key,
  }) : iconChild = null;
  const GlassButton.custom({
    required Widget icon,
    required this.label,
    this.onPressed,
    this.solid = false,
    super.key,
  }) : icon = null,
       iconChild = icon;
  final IconData? icon;
  final Widget? iconChild;
  final String label;
  final VoidCallback? onPressed;
  final bool solid;
  @override
  Widget build(BuildContext context) {
    final glass = LiquidGlassScope.of(context);
    final colors = Theme.of(context).colorScheme;
    return _CircleControl(
      builder: (side) => TonalButtonTheme(
        glass: glass,
        child: ElasticPress(
          enabled: onPressed != null,
          preserveAspectRatio: true,
          child: IconButton(
            tooltip: label,
            onPressed: onPressed,
            style:
                IconButton.styleFrom(
                  fixedSize: Size.square(side),
                  minimumSize: Size.square(side),
                  maximumSize: Size.square(side),
                  iconSize: math.min(24, side),
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                  backgroundColor: glass
                      ? Colors.transparent
                      : solid
                      ? colors.primary
                      : null,
                  disabledBackgroundColor: glass ? Colors.transparent : null,
                  foregroundColor: solid ? colors.onPrimary : null,
                ).copyWith(
                  backgroundBuilder: glass
                      ? (context, states, child) => LiquidGlass(
                          style: solid && !states.contains(WidgetState.disabled)
                              ? LiquidGlassStyle.tinted(colors, colors.primary)
                              : LiquidGlassStyle.regular(colors),
                          pressed:
                              !states.contains(WidgetState.disabled) &&
                              states.contains(WidgetState.pressed),
                          clipper: const _CircleControlClipper(),
                          child: child,
                        )
                      : null,
                ),
            icon: iconChild ?? Icon(icon),
          ),
        ),
      ),
    );
  }
}

/// Loosen rectangular parent minimums, then fit one square within the available
/// space. Text scaling and tooltip length cannot change the painted geometry.
class _CircleControl extends StatelessWidget {
  const _CircleControl({required this.builder});
  final Widget Function(double side) builder;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, limits) {
      final side = math.min(44.0, math.min(limits.maxWidth, limits.maxHeight));
      return PocketReveal(
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: SizedBox.square(dimension: side, child: builder(side)),
        ),
      );
    },
  );
}

class _CircleControlClipper extends CustomClipper<Path> {
  const _CircleControlClipper();
  @override
  Path getClip(Size size) => Path()..addOval(Offset.zero & size);
  @override
  bool shouldReclip(_CircleControlClipper oldClipper) => false;
}

class PocketButton extends StatelessWidget {
  const PocketButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.tonal = false,
    this.glass = true,
  });
  const PocketButton.tonal({
    super.key,
    required this.onPressed,
    required this.child,
    this.glass = true,
  }) : tonal = true;
  final VoidCallback? onPressed;
  final Widget child;
  final bool tonal, glass;
  @override
  Widget build(BuildContext context) => PocketReveal(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TonalButtonTheme(
        glass: glass && LiquidGlassScope.of(context),
        filledTonal: tonal,
        child: ElasticPress(
          enabled: onPressed != null,
          child: FilledButton(onPressed: onPressed, child: child),
        ),
      ),
    ),
  );
}

/// Full-height content with independent overlay chrome. Insets belong to scroll
/// contents, never to their viewport, so content passes behind both edges.
class PocketScaffold extends StatefulWidget {
  const PocketScaffold({
    super.key,
    required this.title,
    required this.body,
    this.leading,
    this.trailing,
    this.bottom,
    this.drawer,
    this.scaffoldKey,
  });
  final Widget title, body;
  final Widget? leading, trailing, bottom, drawer;
  final GlobalKey<ScaffoldState>? scaffoldKey;
  @override
  State<PocketScaffold> createState() => _PocketScaffoldState();
}

class _PocketScaffoldState extends State<PocketScaffold> {
  double bottomHeight = 0;
  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final color = Theme.of(context).scaffoldBackgroundColor;
    final headerHeight = (MediaQuery.textScalerOf(context).scale(17) * 2.4)
        .clamp(52.0, 120.0);
    final top = safe.top + headerHeight + 20;
    return PocketReveal(
      child: Scaffold(
        key: widget.scaffoldKey,
        drawer: widget.drawer == null
            ? null
            : FilledInputTheme(
                borderRadius: AppRadius.xl,
                child: widget.drawer!,
              ),
        resizeToAvoidBottomInset: true,
        body: FilledInputTheme(
          borderRadius: AppRadius.xl,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 17,
          ),
          child: _PocketInsets(
            top: top + 12,
            bottom: widget.bottom == null
                ? safe.bottom + 28
                : bottomHeight + 20,
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.body,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: top + 28,
                  child: FloatingEdgeScrim(
                    backgroundColor: color,
                    overhang: 28,
                  ),
                ),
                Positioned(
                  top: safe.top + 10,
                  left: 18,
                  right: 18,
                  child: SizedBox(
                    height: headerHeight,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          left: 60,
                          right: 60,
                          child: Center(
                            child: DefaultTextStyle(
                              style: AppTextStyle.headline.of(
                                context,
                                emphasized: true,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              child: widget.title,
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            widget.leading ??
                                GlassButton(
                                  icon: Icons.arrow_back_rounded,
                                  label: '返回',
                                  onPressed: Navigator.canPop(context)
                                      ? () => Navigator.maybePop(context)
                                      : null,
                                ),
                            const Spacer(),
                            widget.trailing ?? const SizedBox(width: 44),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.bottom != null) ...[
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: bottomHeight + 28,
                    child: FloatingEdgeScrim(
                      backgroundColor: color,
                      overhang: 28,
                      bottom: true,
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _MeasureSize(
                      onChange: (size) {
                        if (mounted &&
                            (bottomHeight - size.height).abs() > .5) {
                          setState(() => bottomHeight = size.height);
                        }
                      },
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          10,
                          16,
                          safe.bottom + 8,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight:
                                (MediaQuery.sizeOf(context).height -
                                        MediaQuery.viewInsetsOf(context)
                                            .bottom -
                                        top -
                                        safe.bottom -
                                        30)
                                    .clamp(80.0, double.infinity),
                          ),
                          child: SingleChildScrollView(
                            reverse: true,
                            child: widget.bottom,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PocketInsets extends InheritedWidget {
  const _PocketInsets({
    required this.top,
    required this.bottom,
    required super.child,
  });
  final double top, bottom;
  static _PocketInsets? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PocketInsets>();
  @override
  bool updateShouldNotify(_PocketInsets oldWidget) =>
      top != oldWidget.top || bottom != oldWidget.bottom;
}

class PocketList extends StatefulWidget {
  const PocketList({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.controller,
  }) : itemBuilder = null,
       itemCount = null,
       findChildIndexCallback = null;
  const PocketList.builder({
    super.key,
    required this.itemBuilder,
    required this.itemCount,
    this.findChildIndexCallback,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.controller,
  }) : children = null;
  final List<Widget>? children;
  final IndexedWidgetBuilder? itemBuilder;
  final int? itemCount;
  final int? Function(Key)? findChildIndexCallback;
  final EdgeInsets padding;
  final ScrollController? controller;
  @override
  State<PocketList> createState() => _PocketListState();
}

class _PocketListState extends State<PocketList> {
  // Keep only identities, not widgets or buffers. Lazy rows may be disposed
  // outside the cache extent without becoming new content on the return trip.
  final _presented = <(Type, Object)>{};

  @override
  Widget build(BuildContext context) {
    final insets = _PocketInsets.of(context);
    final scrollPadding =
        widget.padding +
        EdgeInsets.only(top: insets?.top ?? 12, bottom: insets?.bottom ?? 24);
    if (widget.itemBuilder != null) {
      return ListView.builder(
        controller: widget.controller,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: scrollPadding,
        itemBuilder: (context, index) =>
            _revealItem(widget.itemBuilder!(context, index), index),
        itemCount: widget.itemCount,
        findChildIndexCallback: widget.findChildIndexCallback == null
            ? null
            : (key) {
                if (key is _PocketListItemKey) {
                  final original = key.value.$2;
                  return original is Key
                      ? widget.findChildIndexCallback!(original)
                      : null;
                }
                return widget.findChildIndexCallback!(key);
              },
      );
    }
    return ListView(
      controller: widget.controller,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: scrollPadding,
      children: [
        for (var index = 0; index < widget.children!.length; index++)
          _revealItem(widget.children![index], index),
      ],
    );
  }

  // Keep the original child's stable identity through this wrapper. A GlobalKey
  // belongs only to the child, never to both levels.
  Widget _revealItem(Widget child, int index) {
    final identity = (child.runtimeType, child.key ?? index);
    return _PocketListItem(
      key: _PocketListItemKey(identity),
      presented: _presented,
      identity: identity,
      child: child,
    );
  }
}

class _PocketListItemKey extends ValueKey<(Type, Object)> {
  const _PocketListItemKey(super.value);
}

class _PocketListItem extends StatefulWidget {
  const _PocketListItem({
    super.key,
    required this.presented,
    required this.identity,
    required this.child,
  });
  final Set<(Type, Object)> presented;
  final (Type, Object) identity;
  final Widget child;
  @override
  State<_PocketListItem> createState() => _PocketListItemState();
}

class _PocketListItemState extends State<_PocketListItem> {
  // Recording belongs to mount, not the eager ListView's widget construction.
  late final animate = widget.presented.add(widget.identity);

  @override
  Widget build(BuildContext context) =>
      PocketReveal(animate: animate, child: widget.child);
}

class PocketEmpty extends StatelessWidget {
  const PocketEmpty({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final inset = _PocketInsets.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          28,
          inset?.top ?? 0,
          28,
          inset?.bottom ?? 0,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight:
                (constraints.maxHeight -
                        (inset?.top ?? 0) -
                        (inset?.bottom ?? 0))
                    .clamp(0, double.infinity),
          ),
          child: Center(child: PocketReveal(child: child)),
        ),
      ),
    );
  }
}

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});
  final ValueChanged<Size> onChange;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SizeObserver(onChange);
  @override
  void updateRenderObject(BuildContext context, _SizeObserver renderObject) =>
      renderObject.onChange = onChange;
}

class _SizeObserver extends RenderProxyBox {
  _SizeObserver(this.onChange);
  ValueChanged<Size> onChange;
  Size? previous;
  @override
  void performLayout() {
    super.performLayout();
    if (previous == size) return;
    previous = size;
    final measured = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onChange(measured);
    });
  }
}

class PocketMark extends StatelessWidget {
  const PocketMark({this.size = 56, super.key});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _PocketMarkPainter(Theme.of(context).colorScheme.onSurface),
    ),
  );
}

class _PocketMarkPainter extends CustomPainter {
  _PocketMarkPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pocket = Path()
      ..moveTo(14, 15)
      ..lineTo(14, 37)
      ..quadraticBezierTo(14, 44, 21, 48)
      ..lineTo(32, 55)
      ..lineTo(43, 48)
      ..quadraticBezierTo(50, 44, 50, 37)
      ..lineTo(50, 15);
    canvas.drawPath(pocket, paint);
    canvas.drawPath(
      Path()
        ..moveTo(25, 23)
        ..lineTo(32, 30)
        ..lineTo(25, 37),
      paint,
    );
    canvas.drawLine(const Offset(36, 38), const Offset(41, 38), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PocketMarkPainter oldDelegate) =>
      color != oldDelegate.color;
}

class PocketCard extends StatelessWidget {
  const PocketCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.onTap,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => PocketReveal(
    child: DashboardCard(padding: padding, onTap: onTap, child: child),
  );
}

class _PocketGroup extends InheritedWidget {
  const _PocketGroup({required super.child});
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PocketGroup>() != null;
  @override
  bool updateShouldNotify(_PocketGroup oldWidget) => false;
}

class PocketSection extends StatelessWidget {
  const PocketSection({
    this.title,
    required this.children,
    this.divided = false,
    super.key,
  });
  final String? title;
  final List<Widget> children;

  /// Separates each direct child when callers supply a group of custom rows.
  final bool divided;
  @override
  Widget build(BuildContext context) => PocketReveal(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
              child: Text(
                title!,
                style: AppTextStyle.footnote
                    .of(context, emphasized: true)
                    .copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            shape: AppShape.xl,
            clipBehavior: Clip.antiAlias,
            child: _PocketGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0 &&
                        (divided ||
                            (children[i - 1] is PocketRow &&
                                children[i] is PocketRow)))
                      Padding(
                        padding: const EdgeInsets.only(left: 56, right: 18),
                        child: Divider(
                          height: 1,
                          thickness: .5,
                          color: Theme.of(context).colorScheme.outlineVariant
                              .withValues(alpha: .4),
                        ),
                      ),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class PocketTile extends StatelessWidget {
  const PocketTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 12,
    ),
  });
  final Widget title;
  final Widget? subtitle, leading, trailing;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry contentPadding;
  @override
  Widget build(BuildContext context) {
    final grouped = _PocketGroup.contains(context);
    final shape = grouped ? AppShape.none : AppShape.xl;
    return PocketReveal(
      child: FocusRing(
        shape: shape,
        child: Material(
          color: selected
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
          shape: shape,
          child: InkWell(
            customBorder: shape,
            splashFactory: grouped ? NoSplash.splashFactory : null,
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 60),
              padding: contentPadding,
              child: Row(
                children: [
                  if (leading != null) ...[
                    IconTheme(
                      data: IconThemeData(
                        size: 22,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      child: leading!,
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DefaultTextStyle(
                          style: AppTextStyle.body.of(context),
                          child: title,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          DefaultTextStyle(
                            style: AppTextStyle.footnote
                                .of(context)
                                .copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                            child: subtitle!,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 14),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PocketRow extends StatelessWidget {
  const PocketRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.leading,
    super.key,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Widget? leading;
  @override
  Widget build(BuildContext context) => PocketTile(
    leading: leading ?? Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    onTap: onTap,
    trailing:
        trailing ??
        (onTap == null
            ? null
            : Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.outline,
              )),
  );
}

class PocketSwitchRow extends StatelessWidget {
  const PocketSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    required this.value,
    required this.onChanged,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 14,
    ),
  });
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry contentPadding;
  @override
  Widget build(BuildContext context) => PocketTile(
    title: title,
    leading: leading,
    subtitle: subtitle,
    contentPadding: contentPadding,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: DashboardSwitch(value: value, onChanged: onChanged),
  );
}

class PocketChoice extends StatelessWidget {
  const PocketChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: PocketButton(
      tonal: !selected,
      onPressed: onSelected == null ? null : () => onSelected!(!selected),
      child: label,
    ),
  );
}

class PocketDisclosure extends StatefulWidget {
  const PocketDisclosure({super.key, required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  State<PocketDisclosure> createState() => _PocketDisclosureState();
}

class _PocketDisclosureState extends State<PocketDisclosure> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final details = expanded
        ? Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: PocketReveal(child: widget.child),
          )
        : const SizedBox(width: double.infinity);
    final contents = Column(
      children: [
        Semantics(
          expanded: expanded,
          child: PocketTile(
            title: Text(widget.title),
            trailing: AnimatedRotation(
              turns: expanded ? .25 : 0,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              child: const Icon(Icons.chevron_right_rounded),
            ),
            onTap: () => setState(() => expanded = !expanded),
          ),
        ),
        if (reduceMotion)
          details
        else
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: details,
          ),
      ],
    );
    return _PocketGroup.contains(context)
        ? contents
        : PocketSection(children: [contents]);
  }
}

/// An action inside FlClash's TonalButtonGroup; the group owns its press.
class PocketAction extends StatelessWidget {
  const PocketAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) =>
      IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon));
}

class PocketSwatch extends StatelessWidget {
  const PocketSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => _CircleControl(
    builder: (side) => ElasticPress(
      enabled: onTap != null,
      preserveAspectRatio: true,
      child: Semantics(
        selected: selected,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: side,
            height: side,
            decoration: ShapeDecoration(
              color: color,
              shape: const CircleBorder(),
            ),
            child: selected
                ? const Icon(Icons.check_rounded, color: Colors.white)
                : null,
          ),
        ),
      ),
    ),
  );
}

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:prism_ui/drag_back.dart';
import 'package:prism_ui/page_transition.dart';

import 'flclash/liquid_glass.dart';
import 'flclash/shape.dart';
import 'flclash/surface.dart';
import 'flclash/typography.dart';
import 'flclash/color.dart';
import 'flclash/elastic_press.dart';
import 'flclash/button.dart';
import 'flclash/input.dart';
import 'flclash/dashboard_card.dart';
import 'flclash/daylight.dart';
import 'flclash/floating_header.dart';
import 'entry_motion.dart';
import 'prism_bridge.dart';

export 'flclash/liquid_glass.dart';
export 'flclash/shape.dart';
export 'flclash/elastic_press.dart';
export 'flclash/button.dart';
export 'flclash/segmented_control.dart';
export 'flclash/floating_header.dart';
export 'package:prism_ui/sheet_header.dart' show FloatingHeader;

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

/// The prism_ui card page motion, including interactive drag back.
///
/// Every push in this app goes through this route, so the transition, the
/// covered-page snapshot and the edge gesture come from the library while the
/// page itself stays ours.
class PocketRoute<T> extends PageRoute<T>
    with CardRouteMixin<T>, DragBackRouteMixin<T> {
  PocketRoute({required this.builder, this.dragBack = true, super.settings});
  final WidgetBuilder builder;

  /// 是否接受边缘拖动返回。首页级全屏页面传 false，手势不能把它带走。
  final bool dragBack;

  @override
  Widget dragBackDetector(Widget child) =>
      dragBack ? super.dragBackDetector(child) : child;

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

/// 全屏目的地的路由名。
///
/// 每个可从侧栏或页头进入的目的地都有一个稳定标识；推入时把标识写进路由名，
/// 于是「我是不是已经在这个目的地」只靠栈顶路由就能回答，不需要另存导航状态。
///
/// @param destination 目的地标识，例如 `remote-dsh`、`tasks`。
/// @returns 仅用于 `RouteSettings.name` 的路由名。
String destinationRouteName(String destination) =>
    'dsh-destination:$destination';

/// 栈顶是否已经是 [destination]。
///
/// 侧栏在目的地页面里原地挂出时，`context` 属于该页面的路由，因此这里读到的就是
/// 用户眼前的页面。根路由的 `name` 为 null，永远不匹配。
///
/// @param context 调用方所在构建上下文。
/// @param destination 目的地标识。
/// @returns 已经是该目的地时为 true。
bool isCurrentDestination(BuildContext context, String destination) =>
    ModalRoute.of(context)?.settings.name == destinationRouteName(destination);

/// 推入一个全屏目的地，**同一个目的地不会在栈上叠第二层**。
///
/// 已经在 [destination] 时直接返回 `null`，不推入任何路由：侧栏与页头的入口点
/// 因此可以反复点击而不套娃。返回值的语义与 `Navigator.push` 一致。
///
/// @param context 调用方所在构建上下文；解析出的 Navigator 就是当前的那一个。
/// @param destination 目的地标识，必须与页面内的侧栏入口使用同一个值。
/// @param builder 目的地页面构造器。
/// @param dragBack 是否接受边缘拖动返回；首页级页面传 false。
/// @returns 页面关闭时带回的结果；已经在该目的地时不推入并返回 null。
Future<T?> openDestination<T>(
  BuildContext context, {
  required String destination,
  required WidgetBuilder builder,
  bool dragBack = true,
}) {
  if (isCurrentDestination(context, destination)) return Future<T?>.value();
  return Navigator.of(context).push<T>(
    PocketRoute<T>(
      builder: builder,
      dragBack: dragBack,
      settings: RouteSettings(name: destinationRouteName(destination)),
    ),
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
          style: PocketGlass.regular(Theme.of(context).colorScheme),
          borderRadius: BorderRadius.circular(radius),
          child: CustomPaint(
            painter: DaylightFinish(
              shape: AppShape.all(radius),
              dark: Theme.of(context).brightness == Brightness.dark,
            ),
            child: child,
          ),
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
                              ? PocketGlass.tinted(colors, colors.primary)
                              : PocketGlass.regular(colors),
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
    this.header,
    this.headerHeight,
    this.ambientMotion = true,
    this.animateEntrance = true,
    this.bottomHeightDebounce = Duration.zero,
    this.keyboardOverlay = false,
    this.onKeyboardSettled,
    this.bottom,
    this.drawer,
    this.onDrawerChanged,
    this.scaffoldKey,
  });
  final Widget title, body;
  final Widget? leading, trailing, header, bottom, drawer;

  /// Height of a custom floating header; defaults to the standard title row.
  final double? headerHeight;

  /// Keep the ambient backdrop static on pages with frequent live updates.
  final bool ambientMotion;
  final bool animateEntrance;

  /// Delays transcript inset changes while the bottom widget animates its height.
  final Duration bottomHeightDebounce;

  /// Keeps the transcript viewport fixed while the system keyboard moves.
  final bool keyboardOverlay;
  final VoidCallback? onKeyboardSettled;
  final ValueChanged<bool>? onDrawerChanged;
  final GlobalKey<ScaffoldState>? scaffoldKey;
  @override
  State<PocketScaffold> createState() => _PocketScaffoldState();
}

class _PocketScaffoldState extends State<PocketScaffold>
    with WidgetsBindingObserver {
  double bottomHeight = 0;
  Timer? _bottomHeightTimer;
  Timer? _keyboardInsetTimer;
  double _settledKeyboardInset = 0;
  final _suspendAmbient = ValueNotifier(false);
  bool _bodyScrolling = false, _drawerOpen = false;
  void _updateAmbient() => _suspendAmbient.value =
      !widget.ambientMotion || _bodyScrolling || _drawerOpen;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateAmbient();
  }

  @override
  void didChangeMetrics() {
    if (!widget.keyboardOverlay) return;
    _keyboardInsetTimer?.cancel();
    _keyboardInsetTimer = Timer(const Duration(milliseconds: 80), () {
      _keyboardInsetTimer = null;
      if (!mounted) return;
      final view = View.of(context);
      final inset = view.viewInsets.bottom / view.devicePixelRatio;
      if ((_settledKeyboardInset - inset).abs() >= .5) {
        setState(() => _settledKeyboardInset = inset);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onKeyboardSettled?.call();
      });
    });
  }

  @override
  void didUpdateWidget(covariant PocketScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ambientMotion != widget.ambientMotion) _updateAmbient();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bottomHeightTimer?.cancel();
    _keyboardInsetTimer?.cancel();
    _suspendAmbient.dispose();
    super.dispose();
  }

  void _onBottomSizeChanged(Size size) {
    final nextHeight = size.height;
    if ((bottomHeight - nextHeight).abs() <= .5) {
      _bottomHeightTimer?.cancel();
      return;
    }
    _bottomHeightTimer?.cancel();
    if (bottomHeight == 0 || widget.bottomHeightDebounce == Duration.zero) {
      setState(() => bottomHeight = nextHeight);
      return;
    }
    _bottomHeightTimer = Timer(widget.bottomHeightDebounce, () {
      _bottomHeightTimer = null;
      if (mounted) setState(() => bottomHeight = nextHeight);
    });
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final color = Theme.of(context).scaffoldBackgroundColor;
    final headerHeight =
        widget.headerHeight ??
        (MediaQuery.textScalerOf(context).scale(17) * 2.4).clamp(52.0, 120.0);
    final top = safe.top + headerHeight + 20;
    return PocketReveal(
      animate: widget.animateEntrance,
      child: Scaffold(
        key: widget.scaffoldKey,
        onDrawerChanged: (open) {
          _drawerOpen = open;
          _updateAmbient();
          widget.onDrawerChanged?.call(open);
        },
        drawer: widget.drawer == null
            ? null
            : FilledInputTheme(
                borderRadius: AppRadius.xl,
                child: widget.drawer!,
              ),
        resizeToAvoidBottomInset: !widget.keyboardOverlay,
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
                : bottomHeight + _settledKeyboardInset + 20,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (LiquidGlassScope.of(context))
                  Positioned.fill(
                    child: DaylightBackdrop(suspendMotion: _suspendAmbient),
                  ),
                NotificationListener<ScrollNotification>(
                  onNotification: (event) {
                    if (event is ScrollStartNotification) {
                      _bodyScrolling = true;
                      _updateAmbient();
                    } else if (event is ScrollEndNotification) {
                      _bodyScrolling = false;
                      _updateAmbient();
                    }
                    return false;
                  },
                  // The glass chrome above this stack repaints on every press,
                  // capture and scrim fade; the page body belongs to its own
                  // layer so none of that repaints the transcript.
                  child: RepaintBoundary(child: widget.body),
                ),
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
                    child:
                        widget.header ??
                        Stack(
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
                if (widget.bottom case final bottom?)
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: _PocketBottomDock(
                        bottom: bottom,
                        height: bottomHeight,
                        top: top,
                        safeBottom: safe.bottom,
                        color: color,
                        keyboardOverlay: widget.keyboardOverlay,
                        onSizeChanged: _onBottomSizeChanged,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PocketBottomDock extends StatelessWidget {
  const _PocketBottomDock({
    required this.bottom,
    required this.height,
    required this.top,
    required this.safeBottom,
    required this.color,
    required this.keyboardOverlay,
    required this.onSizeChanged,
  });

  final Widget bottom;
  final double height, top, safeBottom;
  final Color color;
  final bool keyboardOverlay;
  final ValueChanged<Size> onSizeChanged;

  @override
  Widget build(BuildContext context) {
    final keyboardInset = keyboardOverlay
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          bottom: keyboardInset,
          left: 0,
          right: 0,
          height: height + 28,
          child: FloatingEdgeScrim(
            backgroundColor: color,
            overhang: 28,
            bottom: true,
          ),
        ),
        Positioned(
          bottom: keyboardInset,
          left: 0,
          right: 0,
          child: _MeasureSize(
            onChange: onSizeChanged,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, safeBottom + 8),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      (MediaQuery.sizeOf(context).height -
                              MediaQuery.viewInsetsOf(context).bottom -
                              top -
                              safeBottom -
                              30)
                          .clamp(80.0, double.infinity),
                ),
                child: SingleChildScrollView(reverse: true, child: bottom),
              ),
            ),
          ),
        ),
      ],
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

/// Preserves a mounted list row when variable-height items are inserted above
/// it. A lazy sliver's max extent is only an estimate until those rows have
/// been laid out, so an extent delta alone is not a reliable scroll anchor.
class PocketListAnchorController {
  _PocketListState? _owner;
  int _revision = 0;
  ScrollController? _revealingScroll;
  PocketListAnchor? _heldAnchor;
  VoidCallback? _releaseHeld;
  (Type, Object)? _spaceIdentity;
  double _space = 0;
  bool _releaseSpace = false;

  PocketListAnchor? capture({int minIndex = 0, Set<Key>? keys}) =>
      _owner?._captureAnchor(minIndex, keys: keys);

  /// Corrects scroll offset during sliver layout, before each animation frame
  /// paints. Keeps the same point inside a long, partially visible answer row.
  void hold(
    PocketListAnchor anchor,
    Animation<double> motion, {
    bool immediate = false,
  }) {
    cancel(releaseSpace: false);
    _releaseSpace = false;
    _heldAnchor = anchor;
    final revision = _revision;
    void status(AnimationStatus status) {
      if (status != AnimationStatus.dismissed &&
          status != AnimationStatus.completed) {
        return;
      }
      // A collapsed chain retires its lazy rows on the following frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_revision == revision) {
            _heldAnchor = null;
            _releaseHeld?.call();
            _releaseHeld = null;
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      });
    }

    motion.addStatusListener(status);
    _releaseHeld = () => motion.removeStatusListener(status);
    if (immediate) status(AnimationStatus.dismissed);
  }

  /// Lift an actual keyed row below the floating header. Layout refinements
  /// stay cancellable so a drag, session switch or newer send always wins.
  void reveal(Key key, ScrollController scroll, {required bool animate}) {
    final owner = _owner;
    if (owner == null) return;
    final revision = ++_revision;
    _revealingScroll = scroll;
    Future<void> settle() async {
      try {
        for (var pass = 0; pass < 12; pass++) {
          await WidgetsBinding.instance.endOfFrame;
          if (_revision != revision || _owner != owner || !scroll.hasClients) {
            return;
          }
          final target = owner._revealOffset(key, scroll);
          if (target == null) return;
          if ((target - scroll.offset).abs() < .5) return;
          if (animate) {
            await scroll.animateTo(
              target,
              duration: Duration(milliseconds: pass == 0 ? 280 : 100),
              curve: Curves.easeOutCubic,
            );
          } else {
            scroll.jumpTo(target);
          }
        }
      } finally {
        if (_revision == revision) _revealingScroll = null;
      }
    }

    unawaited(settle());
  }

  void restore(PocketListAnchor anchor, ScrollController scroll) {
    final owner = _owner;
    if (owner == null) return;
    final revision = ++_revision;
    void settle(int remaining, int stableFrames) {
      if (_revision != revision || _owner != owner || !scroll.hasClients) {
        return;
      }
      final moved = owner._alignAnchor(anchor, scroll);
      final stable = moved ? 0 : stableFrames + 1;
      if (remaining > 0 && stable < 2) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => settle(remaining - 1, stable),
        );
        WidgetsBinding.instance.scheduleFrame();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => settle(12, 0));
  }

  void cancel({
    bool stopReveal = false,
    bool releaseSpace = true,
    bool discardSpace = false,
  }) {
    _revision++;
    _heldAnchor = null;
    _releaseHeld?.call();
    _releaseHeld = null;
    if (releaseSpace) _releaseSpace = true;
    if (discardSpace) {
      _spaceIdentity = null;
      _space = 0;
    }
    final scroll = _revealingScroll;
    _revealingScroll = null;
    if (stopReveal && scroll != null && scroll.hasClients) {
      final position = scroll.position;
      if (position is ScrollPositionWithSingleContext) position.goIdle();
    }
  }

  void dispose() {
    cancel(discardSpace: true);
    _owner = null;
  }
}

class PocketListAnchor {
  const PocketListAnchor._(this.identity, this.y);
  final (Type, Object) identity;
  final double y;
}

class PocketList extends StatefulWidget {
  const PocketList({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.controller,
    this.anchorController,
    this.endAnchorKey,
    this.reserveEndSpace = false,
    this.animateItems = true,
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
    this.anchorController,
    this.endAnchorKey,
    this.reserveEndSpace = false,
    this.animateItems = true,
  }) : children = null;
  final List<Widget>? children;
  final IndexedWidgetBuilder? itemBuilder;
  final int? itemCount;
  final int? Function(Key)? findChildIndexCallback;
  final EdgeInsets padding;
  final ScrollController? controller;
  final PocketListAnchorController? anchorController;

  /// Reserve only the remaining viewport below a newly sent message. The
  /// space shrinks to zero as later rows grow; ordinary lists add no space.
  final Key? endAnchorKey;
  final bool reserveEndSpace;
  final bool animateItems;
  @override
  State<PocketList> createState() => _PocketListState();
}

class _PocketListState extends State<PocketList> {
  // Keep only identities, not widgets or buffers. Lazy rows may be disposed
  // outside the cache extent without becoming new content on the return trip.
  final _presented = <(Type, Object)>{};
  final _mountedItems = <(Type, Object), _PocketListItemState>{};
  double? _endAnchorOffset;
  double _topInset = 0;

  @override
  void initState() {
    super.initState();
    widget.anchorController?._owner = this;
  }

  @override
  void didUpdateWidget(PocketList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endAnchorKey != widget.endAnchorKey) _endAnchorOffset = null;
    if (oldWidget.anchorController != widget.anchorController) {
      if (oldWidget.anchorController?._owner == this) {
        oldWidget.anchorController
          ?..cancel()
          .._owner = null;
      }
      widget.anchorController?._owner = this;
    }
  }

  @override
  void dispose() {
    if (widget.anchorController?._owner == this) {
      widget.anchorController
        ?..cancel()
        .._owner = null;
    }
    _mountedItems.clear();
    super.dispose();
  }

  void _register(_PocketListItemState item) {
    _mountedItems[item.widget.identity] = item;
  }

  void _unregister(_PocketListItemState item) {
    if (identical(_mountedItems[item.widget.identity], item)) {
      _mountedItems.remove(item.widget.identity);
    }
  }

  ({int index, double y, double height, double viewportHeight})? _geometry(
    _PocketListItemState item,
  ) {
    // A lazy sliver can retain a child from its previous index for one or
    // more frames after a prepend. Its old paint transform is not evidence of
    // where that keyed row now belongs.
    final key = item.widget.identity.$2;
    if (key is Key &&
        widget.findChildIndexCallback != null &&
        widget.findChildIndexCallback!(key) != item.widget.index) {
      return null;
    }
    final render = item.context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    final viewport = RenderAbstractViewport.maybeOf(render);
    if (viewport == null || viewport is! RenderBox) {
      return null;
    }
    final box = viewport as RenderBox;
    if (!box.attached || !box.hasSize) return null;
    return (
      index: item.widget.index,
      y:
          render.localToGlobal(Offset.zero, ancestor: box).dy +
          (render is _RenderPocketReadingInset ? render.inset : 0),
      height:
          render.size.height -
          (render is _RenderPocketReadingInset ? render.inset : 0),
      viewportHeight: box.size.height,
    );
  }

  PocketListAnchor? _captureAnchor(int minIndex, {Set<Key>? keys}) {
    _PocketListItemState? chosen;
    double? bestY;
    for (final item in _mountedItems.values) {
      if (item.widget.index < minIndex) continue;
      if (keys != null && !keys.contains(item.widget.identity.$2)) continue;
      final geometry = _geometry(item);
      if (geometry == null ||
          geometry.y + geometry.height <= 0 ||
          geometry.y >= geometry.viewportHeight) {
        continue;
      }
      if (bestY == null || geometry.y < bestY) {
        chosen = item;
        bestY = geometry.y;
      }
    }
    return chosen == null
        ? null
        : PocketListAnchor._(chosen.widget.identity, bestY!);
  }

  double? _heldCorrection(
    RenderSliverMultiBoxAdaptor list,
    SliverConstraints constraints,
  ) {
    final controller = widget.anchorController;
    final anchor = controller?._heldAnchor;
    final scroll = widget.controller;
    if (controller == null || scroll == null || !scroll.hasClients) return 0;
    // Retire only space already passed by the user's scroll. Correcting that
    // same amount before paint keeps the content under their finger in place.
    if (controller._releaseSpace &&
        controller._space > 0 &&
        scroll.offset > 0) {
      final item = _mountedItems[controller._spaceIdentity];
      final render = item?.context.findRenderObject();
      final amount = math.min(controller._space, scroll.offset);
      controller._space -= amount;
      if (render is _RenderPocketReadingInset) render.inset = controller._space;
      return -amount;
    }
    if (anchor == null) return 0;
    final item = _mountedItems[anchor.identity];
    if (item == null) return 0;
    final render = item.context.findRenderObject();
    RenderObject? box = render;
    while (box != null && box.parent != list) {
      box = box.parent;
    }
    if (box is! RenderBox || box.parent != list) return 0;
    final offset = list.childScrollOffset(box);
    if (offset == null) return 0;
    final inset = render is _RenderPocketReadingInset ? render.inset : 0.0;
    final target =
        constraints.precedingScrollExtent + offset + inset - anchor.y;
    if (target < scroll.position.minScrollExtent - .01 &&
        render is _RenderPocketReadingInset) {
      controller._spaceIdentity = anchor.identity;
      controller._space = inset + scroll.position.minScrollExtent - target;
      controller._releaseSpace = false;
      render.inset = controller._space;
      return null;
    }
    return math.max(scroll.position.minScrollExtent, target) - scroll.offset;
  }

  double? _keyOffset(Key key, ScrollController scroll) {
    for (final item in _mountedItems.values) {
      if (item.widget.identity.$2 != key) continue;
      final geometry = _geometry(item);
      if (geometry != null) return scroll.offset + geometry.y;
    }
    return null;
  }

  double? _revealOffset(Key key, ScrollController scroll) {
    final measured = _keyOffset(key, scroll);
    if (measured != null) {
      return (measured - _topInset).clamp(
        scroll.position.minScrollExtent,
        scroll.position.maxScrollExtent,
      );
    }
    // A newly appended message may not yet be inside the lazy cache.
    if (widget.findChildIndexCallback?.call(key) == null) return null;
    return scroll.position.maxScrollExtent;
  }

  /// Returns true only when another layout pass could improve the estimate.
  bool _alignAnchor(PocketListAnchor anchor, ScrollController scroll) {
    final exact = _mountedItems[anchor.identity];
    final measured = exact == null ? null : _geometry(exact);
    if (measured != null) {
      final delta = measured.y - anchor.y;
      if (delta.abs() < .5) return false;
      final position = scroll.position;
      final target = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < .5) return false;
      scroll.jumpTo(target);
      return true;
    }

    final key = anchor.identity.$2;
    final targetIndex = key is Key
        ? widget.findChildIndexCallback?.call(key)
        : null;
    if (targetIndex == null) return false;
    final visible =
        <({int index, double y, double height, double viewportHeight})>[];
    for (final item in _mountedItems.values) {
      final geometry = _geometry(item);
      if (geometry != null &&
          geometry.height > 0 &&
          geometry.y + geometry.height > 0 &&
          geometry.y < geometry.viewportHeight) {
        visible.add(geometry);
      }
    }
    if (visible.isEmpty) return false;
    visible.sort(
      (a, b) => (a.index - targetIndex).abs().compareTo(
        (b.index - targetIndex).abs(),
      ),
    );
    final nearest = visible.first;
    final extent =
        visible.map((item) => item.height).reduce((a, b) => a + b) /
        visible.length;
    final estimate = nearest.y + (targetIndex - nearest.index) * extent;
    final position = scroll.position;
    final target = (position.pixels + estimate - anchor.y).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < .5) return false;
    scroll.jumpTo(target);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final insets = _PocketInsets.of(context);
    final scrollPadding =
        widget.padding +
        EdgeInsets.only(top: insets?.top ?? 12, bottom: insets?.bottom ?? 24);
    _topInset = scrollPadding.top;
    if (widget.itemBuilder != null) {
      final delegate = SliverChildBuilderDelegate(
        (context, index) =>
            _revealItem(widget.itemBuilder!(context, index), index),
        childCount: widget.itemCount,
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
      if (!widget.reserveEndSpace) {
        return ListView.custom(
          controller: widget.controller,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: scrollPadding,
          childrenDelegate: delegate,
        );
      }
      return NotificationListener<ScrollStartNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 && notification.dragDetails != null) {
            widget.anchorController?.cancel();
          }
          return false;
        },
        child: CustomScrollView(
          controller: widget.controller,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: scrollPadding,
              sliver: _PocketAnchorSliver(
                correct: _heldCorrection,
                child: SliverList(delegate: delegate),
              ),
            ),
            if (widget.endAnchorKey case final key?)
              SliverLayoutBuilder(
                builder: (context, constraints) {
                  final scroll = widget.controller;
                  if (scroll != null && scroll.hasClients) {
                    _endAnchorOffset =
                        _keyOffset(key, scroll) ?? _endAnchorOffset;
                  }
                  final offset = _endAnchorOffset;
                  final height = offset == null
                      ? 0.0
                      : (offset -
                                _topInset +
                                constraints.viewportMainAxisExtent -
                                constraints.precedingScrollExtent)
                            .clamp(0.0, constraints.viewportMainAxisExtent);
                  return SliverToBoxAdapter(child: SizedBox(height: height));
                },
              ),
          ],
        ),
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
      animate: widget.animateItems,
      identity: identity,
      index: index,
      owner: widget.anchorController == null ? null : this,
      child: child,
    );
  }
}

class _PocketAnchorSliver extends SingleChildRenderObjectWidget {
  const _PocketAnchorSliver({required this.correct, required super.child});
  final double? Function(RenderSliverMultiBoxAdaptor, SliverConstraints)
  correct;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPocketAnchorSliver(correct);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPocketAnchorSliver renderObject,
  ) {
    renderObject.correct = correct;
  }
}

class _RenderPocketAnchorSliver extends RenderProxySliver {
  _RenderPocketAnchorSliver(this.correct);
  double? Function(RenderSliverMultiBoxAdaptor, SliverConstraints) correct;
  @override
  void performLayout() {
    super.performLayout();
    if (geometry!.scrollOffsetCorrection != null ||
        child is! RenderSliverMultiBoxAdaptor) {
      return;
    }
    double? correction;
    invokeLayoutCallback<SliverConstraints>((constraints) {
      correction = correct(child! as RenderSliverMultiBoxAdaptor, constraints);
    });
    if (correction == null) {
      super.performLayout();
      invokeLayoutCallback<SliverConstraints>((constraints) {
        correction = correct(
          child! as RenderSliverMultiBoxAdaptor,
          constraints,
        );
      });
    }
    final offset = correction;
    if (offset != null && offset.abs() > .01) {
      geometry = SliverGeometry(scrollOffsetCorrection: offset);
    }
  }
}

class _PocketListItemKey extends ValueKey<(Type, Object)> {
  const _PocketListItemKey(super.value);
}

class _PocketListItem extends StatefulWidget {
  const _PocketListItem({
    super.key,
    required this.presented,
    required this.animate,
    required this.identity,
    required this.index,
    required this.owner,
    required this.child,
  });
  final Set<(Type, Object)> presented;
  final bool animate;
  final (Type, Object) identity;
  final int index;
  final _PocketListState? owner;
  final Widget child;
  @override
  State<_PocketListItem> createState() => _PocketListItemState();
}

class _PocketListItemState extends State<_PocketListItem> {
  // Recording belongs to mount, not the eager ListView's widget construction.
  late final animate = widget.presented.add(widget.identity);

  @override
  void initState() {
    super.initState();
    widget.owner?._register(this);
  }

  @override
  void didUpdateWidget(_PocketListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.owner != widget.owner ||
        oldWidget.identity != widget.identity) {
      oldWidget.owner?._unregister(this);
      widget.owner?._register(this);
    }
  }

  @override
  void deactivate() {
    widget.owner?._unregister(this);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    widget.owner?._register(this);
  }

  @override
  void dispose() {
    widget.owner?._unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.animate
        ? PocketReveal(animate: animate, child: widget.child)
        : widget.child;
    if (widget.owner?.widget.reserveEndSpace != true) return child;
    return _PocketReadingInset(
      inset:
          widget.owner?.widget.anchorController?._spaceIdentity ==
              widget.identity
          ? widget.owner!.widget.anchorController!._space
          : 0,
      child: child,
    );
  }
}

class _PocketReadingInset extends SingleChildRenderObjectWidget {
  const _PocketReadingInset({required this.inset, required super.child});
  final double inset;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPocketReadingInset(inset);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPocketReadingInset renderObject,
  ) {
    renderObject.inset = inset;
  }
}

class _RenderPocketReadingInset extends RenderShiftedBox {
  _RenderPocketReadingInset(this._inset) : super(null);
  double _inset;
  double get inset => _inset;
  set inset(double value) {
    if (_inset == value) return;
    _inset = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(Size(0, _inset));
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, child.size.height + _inset),
    );
    (child.parentData! as BoxParentData).offset = Offset(0, _inset);
  }
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
          DaylightSurface(
            shape: AppShape.xl,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            enabled: LiquidGlassScope.of(context),
            child: Material(
              type: MaterialType.transparency,
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
    this.neutralSelection = false,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 12,
    ),
  });
  final Widget title;
  final Widget? subtitle, leading, trailing;
  final VoidCallback? onTap;
  final bool selected;

  /// 选中时用中性表面而不是主色容器：侧栏「当前所在页面」属于位置指示，
  /// 不是主操作，用中性高亮才不会抢走强调色。
  final bool neutralSelection;
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
              ? (neutralSelection
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : Theme.of(context).colorScheme.primaryContainer)
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
    trailing: PocketSwitch(value: value, onChanged: onChanged),
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

/// 根对话页提供的应用级动作。
///
/// 「远程 DSH」这类全屏子页面在**原地**挂出同一份侧栏，但侧栏里的「新对话」
/// 「选择会话」「后台任务」「自动化任务」都由根对话页的状态拥有。子页面因此
/// 通过这里调用同一条动作，而不是自己复制一份导航逻辑。
class AppShellActions {
  /// 记录根对话页的动作集合。
  const AppShellActions({
    required this.newChat,
    required this.openSession,
    required this.openTasks,
    required this.openAutomations,
  });

  /// 新建会话并切过去。
  final VoidCallback newChat;

  /// 打开一个已有会话。
  final ValueChanged<String> openSession;

  /// 打开后台任务页。
  final VoidCallback openTasks;

  /// 打开自动化任务页。
  final VoidCallback openAutomations;
}

AppShellActions? _appShellActions;

/// 注册根对话页的应用级动作；传入 null 表示注销。
void registerAppShellActions(AppShellActions? actions) {
  _appShellActions = actions;
}

/// 当前注册的应用级动作；没有根页面时为 null。
AppShellActions? get appShellActions => _appShellActions;

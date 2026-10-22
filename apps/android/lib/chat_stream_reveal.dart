import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';

/// Animates only newly laid-out text ranges. Markdown, links, selection and
/// layout remain owned by the existing renderer; retained glyphs stay opaque.
class ChatStreamReveal extends StatefulWidget {
  const ChatStreamReveal({
    required this.revision,
    required this.child,
    super.key,
  });
  final String revision;
  final Widget child;
  @override
  State<ChatStreamReveal> createState() => _ChatStreamRevealState();
}

class _ChatStreamRevealState extends State<ChatStreamReveal>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: PocketEntryMotion.duration,
  );
  bool _enabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = !MediaQuery.disableAnimationsOf(context);
    if (!_enabled) _motion.stop();
  }

  @override
  void didUpdateWidget(ChatStreamReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_enabled && widget.revision != oldWidget.revision) {
      _motion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _StreamPaint(
    motion: _motion,
    revision: widget.revision,
    enabled: _enabled,
    child: widget.child,
  );
}

class _StreamPaint extends SingleChildRenderObjectWidget {
  const _StreamPaint({
    required this.motion,
    required this.revision,
    required this.enabled,
    required super.child,
  });
  final Animation<double> motion;
  final String revision;
  final bool enabled;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _StreamRender(motion, revision, enabled);
  @override
  void updateRenderObject(BuildContext context, _StreamRender renderObject) =>
      renderObject.update(revision, enabled);
}

class _TextArrival {
  _TextArrival(this.start, this.end, this.at);
  final int start, end, at;
}

class _StreamRender extends RenderProxyBox {
  _StreamRender(this.motion, this.revision, this.enabled);
  final Animation<double> motion;
  final _previous = <String>[];
  final _arrivals = <int, List<_TextArrival>>{};
  String revision;
  bool enabled, _changed = true, _initial = true;
  static final _duration = PocketEntryMotion.duration.inMicroseconds;
  final _isolationShader = ui.Gradient.linear(
    Offset.zero,
    const Offset(1, 0),
    const [Colors.white, Colors.white],
  );
  int get _now =>
      SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds;

  void update(String next, bool animate) {
    if (revision != next) {
      revision = next;
      _changed = true;
      markNeedsLayout();
    }
    if (enabled != animate) {
      enabled = animate;
      if (!enabled) _arrivals.clear();
      markNeedsPaint();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    motion.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    motion.removeListener(markNeedsPaint);
    super.detach();
  }

  List<RenderParagraph> _paragraphs() {
    final result = <RenderParagraph>[];
    void walk(RenderObject node) {
      if (node is RenderParagraph) {
        result.add(node);
        return;
      }
      node.visitChildren(walk);
    }

    if (child != null) walk(child!);
    return result;
  }

  @override
  void performLayout() {
    super.performLayout();
    if (!_changed) return;
    _changed = false;
    final paragraphs = _paragraphs(), now = _now;
    for (var i = 0; i < paragraphs.length; i++) {
      final next = paragraphs[i].text.toPlainText();
      final previous = i < _previous.length ? _previous[i] : '';
      var prefix = 0;
      while (prefix < math.min(next.length, previous.length) &&
          next.codeUnitAt(prefix) == previous.codeUnitAt(prefix)) {
        prefix++;
      }
      final arrivals = _arrivals.putIfAbsent(i, () => []);
      arrivals.removeWhere(
        (range) => now - range.at >= _duration || range.end > prefix,
      );
      if (enabled && !_initial && prefix < next.length) {
        arrivals.add(_TextArrival(prefix, next.length, now));
      }
      if (i < _previous.length) {
        _previous[i] = next;
      } else {
        _previous.add(next);
      }
    }
    _previous.length = paragraphs.length;
    _arrivals.removeWhere((key, _) => key >= paragraphs.length);
    _initial = false;
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!enabled || _arrivals.isEmpty) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    final paragraphs = _paragraphs(), now = _now;
    final regions = <(Rect, double)>[];
    for (var i = 0; i < paragraphs.length; i++) {
      final paragraph = paragraphs[i], ranges = _arrivals[i];
      if (ranges == null) continue;
      ranges.removeWhere((range) => now - range.at >= _duration);
      final transform = paragraph.getTransformTo(this);
      for (final range in ranges) {
        final progress = PocketEntryMotion.curve.transform(
          ((now - range.at) / _duration).clamp(0, 1),
        );
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(baseOffset: range.start, extentOffset: range.end),
        )) {
          regions.add((
            MatrixUtils.transformRect(transform, box.toRect()).shift(offset),
            progress,
          ));
        }
      }
    }
    if (regions.isEmpty) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    // Isolate the complete layer subtree once, including the code scroller's
    // repaint boundaries. A canvas saveLayer only isolates one PictureLayer.
    // The identity shader leaves retained glyphs unchanged; the final picture
    // adjusts only new ranges. No bitmap capture or per-frame layout is needed.
    layer ??= ShaderMaskLayer();
    layer!
      ..shader = _isolationShader
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(layer!, (inner, childOffset) {
      super.paint(inner, childOffset);
      final mask = Paint()..blendMode = BlendMode.dstIn;
      for (final region in regions) {
        mask.color = Color.fromRGBO(255, 255, 255, region.$2);
        inner.canvas.drawRect(region.$1, mask);
      }
    }, offset);
  }
}
